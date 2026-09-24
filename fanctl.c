// fanctl — fan control + CPU/GPU temperatures for Apple Silicon Macs (built on Mac Studio M5 Max, Mac17,14).
//
//   fanctl [status]              temperatures + fans (no root)
//   fanctl watch [-i secs]       live view (no root)
//   fanctl set <rpm|N%>          with fanctld running: sets daemon target and watches (no root);
//                                otherwise needs sudo and holds manual mode until Ctrl-C
//   fanctl auto                  back to automatic control (same daemon/sudo rules as set)
//   fanctl daemon <control-file> run by launchd as root (installed by install.sh)
//   fanctl dump [prefix]         raw SMC keys (debug)
//
// Sensor mapping was established by load tests on Mac17,14: all-core CPU load moves the 18
// Tp0* keys (+9–12 °C; 6 super + 12 performance cores), GPU load moves the Tg* family
// (+10–20 °C, <4 °C under CPU load). Tp1* track both loads weakly and are skipped.
//
// Temperatures: status/watch/set show the mean of the valid readings in each family (a mean
// across sensors in the current sample, not a time average) and the maximum separately. The
// thermal guard always uses the hottest valid reading of either family, never the mean.
//
// Thermal guard (fanctld and `sudo fanctl set`): above GUARD_C every fan is driven to its
// maximum (firmware auto can never spin faster than max, so handing over to it could only
// reduce cooling); below GUARD_C - GUARD_HYST_C the requested speed resumes. With no readable
// temperature sensor the fans go back to auto.
//
// Power: CPU/GPU/ANE/DRAM watts come from metrics.c's IOReport Energy Model as energy delta
// over the channel's own hardware timestamp delta. The counters update in batches (every
// 1–2 s, depending on what drives them); dividing by the poll interval instead gives
// alternating zero/double readings. A repeated timestamp keeps the last interval's value,
// frozen data expires after 10 s, and a new timestamp with zero energy is a genuine 0 W.
// Missing samples print N/A, never 0. "Subtotal" is only CPU + GPU + ANE + DRAM; the other
// Energy Model rails (fabric, media/display, PCIe) are listed separately because their overlap
// with the aggregate rails is unknown. There is no standalone SoC energy channel.
//
// The PMGR CPU/DRAM/ANE counters only advance while a root powermetrics samples (IOReport
// sampling of all ~11k channels, as root or not, leaves their timestamps frozen), so install.sh
// runs `powermetrics --samplers cpu_power -i 1000` as its own LaunchDaemon
// (fanctld-power.plist). GPU Energy updates live regardless.
//
// System power is the SMC's PSTR (≈ PDTR = VD0R × ID0R, the internal PSU's 12 V output, not
// wall power). It is sampled independently of the IOReport channels, so differences between
// the two are approximate. PSTR includes what the USB ports supply to external devices
// (switching off a 14 W USB-C lamp dropped it by 15 W), hence "Mac body" = PSTR - (PU1C +
// PU2C + PU3C + PUAC).
//
// With fanctld running, `set` hands the target to the daemon and then watches; Ctrl-C only
// ends the view, and the daemon keeps the target until `fanctl auto`.
//
// Fan protocol on M5 (no Ftst unlock key): F<i>md = 1 enters manual mode, F<i>Tg is the
// target rpm as a little-endian float. Back to auto: F<i>md = 0, then restore F<i>Tg = F<i>Mn
// (the value the firmware itself reports at idle in auto).
#include "smc.h"
#include "metrics.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <errno.h>
#include <grp.h>
#include <pwd.h>
#include <sys/time.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_SENSORS 256
#define MAX_FANS 8
#define T_MIN 5.0f     // readings outside this range are disconnected/placeholder sensors
#define T_MAX 130.0f
#define GUARD_C 100.0f  // any CPU/GPU sensor above this drives every fan to its maximum
#define GUARD_HYST_C 15.0f  // guard releases once the hottest sensor is this far below GUARD_C
#ifndef STATUS_PATH  // overridable so tests can run unprivileged
#define STATUS_PATH "/var/run/fanctl.status"
#endif
#define STATUS_FRESH_SECS 15

