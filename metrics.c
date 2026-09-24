#include "metrics.h"
#include "power_rate.h"
#include "smc.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <ctype.h>
#include <ifaddrs.h>
#include <libproc.h>
#include <math.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <mach/mach.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int cfstr(CFStringRef s, char *buf, size_t n) {
    buf[0] = 0;
    return s && CFStringGetCString(s, buf, (CFIndex)n, kCFStringEncodingUTF8);
}

// ---------------------------------------------------------------- CPU usage

static char cluster_of[M_MAX_CPUS];
static uint64_t prev_ticks[M_MAX_CPUS][CPU_STATE_MAX];

// cluster-type ('P'/'M'/'E') per logical CPU from the IODeviceTree cpu nodes; CPU numbering is
// not contiguous per cluster on every chip, so never assume an order.
static void scan_clusters(void) {
    io_registry_entry_t cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus");
    io_iterator_t it;
    if (!cpus || IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &it)) return;
    io_object_t cpu;
    while ((cpu = IOIteratorNext(it))) {
        CFNumberRef id = IORegistryEntryCreateCFProperty(cpu, CFSTR("logical-cpu-id"), NULL, 0);
        CFDataRef type = IORegistryEntryCreateCFProperty(cpu, CFSTR("cluster-type"), NULL, 0);
        int n = -1;
        if (id && CFGetTypeID(id) == CFNumberGetTypeID()) CFNumberGetValue(id, kCFNumberIntType, &n);
        if (n >= 0 && n < M_MAX_CPUS && type && CFGetTypeID(type) == CFDataGetTypeID() && CFDataGetLength(type) > 0)
            cluster_of[n] = (char)CFDataGetBytePtr(type)[0];
        if (id) CFRelease(id);
        if (type) CFRelease(type);
        IOObjectRelease(cpu);
    }
    IOObjectRelease(it);
    IOObjectRelease(cpus);
}

int m_cpu_sample(m_cpu *out) {
    natural_t count;
    processor_info_array_t info;
    mach_msg_type_number_t len;
    memset(out, 0, sizeof(*out));
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &len)) return -1;
    processor_cpu_load_info_t load = (processor_cpu_load_info_t)info;
    int n = count > M_MAX_CPUS ? M_MAX_CPUS : (int)count;
    uint64_t user = 0, sys = 0, all = 0;
    for (int i = 0; i < n; i++) {
        uint64_t d[CPU_STATE_MAX], sum = 0;
        for (int s = 0; s < CPU_STATE_MAX; s++) {
            // Tick counters are 32-bit and wrap; unsigned subtraction handles one wrap.
            d[s] = (uint32_t)(load[i].cpu_ticks[s] - (uint32_t)prev_ticks[i][s]);
            prev_ticks[i][s] = load[i].cpu_ticks[s];
            sum += d[s];
        }
        uint64_t busy = d[CPU_STATE_USER] + d[CPU_STATE_SYSTEM] + d[CPU_STATE_NICE];
        out->core[i] = sum ? (double)busy / sum : 0;
        out->cluster[i] = cluster_of[i] ? cluster_of[i] : '?';
        user += d[CPU_STATE_USER] + d[CPU_STATE_NICE];
        sys += d[CPU_STATE_SYSTEM];
        all += sum;
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, len * sizeof(integer_t));
    out->ncpu = n;
    if (all) {
        out->user = (double)user / all;
        out->system = (double)sys / all;
        out->total = out->user + out->system;
    }
    return 0;
}

// ---------------------------------------------------------------- IOReport power

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

static IOReportSubscriptionRef sub;
static CFMutableDictionaryRef sub_channels;
static CFDictionaryRef prev_sample;
static double power_tick_s;

// Apple's IOReportElement layout: provider, channel, channel type, mach timestamp,
// then four 64-bit values. Copy rather than dereference unaligned CFData bytes.
// https://github.com/apple-oss-distributions/xnu/blob/main/iokit/IOKit/IOReportTypes.h
typedef struct {
    uint64_t provider, channel;
    uint8_t format, reserved;
    uint16_t categories, nelements;
    int16_t element_idx;
    uint64_t stamp, values[4];
} power_element;
_Static_assert(sizeof(power_element) == 64, "IOReportElement layout");
_Static_assert(__builtin_offsetof(power_element, stamp) == 24, "IOReport timestamp offset");

