// Prints when the IOReport Energy Model counters actually advance (their hardware timestamp and
// value), to see what drives their update cadence. Usage: build/energyprobe [seconds] [interval]
#include "../metrics.c"
#include <unistd.h>

int main(int argc, char **argv) {
    int secs = argc > 1 ? atoi(argv[1]) : 30;
    double every = argc > 2 ? atof(argv[2]) : 0.5;
    if (m_power_open()) { fprintf(stderr, "IOReport open failed\n"); return 1; }
    const char *want[] = {"CPU Energy", "DRAM0", "GPU Energy", "PCPU", "MCPU0"};
    uint64_t last_stamp[5] = {0}; long long last_val[5] = {0};
    uint64_t t0 = mach_absolute_time();
    for (int n = 0; n * every < secs; n++) {
        CFDictionaryRef s = IOReportCreateSamples(sub, sub_channels, NULL);
        CFArrayRef chans = s ? CFDictionaryGetValue(s, CFSTR("IOReportChannels")) : NULL;
        uint64_t now = mach_absolute_time();
        for (CFIndex i = 0; chans && i < CFArrayGetCount(chans); i++) {
            CFDictionaryRef ch = CFArrayGetValueAtIndex(chans, i);
            char name[64];
            cfstr(IOReportChannelGetChannelName(ch), name, sizeof name);
            for (int k = 0; k < 5; k++) {
                if (strcmp(name, want[k])) continue;
                CFDataRef raw = CFDictionaryGetValue(ch, CFSTR("RawElements"));
                power_element e; memcpy(&e, CFDataGetBytePtr(raw), sizeof e);
                long long v = IOReportSimpleGetIntegerValue(ch, 0);
                if (e.stamp != last_stamp[k] || v != last_val[k]) {
                    printf("t=%6.2fs %-10s stamp age %6.2fs  Δstamp %6.2fs  Δvalue %lld\n",
                           (now - t0) * power_tick_s, want[k], (now - e.stamp) * power_tick_s,
                           last_stamp[k] ? (e.stamp - last_stamp[k]) * power_tick_s : 0.0, v - last_val[k]);
                    last_stamp[k] = e.stamp; last_val[k] = v;
                }
            }
        }
        if (s) CFRelease(s);
        fflush(stdout);
        usleep((useconds_t)(every * 1e6));
    }
    return 0;
}