typedef struct { char keys[MAX_SENSORS][5]; int n; } family;
typedef struct { float avg, max; int n; } temp_stat;
typedef struct { float actual, target, min, max; uint8_t mode; } fan_state;

static family cpu_fam, gpu_fam;
static int nfans;

static void die(const char *msg) { fprintf(stderr, "fanctl: %s\n", msg); exit(1); }

static void scan_families(void) {
    uint32_t n;
    if (smc_count(&n)) die("cannot read SMC key count");
    for (uint32_t i = 0; i < n; i++) {
        char k[5];
        if (smc_key_at(i, k) || k[0] != 'T') continue;
        family *f = k[1] == 'p' && k[2] == '0' ? &cpu_fam : k[1] == 'g' ? &gpu_fam : NULL;
        if (!f || f->n >= MAX_SENSORS) continue;
        float v;
        if (smc_read_float(k, &v)) continue;
        memcpy(f->keys[f->n++], k, 5);
    }
}

static temp_stat read_family(const family *f) {
    temp_stat s = {0, 0, 0};
    double sum = 0;
    for (int i = 0; i < f->n; i++) {
        float v;
        if (smc_read_float(f->keys[i], &v) || v < T_MIN || v > T_MAX) continue;
        sum += v;
        if (v > s.max) s.max = v;
        s.n++;
    }
    if (s.n) s.avg = (float)(sum / s.n);
    return s;
}

static void fan_key(char out[5], int fan, const char *suffix) { snprintf(out, 5, "F%d%s", fan, suffix); }

static int read_fan(int i, fan_state *f) {
    char k[5];
    memset(f, 0, sizeof(*f));
    fan_key(k, i, "Ac"); if (smc_read_float(k, &f->actual)) return -1;
    fan_key(k, i, "Tg"); smc_read_float(k, &f->target);
    // Without a valid range or mode every decision below would be wrong (a failed Mn/Mx read
    // used to clamp targets to 0 rpm), so treat any of these failing as an unreadable fan.
    fan_key(k, i, "Mn"); if (smc_read_float(k, &f->min)) return -1;
    fan_key(k, i, "Mx"); if (smc_read_float(k, &f->max)) return -1;
    fan_key(k, i, "md"); if (smc_read_u8(k, &f->mode)) return -1;
    if (!(f->min > 0 && f->max > f->min)) return -1;
    return 0;
}

static void init(void) {
    if (smc_open()) die("cannot open AppleSMC");
    uint8_t n = 0;
    if (smc_read_u8("FNum", &n)) die("cannot read fan count (FNum)");
    nfans = n > MAX_FANS ? MAX_FANS : n;
    scan_families();
}

// ---- settings: "auto", "<rpm>" or "<N>%" of each fan's min..max range ----

// Returns 1 for auto, 0 for manual (rpm clamped to the fan's range), -1 if unparseable.
static int parse_setting(const char *s, const fan_state *f, float *rpm) {
    if (!strcmp(s, "auto")) return 1;
    char *end;
    double v = strtod(s, &end);
    if (end == s || !isfinite(v) || (*end && strcmp(end, "%"))) return -1;
    double r = *end == '%' ? f->min + (f->max - f->min) * v / 100.0 : v;
    if (r < f->min) r = f->min;
    if (r > f->max) r = f->max;
    *rpm = (float)r;
    return 0;
}

// ---- SMC writes (root) ----

static void require_root(void) {
    if (geteuid() != 0) die("writing fan settings needs root — run with sudo, or install fanctld (install.sh)");
}

static int write_auto(int i, float min) {
    char k[5];
    fan_key(k, i, "md");
    if (smc_write_u8(k, 0)) return -1;
    fan_key(k, i, "Tg");
    smc_write_float(k, min);
    return 0;
}

