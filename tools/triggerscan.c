// Finds which IOReport channel group, when sampled, makes the PMGR "CPU Energy" counter refresh.
// On Mac17,14 / macOS 27 that counter only advances while something (e.g. powermetrics) samples.
// Usage: build/triggerscan [all|<group>|scan]   (run with sudo to test the privileged path too)
#include "../metrics.c"
#include <unistd.h>

CFDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);

static double tick;

// Age (s) of CPU Energy's hardware stamp in a sample, or -1 if absent.
static double cpu_energy_age(CFDictionaryRef smp) {
    CFArrayRef a = CFDictionaryGetValue(smp, CFSTR("IOReportChannels"));
    uint64_t now = mach_absolute_time();
    for (CFIndex i = 0; a && i < CFArrayGetCount(a); i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(a, i);
        char name[64]; cfstr(IOReportChannelGetChannelName(ch), name, sizeof name);
        if (strcmp(name, "CPU Energy")) continue;
        CFDataRef raw = CFDictionaryGetValue(ch, CFSTR("RawElements"));
        if (!raw || CFDataGetLength(raw) != sizeof(power_element)) return -1;
        power_element e; memcpy(&e, CFDataGetBytePtr(raw), sizeof e);
        return (now - e.stamp) * tick;
    }
    return -1;
}

// Subscribe to `chans` plus CPU Energy, sample 3 times 0.5 s apart; 1 if CPU Energy came back fresh.
static int triggers(CFDictionaryRef chans, int verbose) {
    CFMutableDictionaryRef want = CFDictionaryCreateMutableCopy(NULL, 0, chans);
    CFMutableDictionaryRef energy = filtered_group(CFSTR("Energy Model"), NULL, NULL);
    IOReportMergeChannels(want, energy, NULL);
    CFMutableDictionaryRef subbed = NULL;
    IOReportSubscriptionRef s = IOReportCreateSubscription(NULL, want, &subbed, 0, NULL);
    CFRelease(want); CFRelease(energy);
    if (!s) return -1;
    int fresh = 0;
    for (int n = 0; n < 3; n++) {
        CFDictionaryRef smp = IOReportCreateSamples(s, subbed, NULL);
        double age = smp ? cpu_energy_age(smp) : -1;
        if (verbose) printf("  sample %d: CPU Energy stamp age %.2fs\n", n, age);
        if (n > 0 && age >= 0 && age < 0.5) fresh = 1;
        if (smp) CFRelease(smp);
        usleep(500000);
    }
    CFRelease(subbed);
    CFRelease(s);
    return fresh;
}

int main(int argc, char **argv) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb); tick = (double)tb.numer / tb.denom / 1e9;
    const char *mode = argc > 1 ? argv[1] : "scan";
    printf("uid %d\n", getuid());
    if (!strcmp(mode, "all")) {
        CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
        int r = triggers(all, 1);
        printf("all channels (%ld): %s\n", (long)CFArrayGetCount(CFDictionaryGetValue(all, CFSTR("IOReportChannels"))),
               r == 1 ? "REFRESHES CPU Energy" : "no refresh");
        return r == 1 ? 0 : 2;  // lets a shell `&&` skip the per-group scan when nothing refreshes
    }
    if (strcmp(mode, "scan")) {
        CFStringRef g = CFStringCreateWithCString(NULL, mode, kCFStringEncodingUTF8);
        CFDictionaryRef d = IOReportCopyChannelsInGroup(g, NULL, 0, 0, 0);
        printf("group %s: %s\n", mode, d && triggers(d, 1) == 1 ? "REFRESHES CPU Energy" : "no refresh");
        return 0;
    }
    // Every distinct top-level group, one at a time; likely candidates first, stop at the first hit.
    const char *first[] = {"CPU Stats", "PMP0", "PMP", "SoC Stats", "AMC Stats", "GPU Stats", "Energy Model"};
    CFMutableArrayRef order = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (size_t i = 0; i < sizeof first / sizeof *first; i++) {
        CFStringRef g = CFStringCreateWithCString(NULL, first[i], kCFStringEncodingUTF8);
        CFArrayAppendValue(order, g); CFRelease(g);
    }
    CFDictionaryRef all = IOReportCopyAllChannels(0, 0);
    CFArrayRef a = CFDictionaryGetValue(all, CFSTR("IOReportChannels"));
    for (CFIndex i = 0; i < CFArrayGetCount(a); i++) {
        CFStringRef g = IOReportChannelGetGroup(CFArrayGetValueAtIndex(a, i));
        if (g && !CFArrayContainsValue(order, CFRangeMake(0, CFArrayGetCount(order)), g)) CFArrayAppendValue(order, g);
    }
    int hits = 0, tested = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(order) && !hits; i++) {
        CFStringRef g = CFArrayGetValueAtIndex(order, i);
        CFDictionaryRef d = IOReportCopyChannelsInGroup(g, NULL, 0, 0, 0);
        if (!d) continue;
        char name[128]; cfstr(g, name, sizeof name);
        int r = triggers(d, 0);
        tested++;
        printf("%-40s %s\n", name, r == 1 ? "REFRESHES CPU Energy" : "-");
        if (r == 1) hits++;
        fflush(stdout);
        CFRelease(d);
    }
    printf("tested %d groups, %d refresh CPU Energy\n", tested, hits);
}