static struct {
    uint64_t provider, channel;
    power_rate rate;
} power_rates[128];
static size_t n_power_rates;

static double energy_unit_j(CFDictionaryRef ch) {
    char unit[16];
    cfstr(IOReportChannelGetUnitLabel(ch), unit, sizeof unit);
    if (!strcmp(unit, "J")) return 1;
    if (!strcmp(unit, "mJ")) return 1e-3;
    if (!strcmp(unit, "uJ")) return 1e-6;
    if (!strcmp(unit, "nJ")) return 1e-9;
    return NAN;
}

static double channel_watts(CFDictionaryRef ch, uint64_t now, double *window, double *age) {
    CFDataRef raw = CFDictionaryGetValue(ch, CFSTR("RawElements"));
    if (!raw || CFGetTypeID(raw) != CFDataGetTypeID() || CFDataGetLength(raw) != sizeof(power_element))
        return NAN;
    power_element e;
    memcpy(&e, CFDataGetBytePtr(raw), sizeof e);
    if (e.format != 1 || e.nelements != 1 || e.element_idx != 0) return NAN;
    size_t i;
    for (i = 0; i < n_power_rates; i++)
        if (power_rates[i].provider == e.provider && power_rates[i].channel == e.channel) break;
    if (i == n_power_rates) {
        if (n_power_rates == sizeof power_rates / sizeof *power_rates) return NAN;
        power_rates[i].provider = e.provider;
        power_rates[i].channel = e.channel;
        n_power_rates++;
    }
    power_rate *r = &power_rates[i].rate;
    double w = power_rate_update(r, IOReportSimpleGetIntegerValue(ch, 0), e.stamp,
                                 now, power_tick_s, energy_unit_j(ch));
    if (isfinite(w)) {
        if (window) *window = r->interval_s;
        if (age) *age = (now - e.stamp) * power_tick_s;
    }
    return w;
}

// "PCPU", "MCPU0", "ANE1"... : prefix followed only by digits (skips per-core "MCPU0_3", "PCPU0_SRAM").
static int is_cluster_name(const char *name, const char *prefix) {
    size_t n = strlen(prefix);
    if (strncmp(name, prefix, n)) return 0;
    for (const char *p = name + n; *p; p++)
        if (!isdigit((unsigned char)*p)) return 0;
    return 1;
}

static int other_energy_channel(const char *name) {
    // Observed on this machine: retain raw names instead of guessing rail meanings.
    // Do not include per-core, SRAM or DTL channels alongside their parent totals.
    const char *prefixes[] = {"AFR", "ISP", "AVE", "AVD", "MSR", "AMCC", "DCS",
                             "DISP", "DISPEXT", "FAB", "MCPM", "PCPM"};
    for (size_t i = 0; i < sizeof prefixes / sizeof *prefixes; i++)
        if (is_cluster_name(name, prefixes[i])) return 1;
    // Both PCIe families are diagnostic only; they may represent overlapping levels.
    return (!strncmp(name, "apciec", 6) || !strncmp(name, "PCIe Port ", 10)) && strstr(name, " Energy");
}

static int wanted_energy_channel(const char *name) {
    return !strcmp(name, "CPU Energy") || !strcmp(name, "GPU Energy") || is_cluster_name(name, "DRAM") ||
           is_cluster_name(name, "PCPU") || is_cluster_name(name, "MCPU") || is_cluster_name(name, "ECPU") ||
           is_cluster_name(name, "ANE") || other_energy_channel(name);
}