static int write_manual(int i, float rpm) {
    char k[5];
    fan_key(k, i, "md");
    if (smc_write_u8(k, 1)) return -1;
    fan_key(k, i, "Tg");
    return smc_write_float(k, rpm);
}

// Only writes fans that are not already where we want them, so a steady state costs reads only.
static int ensure_auto(void) {
    int err = 0;
    for (int i = 0; i < nfans; i++) {
        fan_state f;
        if (read_fan(i, &f)) { err = -1; continue; }
        if (f.mode && write_auto(i, f.min)) err = -1;
    }
    return err;
}

// Unconditional hand-back for exit, stop, sleep and `fanctl auto`. The F<i>md readback lags a
// write by ~1 s, so right after entering manual it can still read 0 and ensure_auto() would skip
// the write, leaving the fans pinned after we exit. Never trust the readback on these paths.
static int force_auto(void) {
    int err = 0;
    for (int i = 0; i < nfans; i++) {
        fan_state f;
        float min = read_fan(i, &f) || f.min <= 0 ? 0 : f.min;
        char k[5];
        fan_key(k, i, "md");
        if (smc_write_u8(k, 0)) { err = -1; continue; }
        fan_key(k, i, "Tg");
        if (min > 0) smc_write_float(k, min);
    }
    return err;
}

static int ensure_manual(const float *rpm) {
    int err = 0;
    for (int i = 0; i < nfans; i++) {
        fan_state f;
        if (read_fan(i, &f)) { err = -1; continue; }
        if ((f.mode != 1 || fabsf(f.target - rpm[i]) > 1) && write_manual(i, rpm[i])) err = -1;
    }
    return err;
}

// ---- daemon status file (/var/run/fanctl.status), read by the CLI and the menu bar app ----

typedef struct { char control[1024], setting[32], mode[8], reason[16]; int guard; } daemon_status;

static int read_daemon_status(daemon_status *st) {
    struct stat sb;
    if (stat(STATUS_PATH, &sb) || time(NULL) - sb.st_mtime > STATUS_FRESH_SECS) return -1;
    FILE *fp = fopen(STATUS_PATH, "r");
    if (!fp) return -1;
    memset(st, 0, sizeof(*st));
    char line[1100];
    while (fgets(line, sizeof line, fp)) {
        line[strcspn(line, "\n")] = 0;
        if (!strncmp(line, "control=", 8)) strlcpy(st->control, line + 8, sizeof st->control);
        else if (!strncmp(line, "setting=", 8)) strlcpy(st->setting, line + 8, sizeof st->setting);
        else if (!strncmp(line, "mode=", 5)) strlcpy(st->mode, line + 5, sizeof st->mode);
        else if (!strncmp(line, "guard=", 6)) st->guard = atoi(line + 6);
        else if (!strncmp(line, "reason=", 7)) strlcpy(st->reason, line + 7, sizeof st->reason);
    }
    fclose(fp);
    return st->control[0] ? 0 : -1;
}

// Atomic replace (write a fresh temp file + rename).
static int write_file_atomic(const char *path, const char *content, mode_t perm) {
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    unlink(tmp);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, perm);
    if (fd < 0) return -1;
    size_t len = strlen(content);
    int ok = write(fd, content, len) == (ssize_t)len;
    close(fd);
    if (!ok || rename(tmp, path)) { unlink(tmp); return -1; }
    return 0;
}

// ---- CLI commands ----

static int power_ready, power_primed;

static void start_power(void) {
    power_ready = m_power_open() == 0;
    power_primed = 0;
}

