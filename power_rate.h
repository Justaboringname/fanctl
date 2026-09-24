// Energy counters are asynchronous: the UI polling interval is NOT their timebase.
// Fixes the 0 / ~2x watt oscillation on Mac17,14: PMGR posts its energy in batches (about every
// 2.1 s under a 2 s powermetrics, ~1.07 s under the 1 s one install.sh runs).
// Keep the most recent completed hardware interval until a new timestamp arrives.
// A fresh timestamp with unchanged energy is a genuine zero; a repeated timestamp
// is not. Expire frozen telemetry after 10s, and re-prime after resets/sleep gaps.
#pragma once
#include <math.h>
#include <stdint.h>

#define POWER_MAX_AGE_S 10.0
// With powermetrics driving the PMGR counters (~1.07 s), about one update in 60 is followed by a
// second one ~10 ms later; a watt figure over such a sliver is mostly quantisation noise (it showed
// as a one-second spike). Shorter windows are folded into the next one instead.
#define POWER_MIN_WINDOW_S 0.25

typedef struct {
    int initialized, valid;
    uint64_t stamp;
    int64_t energy;
    double unit_j, watts, interval_s;
} power_rate;

// Returns NAN until two usable source timestamps exist. now and stamp are in the
// same hardware clock domain; unit_j converts the raw energy counter to joules.
static inline double power_rate_update(power_rate *r, int64_t energy, uint64_t stamp,
                                       uint64_t now, double tick_s, double unit_j) {
    if (energy < 0 || !stamp || now < stamp || !isfinite(tick_s) || tick_s <= 0 ||
        !isfinite(unit_j) || unit_j <= 0 || (now - stamp) * tick_s > POWER_MAX_AGE_S) {
        *r = (power_rate){0};
        return NAN;
    }
    if (!r->initialized || stamp < r->stamp || energy < r->energy || unit_j != r->unit_j ||
        (stamp - r->stamp) * tick_s > POWER_MAX_AGE_S ||
        (stamp == r->stamp && energy != r->energy)) {
        *r = (power_rate){.initialized = 1, .stamp = stamp, .energy = energy, .unit_j = unit_j};
        return NAN;
    }
    if (stamp == r->stamp) return r->valid ? r->watts : NAN;
    double interval = (stamp - r->stamp) * tick_s;
    if (interval < POWER_MIN_WINDOW_S) return r->valid ? r->watts : NAN;  // keep the baseline
    r->interval_s = interval;
    r->watts = (double)(energy - r->energy) * unit_j / r->interval_s;
    r->stamp = stamp;
    r->energy = energy;
    r->valid = isfinite(r->watts) && r->watts >= 0;
    return r->valid ? r->watts : NAN;
}