// Copies a channel group keeping only the channels `keep` accepts, so each sample stays small.
static CFMutableDictionaryRef filtered_group(CFStringRef group, CFStringRef subgroup, int (*keep)(const char *)) {
    CFDictionaryRef all = IOReportCopyChannelsInGroup(group, subgroup, 0, 0, 0);
    if (!all) return NULL;
    CFMutableDictionaryRef copy = CFDictionaryCreateMutableCopy(NULL, 0, all);
    CFArrayRef chans = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    if (keep && chans) {
        CFMutableArrayRef kept = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (CFIndex i = 0; i < CFArrayGetCount(chans); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(chans, i);
            char name[128];
            cfstr(IOReportChannelGetChannelName(ch), name, sizeof name);
            if (keep(name)) CFArrayAppendValue(kept, ch);
        }
        CFDictionarySetValue(copy, CFSTR("IOReportChannels"), kept);
        CFRelease(kept);
    }
    CFRelease(all);
    return copy;
}

int m_power_open(void) {
    if (sub) return prev_sample ? 0 : -1;
    CFMutableDictionaryRef energy = filtered_group(CFSTR("Energy Model"), NULL, wanted_energy_channel);
    if (!energy) return -1;
    CFMutableDictionaryRef gpu = filtered_group(CFSTR("GPU Stats"), CFSTR("GPU Performance States"), NULL);
    if (gpu) { IOReportMergeChannels(energy, gpu, NULL); CFRelease(gpu); }
    sub = IOReportCreateSubscription(NULL, energy, &sub_channels, 0, NULL);
    CFRelease(energy);
    if (!sub) return -1;
    prev_sample = IOReportCreateSamples(sub, sub_channels, NULL);
    mach_timebase_info_data_t tb;
    if (mach_timebase_info(&tb) != KERN_SUCCESS || !tb.denom) return -1;
    power_tick_s = (double)tb.numer / tb.denom / 1e9;
    // Prime from raw samples, preserving each provider's own update timestamp.
    CFArrayRef channels = prev_sample ? CFDictionaryGetValue(prev_sample, CFSTR("IOReportChannels")) : NULL;
    uint64_t now = mach_absolute_time();
    for (CFIndex i = 0; channels && i < CFArrayGetCount(channels); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(channels, i);
        CFStringRef group = IOReportChannelGetGroup(ch);
        if (group && CFEqual(group, CFSTR("Energy Model"))) channel_watts(ch, now, NULL, NULL);
    }
    return prev_sample ? 0 : -1;
}

int m_power_sample(m_power *out) {
    memset(out, 0, sizeof(*out));
    if (!sub || !prev_sample) return -1;
    CFDictionaryRef cur = IOReportCreateSamples(sub, sub_channels, NULL);
    if (!cur) return -1;
    uint64_t now = mach_absolute_time();
    CFDictionaryRef delta = IOReportCreateSamplesDelta(prev_sample, cur, NULL);
    CFRelease(prev_sample);
    prev_sample = cur;
    CFArrayRef chans = CFDictionaryGetValue(cur, CFSTR("IOReportChannels"));
    int ane_seen = 0, ane_bad = 0, dram_seen = 0, dram_bad = 0;
    for (CFIndex i = 0; chans && i < CFArrayGetCount(chans); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(chans, i);
        char group[64], name[64];
        cfstr(IOReportChannelGetGroup(ch), group, sizeof group);
        cfstr(IOReportChannelGetChannelName(ch), name, sizeof name);
        if (!strcmp(group, "Energy Model")) {
            double window = 0, age = 0;
            double w = channel_watts(ch, now, &window, &age);
            int valid = isfinite(w) && w >= 0;
            if (other_energy_channel(name)) {
                if (out->n_other < M_MAX_POWER_CHANNELS) {
                    m_power_channel *extra = &out->other[out->n_other++];
                    strlcpy(extra->name, name, sizeof extra->name);
                    extra->valid = valid;
                    if (valid) extra->watts = w;
                } else out->other_truncated = 1;
                continue;
            }
            if (is_cluster_name(name, "DRAM")) {
                dram_seen++;
                if (valid) out->dram_w += w; else dram_bad++;
                continue;
            }
            if (is_cluster_name(name, "ANE")) {
                ane_seen++;
                if (valid) out->ane_w += w; else ane_bad++;
                continue;
            }
            if (!isfinite(w) || w < 0) continue;
            if (!strcmp(name, "CPU Energy")) {
                out->cpu_w = w; out->cpu_valid = 1;
                out->cpu_interval_s = window; out->cpu_age_s = age;
            }
            else if (!strcmp(name, "GPU Energy")) { out->gpu_w = w; out->gpu_valid = 1; }
            else if (is_cluster_name(name, "PCPU")) out->cpu_p_w += w;
            else if (is_cluster_name(name, "MCPU")) out->cpu_m_w += w;
            else if (is_cluster_name(name, "ECPU")) out->cpu_e_w += w;
        }
    }
    // Residency percentages still use delta samples, independently of energy timing.
    CFArrayRef states = delta ? CFDictionaryGetValue(delta, CFSTR("IOReportChannels")) : NULL;
    for (CFIndex i = 0; states && i < CFArrayGetCount(states); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(states, i);
        CFStringRef name = IOReportChannelGetChannelName(ch);
        if (name && CFEqual(name, CFSTR("GPUPH"))) {
            int64_t off = 0, total = 0;
            for (int s = 0; s < IOReportStateGetCount(ch); s++) {
                char sn[32];
                int64_t r = IOReportStateGetResidency(ch, s);
                cfstr(IOReportStateGetNameForIndex(ch, s), sn, sizeof sn);
                if (!strcmp(sn, "OFF")) off += r;
                total += r;
            }
            out->gpu_active = total ? 1.0 - (double)off / total : 0;
        }
    }
    if (delta) CFRelease(delta);
    out->ane_valid = ane_seen > 0 && !ane_bad;
    out->dram_valid = dram_seen > 0 && !dram_bad;
    out->valid = out->cpu_valid && out->gpu_valid;
    return 0;
}