static void print_power(void) {
    m_power p = {0};
    int pending = power_ready && !power_primed;
    power_primed = 1;
    int ok = power_ready && !pending && m_power_sample(&p) == 0;
    if (pending) {
        printf("Power: CPU / GPU / ANE / DRAM / Subtotal: sampling\n");
    } else {
        const char *names[] = {"CPU", "GPU", "ANE", "DRAM"};
        double watts[] = {p.cpu_w, p.gpu_w, p.ane_w, p.dram_w};
        int valid[] = {p.cpu_valid, p.gpu_valid, p.ane_valid, p.dram_valid};
        printf("Power: ");
        for (int i = 0; i < 4; i++) {
            printf("%s%s ", i ? " | " : "", names[i]);
            if (ok && valid[i]) printf("%.2f W", watts[i]); else printf("N/A");
        }
        if (ok && p.cpu_valid)
            printf("\nCPU: %.2fs measurement window; updated %.1fs ago", p.cpu_interval_s, p.cpu_age_s);
        printf("\nSubtotal (CPU+GPU+ANE+DRAM): ");
        if (ok && p.valid && p.ane_valid && p.dram_valid)
            printf("%.2f W\n", p.cpu_w + p.gpu_w + p.ane_w + p.dram_w);
        else printf("N/A\n");
    }
    float system_w;
    printf("System (SMC PSTR): ");
    int have_system = !smc_read_float("PSTR", &system_w) && isfinite(system_w) && system_w >= 0;
    if (have_system) printf("%.2f W\n", system_w);
    else printf("N/A\n");
    // PSTR includes what the USB ports deliver to external devices (lamp test, 2026-09-24).
    float usb_w = m_usb_w();
    printf("USB ports out (PU1C+PU2C+PU3C+PUAC): %.2f W\n", usb_w);
    if (have_system) printf("Mac body (PSTR - USB out): %.2f W\n", fmaxf(0, system_w - usb_w));
    printf("Other channels (overlap unknown; excluded from subtotal):\n");
    if (pending) printf("  sampling\n");
    else if (!ok || !p.n_other) printf("  N/A\n");
    else {
        for (int i = 0; i < p.n_other; i++) {
            printf("  %-20s ", p.other[i].name);
            if (p.other[i].valid) printf("%7.2f W", p.other[i].watts);
            else printf("    N/A  ");
            if (i % 2 || i == p.n_other - 1) putchar('\n');
        }
        if (p.other_truncated) printf("  (additional channels omitted)\n");
    }
}

static int monitoring;  // set by watch (and set, which watches); the Ctrl-C hint only makes sense there

static void print_status(void) {
    temp_stat c = read_family(&cpu_fam), g = read_family(&gpu_fam);
    printf("CPU avg %5.1f °C  (max %5.1f, %d sensors)\n", c.avg, c.max, c.n);
    printf("GPU avg %5.1f °C  (max %5.1f, %d sensors)\n", g.avg, g.max, g.n);
    print_power();
    for (int i = 0; i < nfans; i++) {
        fan_state f;
        if (read_fan(i, &f)) continue;
        float pct = f.max > f.min ? 100.0f * (f.actual - f.min) / (f.max - f.min) : 0;
        printf("Fan%d %5.0f rpm  (%3.0f%%)  target %4.0f  range %.0f–%.0f  %s\n", i, f.actual,
               pct < 0 ? 0 : pct, f.target, f.min, f.max, f.mode ? "MANUAL" : "auto");
    }
    daemon_status st;
    if (!read_daemon_status(&st))
        printf("fanctld: setting %s%s\n%s",
               st.setting, st.guard ? "  (thermal guard tripped — fans at full speed until it cools down)"
               : !strcmp(st.reason, "no-sensors") ? "  (no temperature sensor readable — fans on auto)"
               : !strcmp(st.reason, "read-error") ? "  (fan state unreadable — fans on auto)" : "",
               monitoring ? "Ctrl-C only exits monitoring; fanctl auto restores automatic control.\n" : "");
}

static void cmd_watch(double interval) {
    monitoring = 1;
    start_power();
    for (;;) {
        printf("\033[H\033[2J");
        print_status();
        printf("\n(Ctrl-C to quit)\n");
        fflush(stdout);
        usleep((useconds_t)(interval * 1e6));
    }
}

