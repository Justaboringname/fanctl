// Drives fanctl.c's daemon tick and restore paths against tests/fake_smc.c.
#define STATUS_PATH "build/test.status"
#define main fanctl_main
#include "../fanctl.c"
#undef main
#include <assert.h>

// stderr is silenced (daemon log lines), so report failures on stdout.
#define CHECK(c) do { if (!(c)) { printf("FAIL line %d: %s\n", __LINE__, #c); exit(1); } } while (0)

extern float fake_temp, fake_min, fake_max;
extern int fake_fail_reads, md_lag_reads;
uint8_t fake_md(int i);
float fake_tg(int i);

static const char *ctl = "build/test.control";
static void setting(const char *s) { FILE *f = fopen(ctl, "w"); fprintf(f, "%s\n", s); fclose(f); }

int main(void) {
    init();
    ctl_path = ctl;
    ctl_owner = getuid();
    freopen("/dev/null", "w", stderr);  // daemon log lines

    // 30% manual, cool: target = 1000 + 0.3 * 2625
    setting("30%"); fake_temp = 60; tick(NULL, NULL);
    CHECK(fake_md(0) == 1 && fabsf(fake_tg(0) - 1787.5f) < 0.1f && !guard_tripped);

    // Hot: guard drives both fans to MAX, not firmware auto.
    fake_temp = GUARD_C + 1; tick(NULL, NULL);
    CHECK(guard_tripped && fake_md(0) == 1 && fake_md(1) == 1 && fake_tg(0) == fake_max && fake_tg(1) == fake_max);
    // Still above the release point: stays at max; re-clicking the same setting changes nothing.
    fake_temp = GUARD_C - GUARD_HYST_C + 1; setting("30%"); tick(NULL, NULL);
    CHECK(guard_tripped && fake_tg(0) == fake_max);
    // Cooled below release: back to the user's 30% by itself.
    fake_temp = GUARD_C - GUARD_HYST_C - 1; tick(NULL, NULL);
    CHECK(!guard_tripped && fabsf(fake_tg(0) - 1787.5f) < 0.1f);

    // Transient SMC read failure: no state change, not treated as a setting change.
    fake_temp = GUARD_C + 1; tick(NULL, NULL); CHECK(guard_tripped);
    fake_fail_reads = 1; tick(NULL, NULL);
    CHECK(guard_tripped && fake_tg(0) == fake_max && !strcmp(cur_setting, "30%"));

    // Switching to auto hands back to firmware and clears the guard.
    setting("auto"); tick(NULL, NULL);
    CHECK(fake_md(0) == 0 && fake_md(1) == 0 && !guard_tripped && fake_tg(0) == fake_min);

    // Garbage setting → auto, reported as invalid.
    setting("fast"); tick(NULL, NULL); CHECK(fake_md(0) == 0 && !strcmp(cur_setting, "invalid"));

    // No temperature sensor readable: hand back to firmware auto, and do NOT claim the guard.
    setting("50%"); fake_temp = 60; tick(NULL, NULL); CHECK(fake_md(0) == 1);
    fake_temp = 500; tick(NULL, NULL);  // outside T_MAX → every sensor filtered out
    CHECK(fake_md(0) == 0 && !guard_tripped && blind);
    fake_temp = 60; tick(NULL, NULL); CHECK(fake_md(0) == 1 && !blind);

    // Persistent fan read failure: after 3 ticks force auto even though nothing is readable.
    fake_fail_reads = 100000;
    for (int i = 0; i < 5; i++) tick(NULL, NULL);
    CHECK(fake_md(0) == 0 && fake_md(1) == 0 && read_failures >= 3);
    fake_fail_reads = 0; tick(NULL, NULL);
    CHECK(read_failures == 0 && fake_md(0) == 1);  // recovers to the 50% setting

    setting("auto"); tick(NULL, NULL); CHECK(fake_md(0) == 0);  // precondition below: fans on auto

    // Readback lag: md written 1 but still reads 0. ensure_auto() would skip; force_auto() must not.
    md_lag_reads = 3;
    write_manual(0, 2000); write_manual(1, 2000);
    CHECK(fake_md(0) == 1);
    ensure_auto(); CHECK(fake_md(0) == 1);   // the old bug: readback says auto, nothing written
    force_auto(); CHECK(fake_md(0) == 0 && fake_md(1) == 0 && fake_tg(0) == fake_min);
    md_lag_reads = 0;

    // Missing fan range is an unreadable fan, not a 0 rpm target.
    fan_state f;
    fake_fail_reads = 0; fake_min = 0; CHECK(read_fan(0, &f) == -1); fake_min = 1000;
    CHECK(read_fan(0, &f) == 0);

    // parse_setting clamps and rejects junk.
    float r;
    CHECK(parse_setting("100%", &f, &r) == 0 && r == fake_max);
    CHECK(parse_setting("50", &f, &r) == 0 && r == fake_min);
    CHECK(parse_setting("50%x", &f, &r) == -1 && parse_setting("nan", &f, &r) == -1);
    puts("PASS: guard→max + hysteresis release, transient + persistent read failure, no sensors, auto/invalid, md readback lag, fan range");
    return 0;
}