// ---------------------------------------------------------------- GPU utilization

static double dict_num(CFDictionaryRef d, CFStringRef key) {
    CFNumberRef n = CFDictionaryGetValue(d, key);
    double v = 0;
    if (n && CFGetTypeID(n) == CFNumberGetTypeID()) CFNumberGetValue(n, kCFNumberDoubleType, &v);
    return v;
}

int m_gpu_sample(m_gpu *out) {
    memset(out, 0, sizeof(*out));
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it)) return -1;
    io_object_t svc;
    int found = 0;
    while ((svc = IOIteratorNext(it))) {
        CFDictionaryRef stats = IORegistryEntryCreateCFProperty(svc, CFSTR("PerformanceStatistics"), NULL, 0);
        if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID() && !found) {
            out->device = dict_num(stats, CFSTR("Device Utilization %")) / 100;
            out->renderer = dict_num(stats, CFSTR("Renderer Utilization %")) / 100;
            out->tiler = dict_num(stats, CFSTR("Tiler Utilization %")) / 100;
            out->mem_in_use = (uint64_t)dict_num(stats, CFSTR("In use system memory"));
            out->mem_alloc = (uint64_t)dict_num(stats, CFSTR("Alloc system memory"));
            found = 1;
        }
        if (stats) CFRelease(stats);
        IOObjectRelease(svc);
    }
    IOObjectRelease(it);
    return found ? 0 : -1;
}

// ---------------------------------------------------------------- memory

// Same definitions as Activity Monitor: app = internal − purgeable, used = app + wired + compressed,
// cached files = external + purgeable. Pages are 16 KiB on Apple Silicon — use the kernel's size.
int m_mem_sample(m_mem *out) {
    memset(out, 0, sizeof(*out));
    vm_statistics64_data_t vm;
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt)) return -1;
    uint64_t page = vm_kernel_page_size;
    size_t len = sizeof(out->total);
    sysctlbyname("hw.memsize", &out->total, &len, NULL, 0);
    out->app = (uint64_t)(vm.internal_page_count - vm.purgeable_count) * page;
    out->wired = (uint64_t)vm.wire_count * page;
    out->compressed = (uint64_t)vm.compressor_page_count * page;
    out->cached = (uint64_t)(vm.external_page_count + vm.purgeable_count) * page;
    out->used = out->app + out->wired + out->compressed;
    struct xsw_usage swap;
    len = sizeof(swap);
    if (!sysctlbyname("vm.swapusage", &swap, &len, NULL, 0)) {
        out->swap_total = swap.xsu_total;
        out->swap_used = swap.xsu_used;
    }
    len = sizeof(out->pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &out->pressure, &len, NULL, 0);
    return 0;
}