// Become the user who ran sudo: supplementary groups first (initgroups), then gid, then uid.
static int drop_to_sudo_user(void) {
    const char *uid_s = getenv("SUDO_UID"), *gid_s = getenv("SUDO_GID");
    if (!uid_s || !gid_s) return -1;
    char *end;
    errno = 0;
    unsigned long uid = strtoul(uid_s, &end, 10);
    if (errno || *end || !*uid_s || uid == 0) return -1;
    unsigned long gid = strtoul(gid_s, &end, 10);
    if (errno || *end || !*gid_s) return -1;
    struct passwd *pw = getpwuid((uid_t)uid);
    if (!pw || initgroups(pw->pw_name, (int)gid) || setgid((gid_t)gid) || setuid((uid_t)uid)) return -1;
    return setuid(0) == 0 ? -1 : 0;  // must not be able to regain root
}

// If fanctld is running, settings go through its control file so the two never fight.
// The control file lives in the user's home, so never touch it with root privileges.
static int delegate_to_daemon(const char *setting) {
    daemon_status st;
    if (read_daemon_status(&st)) return 0;
    if (geteuid() == 0 && drop_to_sudo_user()) die("fanctld is running — run this without sudo");
    char line[64];
    snprintf(line, sizeof line, "%s\n", setting);
    if (write_file_atomic(st.control, line, 0644)) die("cannot write the fanctld control file");
    printf("fanctld: setting → %s\n", setting);
    return 1;
}

static volatile sig_atomic_t stop;
static void on_signal(int sig) { (void)sig; stop = 1; }

static int manual_active;
static void restore_at_exit(void) { if (manual_active) force_auto(); }

static void catch_signals(void) {
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGQUIT, on_signal);
}

// Without the daemon: holds manual mode until Ctrl-C / signal, the thermal guard, or `duration`
// seconds (0 = forever), then returns the fans to auto.
static void cmd_set(const char *arg, float guard, int duration, int flags_given) {
    fan_state f[MAX_FANS];
    float target[MAX_FANS];
    for (int i = 0; i < nfans; i++) {
        if (read_fan(i, &f[i])) die("cannot read fan state");
        int r = parse_setting(arg, &f[i], &target[i]);
        if (r < 0) die("target must be an rpm number or a percentage like 50%");
        if (r == 1) die("use `fanctl auto` for automatic control");
    }
    daemon_status st;
    if (flags_given && !read_daemon_status(&st))
        die("--for/--guard only apply without fanctld; the daemon holds settings until changed and uses a fixed "
            "100 °C guard (fans to full speed above it)");
    if (delegate_to_daemon(arg)) { cmd_watch(1.0); return; }
    require_root();
    catch_signals();
    atexit(restore_at_exit);
    manual_active = 1;
    for (int i = 0; i < nfans; i++)
        if (write_manual(i, target[i])) {
            fprintf(stderr, "fanctl: SMC rejected the write for Fan%d (SMC result 0x%02x)\n", i, smc_last_result);
            exit(1);  // atexit handler returns the fans to auto
        }
    start_power();
    int interactive = isatty(STDOUT_FILENO) && !duration;
    if (!interactive)
        printf("Fans set to manual. Ctrl-C returns them to auto. Thermal guard: %.0f °C (max sensor) → full speed.\n"
               "Power subtotal includes DRAM; other channels and System are separate.\n\n", guard);
    float full[MAX_FANS];
    for (int i = 0; i < nfans; i++) full[i] = f[i].max;
    int tripped = 0;
    for (int t = 0; !stop && (!duration || t < duration); t++) {
        temp_stat c = read_family(&cpu_fam), g = read_family(&gpu_fam);
        if (!c.n && !g.n) {
            printf("\nNo temperature sensor readable — returning to auto.\n");
            break;
        }
        float hot = fmaxf(c.max, g.max);
        if (!tripped && hot > guard) {
            tripped = 1;
            printf("\nThermal guard: %.1f °C — fans to full speed until below %.0f °C.\n", hot, guard - GUARD_HYST_C);
        } else if (tripped && hot < guard - GUARD_HYST_C) {
            tripped = 0;
            printf("\nThermal guard released (%.1f °C) — back to the requested speed.\n", hot);
        }
        ensure_manual(tripped ? full : target);  // also re-asserts if the firmware dropped us to auto
        if (interactive) {
            printf("\033[H\033[2JFan control: manual | Ctrl-C: auto | Thermal guard: %.0f °C (max) → full speed%s\n"
                   "Power subtotal includes DRAM; other channels and System are separate.\n\n", guard,
                   tripped ? "  [TRIPPED]" : "");
        }
        printf("CPU avg %5.1f °C  |  GPU avg %5.1f °C\n", c.avg, g.avg);
        print_power();
        for (int i = 0; i < nfans; i++) {
            fan_state now;
            if (read_fan(i, &now)) continue;
            printf("Fan%d %5.0f/%4.0f rpm\n", i, now.actual, tripped ? full[i] : target[i]);
        }
        if (!interactive) printf("\n");
        fflush(stdout);
        sleep(1);
    }
    manual_active = 0;
    if (force_auto()) die("\nfailed to return fans to auto — run: sudo fanctl auto");
    printf("\nFans returned to auto.\n");
}

