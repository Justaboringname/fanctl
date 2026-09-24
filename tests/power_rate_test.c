#include "../power_rate.h"
#include <assert.h>
#include <stdio.h>

static void eq(double a, double b) { assert(isfinite(a) && fabs(a - b) < 1e-8); }

int main(void) {
    power_rate cpu = {0}, gpu = {0};
    // 75 W delivered as 150 J batches every 2s. Polling every 1s must NEVER
    // turn the stale observation into 0 W or divide the next batch by 1s.
    assert(isnan(power_rate_update(&cpu, 1000000, 1000, 1000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 1000000, 1000, 2000, .001, .001)));
    eq(power_rate_update(&cpu, 1150000, 3000, 3000, .001, .001), 75);
    eq(power_rate_update(&cpu, 1150000, 3000, 4000, .001, .001), 75);
    eq(power_rate_update(&cpu, 1300000, 5000, 5000, .001, .001), 75);
    eq(cpu.interval_s, 2);
    // Irregular UI polls leave the source interval unchanged.
    eq(power_rate_update(&cpu, 1300000, 5000, 6600, .001, .001), 75);
    eq(power_rate_update(&cpu, 1450000, 7000, 7250, .001, .001), 75);
    // GPU has an independent update rate and energy unit (nJ).
    assert(isnan(power_rate_update(&gpu, 0, 1000, 1000, .001, 1e-9)));
    eq(power_rate_update(&gpu, 2000000000, 2000, 2200, .001, 1e-9), 2);
    // Genuine load drop: advancing timestamp plus unchanged energy means 0 W.
    eq(power_rate_update(&cpu, 1450000, 9000, 9000, .001, .001), 0);
    // Counter reset, time regression, sleep gaps and frozen samples re-prime.
    assert(isnan(power_rate_update(&cpu, 10, 11000, 11000, .001, .001)));
    eq(power_rate_update(&cpu, 150010, 13000, 13000, .001, .001), 75);
    assert(isnan(power_rate_update(&cpu, 150010, 13000, 24001, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 150010, 25000, 25000, .001, .001)));
    eq(power_rate_update(&cpu, 300010, 27000, 27000, .001, .001), 75);
    assert(isnan(power_rate_update(&cpu, 450010, 50000, 50000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 450010, 49000, 50000, .001, .001)));
    // Unknown units, missing timestamps and inconsistent frozen counters fail closed.
    assert(isnan(power_rate_update(&cpu, 450010, 51000, 51000, .001, NAN)));
    assert(isnan(power_rate_update(&cpu, -1, 51000, 51000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 1, 0, 51000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 1, 52000, 51000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 1, 52000, 52000, .001, .001)));
    assert(isnan(power_rate_update(&cpu, 2, 52000, 52500, .001, .001)));
    // Unit change is not a load spike; must establish a new baseline.
    assert(isnan(power_rate_update(&gpu, 2000001, 3000, 3000, .001, 1e-6)));
    eq(power_rate_update(&gpu, 4000001, 4000, 4000, .001, 1e-6), 2);
    // A second update ~10 ms after the regular one is folded into the next window, not reported
    // as watts over 10 ms; fast polling of a live counter still becomes valid once 0.25 s pass.
    power_rate b = {0};
    assert(isnan(power_rate_update(&b, 0, 1000, 1000, .001, .001)));
    eq(power_rate_update(&b, 1000, 2000, 2000, .001, .001), 1);
    eq(power_rate_update(&b, 1033, 2010, 2010, .001, .001), 1);
    eq(power_rate_update(&b, 2033, 3010, 3010, .001, .001), 1.033 / 1.01);
    eq(b.interval_s, 1.01);
    power_rate live = {0};
    assert(isnan(power_rate_update(&live, 0, 1000, 1000, .001, .001)));
    assert(isnan(power_rate_update(&live, 100, 1100, 1100, .001, .001)));
    assert(isnan(power_rate_update(&live, 200, 1200, 1200, .001, .001)));
    eq(power_rate_update(&live, 300, 1300, 1300, .001, .001), 1);
    puts("PASS: asynchronous 75W batches, irregular polling, independent GPU, real zero, reset/stale/unit handling, short-window folding");
}