// ---------------------------------------------------------------- network

static uint64_t prev_rx, prev_tx, session_rx, session_tx;
static char prev_iface[16];
static double prev_net_t;

static void primary_interface(char *out, size_t n) {
    out[0] = 0;
    CFDictionaryRef v = SCDynamicStoreCopyValue(NULL, CFSTR("State:/Network/Global/IPv4"));
    if (!v) return;
    CFStringRef name = CFDictionaryGetValue(v, CFSTR("PrimaryInterface"));
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) cfstr(name, out, n);
    CFRelease(v);
}

// Byte counters via NET_RT_IFLIST2. On macOS 27 the kernel only hands full 64-bit counts to
// callers holding com.apple.private.network.statistics (netstat); everyone else gets them
// truncated to 32 bits, so deltas are taken modulo 2^32 and totals are accumulated per session.
static int iface_bytes(const char *iface, uint64_t *rx, uint64_t *tx) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0};
    size_t len;
    if (sysctl(mib, 6, NULL, &len, NULL, 0)) return -1;
    char *buf = malloc(len);
    if (!buf || sysctl(mib, 6, buf, &len, NULL, 0)) { free(buf); return -1; }
    int found = -1;
    for (char *p = buf; p < buf + len;) {
        struct if_msghdr *ifm = (struct if_msghdr *)p;
        if (ifm->ifm_type == RTM_IFINFO2) {
            struct if_msghdr2 *m2 = (struct if_msghdr2 *)p;
            char name[IF_NAMESIZE];
            if (if_indextoname(m2->ifm_index, name) && !strcmp(name, iface)) {
                *rx = m2->ifm_data.ifi_ibytes;
                *tx = m2->ifm_data.ifi_obytes;
                found = 0;
                break;
            }
        }
        p += ifm->ifm_msglen;
    }
    free(buf);
    return found;
}

static void iface_ipv4(const char *iface, char *out, size_t n) {
    out[0] = 0;
    struct ifaddrs *list;
    if (getifaddrs(&list)) return;
    for (struct ifaddrs *a = list; a; a = a->ifa_next)
        if (a->ifa_addr && a->ifa_addr->sa_family == AF_INET && !strcmp(a->ifa_name, iface)) {
            inet_ntop(AF_INET, &((struct sockaddr_in *)a->ifa_addr)->sin_addr, out, (socklen_t)n);
            break;
        }
    freeifaddrs(list);
}

int m_net_sample(m_net *out) {
    memset(out, 0, sizeof(*out));
    primary_interface(out->iface, sizeof out->iface);
    double t = now_s();
    uint64_t rx = 0, tx = 0;
    if (!out->iface[0] || iface_bytes(out->iface, &rx, &tx)) {
        prev_iface[0] = 0;
        return 0;
    }
    iface_ipv4(out->iface, out->ipv4, sizeof out->ipv4);
    // Only compute a rate against a baseline from the same interface (switching Wi-Fi ↔ Ethernet
    // would otherwise produce a huge bogus spike).
    if (!strcmp(prev_iface, out->iface) && t > prev_net_t) {
        uint64_t drx = (uint32_t)((uint32_t)rx - (uint32_t)prev_rx), dtx = (uint32_t)((uint32_t)tx - (uint32_t)prev_tx);
        out->rx_bps = drx / (t - prev_net_t);
        out->tx_bps = dtx / (t - prev_net_t);
        session_rx += drx;
        session_tx += dtx;
    }
    out->rx_total = session_rx;
    out->tx_total = session_tx;
    strlcpy(prev_iface, out->iface, sizeof prev_iface);
    prev_rx = rx;
    prev_tx = tx;
    prev_net_t = t;
    return 0;
}

// ---------------------------------------------------------------- sensors (SMC + IOHID)

#define MAX_KEYS 256
static char cpu_keys[MAX_KEYS][5], gpu_keys[MAX_KEYS][5];
static int ncpu_keys, ngpu_keys, nfans;