static void cmd_auto(void) {
    if (delegate_to_daemon("auto")) return;
    require_root();
    if (force_auto()) die("SMC rejected the write");
    printf("Fans returned to auto.\n");
}

static void cmd_dump(const char *prefix) {
    uint32_t n;
    if (smc_count(&n)) die("cannot read SMC key count");
    for (uint32_t i = 0; i < n; i++) {
        char k[5];
        smc_val v;
        if (smc_key_at(i, k) || strncmp(k, prefix, strlen(prefix))) continue;
        int r = smc_read(k, &v);
        printf("%s  %-4s size=%-2u attr=0x%02x  ", k, v.type, v.size, v.attr);
        if (r) { printf("(read error)\n"); continue; }
        if (!strcmp(v.type, "flt ") && v.size == 4) { float fv; memcpy(&fv, v.bytes, 4); printf("%.3f", fv); }
        else for (uint32_t j = 0; j < v.size && j < 32; j++) printf("%02x", v.bytes[j]);
        printf("\n");
    }
}

// ---- daemon ----
//
// Polls the user-owned control file once a second and drives the fans to match. The file is
// untrusted input to a root process: it is opened without following symlinks, must be a regular
// single-link file owned by the owner of its directory (so it cannot alias a root file), and only
// a validated setting is ever echoed into the status file or the log.

static const char *ctl_path;
static char cur_setting[32];
static int guard_tripped, asleep, blind, read_failures;
static double resume_at;
static io_connect_t pm_root;

static void logf_(const char *fmt, const char *arg);

// Setting-change lines come from a user-writable file polled every second; cap them so the
// root-owned log cannot be flooded.
static void log_setting(const char *setting) {
    static time_t last;
    static int suppressed;
    time_t now = time(NULL);
    if (now - last < 10) { suppressed++; return; }
    char msg[96];
    if (suppressed) snprintf(msg, sizeof msg, "setting → %s (%d earlier changes not logged)", setting, suppressed);
    else snprintf(msg, sizeof msg, "setting → %s", setting);
    last = now;
    suppressed = 0;
    logf_("%s", msg);
}

static void logf_(const char *fmt, const char *arg) {
    char ts[32];
    time_t now = time(NULL);
    strftime(ts, sizeof ts, "%F %T", localtime(&now));
    fprintf(stderr, "%s fanctld: ", ts);
    fprintf(stderr, fmt, arg);
    fputc('\n', stderr);
}

static uid_t ctl_owner;

static void read_control(char *out, size_t n) {
    strlcpy(out, "auto", n);
    int fd = open(ctl_path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return;
    struct stat sb;
    char buf[32] = {0};
    if (!fstat(fd, &sb) && S_ISREG(sb.st_mode) && sb.st_nlink == 1 && sb.st_uid == ctl_owner &&
        read(fd, buf, sizeof buf - 1) > 0) {
        buf[strcspn(buf, " \t\r\n")] = 0;
        if (buf[0]) strlcpy(out, buf, n);
    }
    close(fd);
}

// reason: "" (following the setting), "guard" (full speed, too hot), "no-sensors" or "read-error"
// (handed to firmware auto because we cannot see what we are controlling).
static void write_status(const char *setting, int manual, float rpm0, const char *reason) {
    static char last[1400];
    static int ticks;
    char s[1400];
    snprintf(s, sizeof s, "control=%s\nsetting=%s\nmode=%s\ntarget=%.0f\nguard=%d\nreason=%s\n", ctl_path, setting,
             manual ? "manual" : "auto", rpm0, guard_tripped, reason);
    // Rewrite on change, otherwise every 5 s as a heartbeat (freshness = daemon alive).
    if (!strcmp(s, last) && ++ticks < 5) return;
    ticks = 0;
    strlcpy(last, s, sizeof last);
    write_file_atomic(STATUS_PATH, s, 0644);
}

static void tick(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    if (stop) {
        int err = force_auto();
        unlink(STATUS_PATH);
        logf_("%s", err ? "stopping — FAILED to return fans to auto (run: sudo fanctl auto)"
                        : "stopping, fans returned to auto");
        CFRunLoopStop(CFRunLoopGetCurrent());
        return;
    }
    if (asleep) return;
    if (CFAbsoluteTimeGetCurrent() < resume_at) {
        utimes(STATUS_PATH, NULL);  // still alive while the SMC settles after wake
        return;
    }

    char s[32];
    read_control(s, sizeof s);
    float rpm[MAX_FANS] = {0}, full[MAX_FANS] = {0};
    int manual = 0, valid = 1;
    for (int i = 0; i < nfans; i++) {
        fan_state f;
        if (read_fan(i, &f)) {
            // One failed read is not a setting change: keep the current state. A persistent failure
            // means we can neither guard nor re-assert, so hand the fans to the firmware.
            if (++read_failures < 3) { utimes(STATUS_PATH, NULL); return; }
            if (read_failures == 3) logf_("%s", "fan state unreadable for 3 s — fans handed to firmware auto");
            force_auto();
            guard_tripped = 0;
            write_status(cur_setting[0] ? cur_setting : "auto", 0, 0, "read-error");
            return;
        }
        full[i] = f.max;
        int r = parse_setting(s, &f, &rpm[i]);
        if (r < 0) valid = 0;
        if (r == 0) manual = 1;
    }
    read_failures = 0;
    if (!valid) strlcpy(s, "invalid", sizeof s);
    if (strcmp(s, cur_setting)) {
        strlcpy(cur_setting, s, sizeof cur_setting);
        log_setting(s);
    }

    int drive_manual = manual && valid;
    const char *reason = "";
    if (drive_manual) {
        temp_stat c = read_family(&cpu_fam), g = read_family(&gpu_fam);
        float hot = fmaxf(c.max, g.max);
        if (!c.n && !g.n) {
            // Flying blind: let the firmware's own thermal control run.
            if (!blind) logf_("%s", "no temperature sensor readable — fans on auto");
            blind = 1;
            guard_tripped = 0;
            drive_manual = 0;
            reason = "no-sensors";
        } else {
            blind = 0;
            if (!guard_tripped && hot > GUARD_C) {
                guard_tripped = 1;
                logf_("%s", "thermal guard tripped — fans to full speed until the hottest sensor cools down");
            } else if (guard_tripped && hot < GUARD_C - GUARD_HYST_C) {
                guard_tripped = 0;
                logf_("%s", "thermal guard released — back to the requested speed");
            }
            if (guard_tripped) reason = "guard";
        }
    } else {
        guard_tripped = blind = 0;  // firmware auto is in charge; nothing to guard
    }
    const float *drive = guard_tripped ? full : rpm;
    if (drive_manual) ensure_manual(drive);
    else ensure_auto();
    write_status(s, drive_manual, drive_manual ? drive[0] : 0, reason);
}

static void power_cb(void *ref, io_service_t svc, natural_t type, void *arg) {
    (void)ref; (void)svc;
    switch (type) {
    case kIOMessageCanSystemSleep:
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemWillSleep:
        asleep = 1;
        force_auto();  // never leave fans pinned while asleep; re-applied after wake
        IOAllowPowerChange(pm_root, (long)arg);
        break;
    case kIOMessageSystemHasPoweredOn:
        asleep = 0;
        resume_at = CFAbsoluteTimeGetCurrent() + 3;  // let the SMC settle before re-applying
        utimes(STATUS_PATH, NULL);  // the file aged during sleep; readers would think we died
        break;
    }
}

static void cmd_daemon(const char *control) {
    require_root();
    ctl_path = control;
    char dir[1024];
    strlcpy(dir, control, sizeof dir);
    char *slash = strrchr(dir, '/');
    struct stat sb;
    if (!slash || (*slash = 0, stat(dir, &sb))) die("control file directory does not exist");
    ctl_owner = sb.st_uid;
    catch_signals();
    IONotificationPortRef port;
    io_object_t notifier;
    pm_root = IORegisterForSystemPower(NULL, &port, power_cb, &notifier);
    if (pm_root) CFRunLoopAddSource(CFRunLoopGetCurrent(), IONotificationPortGetRunLoopSource(port), kCFRunLoopDefaultMode);
    else logf_("%s", "warning: no sleep/wake notifications");
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1.0, 0, 0, tick, NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, kCFRunLoopDefaultMode);
    logf_("started, control file %s", control);
    CFRunLoopRun();
}