static void scan_smc(void) {
    uint32_t n;
    uint8_t f = 0;
    if (!smc_read_u8("FNum", &f)) nfans = f > M_MAX_FANS ? M_MAX_FANS : f;
    if (smc_count(&n)) return;
    for (uint32_t i = 0; i < n; i++) {
        char k[5];
        float v;
        if (smc_key_at(i, k) || k[0] != 'T' || smc_read_float(k, &v)) continue;
        if (k[1] == 'p' && k[2] == '0' && ncpu_keys < MAX_KEYS) memcpy(cpu_keys[ncpu_keys++], k, 5);
        else if (k[1] == 'g' && ngpu_keys < MAX_KEYS) memcpy(gpu_keys[ngpu_keys++], k, 5);
    }
}

static void family_stat(char keys[][5], int n, float *max, float *avg) {
    double sum = 0;
    int cnt = 0;
    *max = *avg = 0;
    for (int i = 0; i < n; i++) {
        float v;
        if (smc_read_float(keys[i], &v) || v < 5 || v > 130) continue;
        sum += v;
        if (v > *max) *max = v;
        cnt++;
    }
    if (cnt) *avg = (float)(sum / cnt);
}

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
#define kHIDTemperature 15

static IOHIDServiceClientRef ssd_sensor;

static void find_ssd_sensor(void) {
    IOHIDEventSystemClientRef sys = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!sys) return;
    int page = 0xff00, usage = 5;
    CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")}, *v[] = {p, u};
    CFDictionaryRef match = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(sys, match);
    CFArrayRef svcs = IOHIDEventSystemClientCopyServices(sys);
    for (CFIndex i = 0; svcs && i < CFArrayGetCount(svcs); i++) {
        IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs, i);
        CFStringRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
        char buf[64];
        if (cfstr(name, buf, sizeof buf) && !strcmp(buf, "NAND CH0 temp")) ssd_sensor = (IOHIDServiceClientRef)CFRetain(s);
        if (name) CFRelease(name);
    }
    if (svcs) CFRelease(svcs);
    CFRelease(match);
    CFRelease(p);
    CFRelease(u);
    // `sys` stays alive for the process lifetime; the service client references it.
}

// USB port rails, each V5SC (5.2 V) x IUxC. On Mac17,14 PU1C carries rear USB-C 1-2 (verified with a
// lamp on port 2), PU2C tracks ports 3-4 (DnJV x DnJI); PU3C/PUAC are presumably the front USB-C and
// USB-A ports (by name only, ~0.03 W idle). Keys missing on other Macs just contribute 0.
float m_usb_w(void) {
    static const char *keys[] = {"PU1C", "PU2C", "PU3C", "PUAC"};
    float sum = 0;
    for (int i = 0; i < 4; i++) {
        float v;
        if (!smc_read_float(keys[i], &v) && isfinite(v) && v > 0) sum += v;
    }
    return sum;
}

int m_sensors_sample(m_sensors *out) {
    memset(out, 0, sizeof(*out));
    family_stat(cpu_keys, ncpu_keys, &out->cpu_max, &out->cpu_avg);
    family_stat(gpu_keys, ngpu_keys, &out->gpu_max, &out->gpu_avg);
    smc_read_float("PSTR", &out->sys_w);
    out->usb_w = m_usb_w();
    if (ssd_sensor) {
        IOHIDEventRef e = IOHIDServiceClientCopyEvent(ssd_sensor, kHIDTemperature, 0, 0);
        if (e) {
            out->ssd = (float)IOHIDEventGetFloatValue(e, kHIDTemperature << 16);
            CFRelease(e);
        }
    }
    out->nfans = nfans;
    for (int i = 0; i < nfans; i++) {
        char k[5];
        uint8_t md = 0;
        m_fan *f = &out->fan[i];
        snprintf(k, 5, "F%dAc", i); smc_read_float(k, &f->actual);
        snprintf(k, 5, "F%dTg", i); smc_read_float(k, &f->target);
        snprintf(k, 5, "F%dMn", i); smc_read_float(k, &f->min);
        snprintf(k, 5, "F%dMx", i); smc_read_float(k, &f->max);
        snprintf(k, 5, "F%dmd", i); smc_read_u8(k, &md);
        f->manual = md != 0;
    }
    return 0;
}

// ---------------------------------------------------------------- processes

typedef struct { int pid; uint64_t start, cpu, energy; } proc_prev;
static proc_prev *prev_procs;
static int nprev_procs;
static double prev_procs_t;

static int cmp_prev(const void *a, const void *b) { return ((const proc_prev *)a)->pid - ((const proc_prev *)b)->pid; }
static int cmp_cpu(const void *a, const void *b) { double d = ((const m_proc *)b)->cpu - ((const m_proc *)a)->cpu; return (d > 0) - (d < 0); }
static int cmp_watts(const void *a, const void *b) { double d = ((const m_proc *)b)->watts - ((const m_proc *)a)->watts; return (d > 0) - (d < 0); }
static int cmp_mem(const void *a, const void *b) {
    uint64_t x = ((const m_proc *)a)->mem, y = ((const m_proc *)b)->mem;
    return (y > x) - (y < x);
}

int m_procs_sample(m_procs *out) {
    memset(out, 0, sizeof(*out));
    int cap = proc_listallpids(NULL, 0) + 64;
    int *pids = malloc(sizeof(int) * cap);
    if (!pids) return -1;
    int n = proc_listallpids(pids, sizeof(int) * cap);
    if (n < 0) { free(pids); return -1; }
    if (n > cap) n = cap;
    proc_prev *cur = malloc(sizeof(proc_prev) * (n ? n : 1));
    m_proc *rows = malloc(sizeof(m_proc) * (n ? n : 1));
    if (!cur || !rows) { free(pids); free(cur); free(rows); return -1; }

    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    double t = now_s(), dt = t - prev_procs_t;
    int ncur = 0, nrows = 0;
    for (int i = 0; i < n; i++) {
        struct rusage_info_v6 ri;
        if (pids[i] <= 0 || proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&ri)) continue;
        uint64_t cpu = ri.ri_user_time + ri.ri_system_time;  // mach time units
        proc_prev key = {pids[i], ri.ri_proc_start_abstime, cpu, ri.ri_energy_nj};
        cur[ncur++] = key;
        m_proc *r = &rows[nrows++];
        memset(r, 0, sizeof(*r));
        r->pid = pids[i];
        r->mem = ri.ri_phys_footprint;
        proc_name(pids[i], r->name, sizeof r->name);
        // Rates only against the same process instance (a reused pid has a different start time).
        proc_prev *p = prev_procs ? bsearch(&key, prev_procs, nprev_procs, sizeof(proc_prev), cmp_prev) : NULL;
        if (p && p->start == key.start && dt > 0 && cpu >= p->cpu && key.energy >= p->energy) {
            r->cpu = (double)(cpu - p->cpu) * tb.numer / tb.denom / 1e9 / dt;  // cores busy, 1.0 = one core
            r->watts = (double)(key.energy - p->energy) / 1e9 / dt;
        }
    }
    free(pids);
    qsort(cur, ncur, sizeof(proc_prev), cmp_prev);
    free(prev_procs);
    prev_procs = cur;
    nprev_procs = ncur;
    prev_procs_t = t;

    out->readable = nrows;
    out->total = n;
    out->n = nrows < M_TOP_PROCS ? nrows : M_TOP_PROCS;
    qsort(rows, nrows, sizeof(m_proc), cmp_cpu);
    memcpy(out->by_cpu, rows, sizeof(m_proc) * out->n);
    qsort(rows, nrows, sizeof(m_proc), cmp_watts);
    memcpy(out->by_power, rows, sizeof(m_proc) * out->n);
    qsort(rows, nrows, sizeof(m_proc), cmp_mem);
    memcpy(out->by_mem, rows, sizeof(m_proc) * out->n);
    free(rows);
    return 0;
}

// ----------------------------------------------------------------

int m_open(void) {
    if (smc_open()) return -1;
    scan_smc();
    scan_clusters();
    find_ssd_sensor();
    m_cpu c;
    m_net n;
    m_cpu_sample(&c);  // prime baselines
    m_net_sample(&n);
    if (m_power_open()) return -2;
    return 0;
}