static void usage(void) {
    fprintf(stderr,
            "usage: fanctl [status]\n"
            "       fanctl watch [-i secs]\n"
            "       fanctl set <rpm|N%%> [--guard °C] [--for secs]\n"
            "       fanctl auto\n"
            "       fanctl daemon <control-file>\n"
            "       fanctl dump [prefix]\n");
    exit(2);
}

int main(int argc, char **argv) {
    const char *cmd = argc > 1 ? argv[1] : "status";
    init();
    if (!strcmp(cmd, "status")) {
        start_power();
        if (power_ready) {
            // A one-shot status needs a fresh hardware interval, not just a 250ms poll.
            m_power p;
            for (int i = 0; i < 30; i++) {
                usleep(100000);
                if (!m_power_sample(&p) && p.valid && p.ane_valid && p.dram_valid) break;
            }
            power_primed = 1;
        }
        print_status();
    }
    else if (!strcmp(cmd, "watch")) cmd_watch(argc > 3 && !strcmp(argv[2], "-i") ? atof(argv[3]) : 1.0);
    else if (!strcmp(cmd, "set") && argc > 2) {
        float guard = GUARD_C;
        int duration = 0, flags = 0;
        for (int i = 3; i < argc; i += 2) {
            if (i + 1 >= argc) usage();
            if (!strcmp(argv[i], "--guard")) guard = (float)atof(argv[i + 1]);
            else if (!strcmp(argv[i], "--for")) duration = atoi(argv[i + 1]);
            else usage();
            flags = 1;
        }
        cmd_set(argv[2], guard, duration, flags);
    } else if (!strcmp(cmd, "auto")) cmd_auto();
    else if (!strcmp(cmd, "daemon") && argc > 2) cmd_daemon(argv[2]);
    else if (!strcmp(cmd, "dump")) cmd_dump(argc > 2 ? argv[2] : "");
    else usage();
    smc_close();
    return 0;
}
