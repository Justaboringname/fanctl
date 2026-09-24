// System metrics for the menu bar app, all readable without root.
//
// Most rates use the interval since the previous call. Power uses each IOReport
// channel's hardware timestamps instead: repeated readings hold the last complete
// interval (up to 10s), and fresh zero-energy intervals correctly report zero watts.
// Power validity flags stay false until two usable hardware timestamps exist.
#pragma once
#include <stdint.h>

#define M_MAX_CPUS 64
#define M_MAX_FANS 8
#define M_MAX_POWER_CHANNELS 64

typedef struct {
    char name[64];
    double watts;
    int valid;
} m_power_channel;

typedef struct {
    int ncpu;
    char cluster[M_MAX_CPUS];   // IODeviceTree cluster-type per logical CPU: 'P', 'M' or 'E'
    double core[M_MAX_CPUS];    // busy fraction 0..1 per logical CPU
    double user, system, total; // busy fraction 0..1 across all CPUs
} m_cpu;

typedef struct {
    int valid;
    int cpu_valid, gpu_valid, ane_valid, dram_valid;
    double cpu_w;               // "CPU Energy" (all clusters)
    double cpu_p_w, cpu_m_w, cpu_e_w;  // per cluster type (PCPU*, MCPU*, ECPU*)
    double gpu_w, ane_w, dram_w;
    double cpu_interval_s, cpu_age_s; // last completed source window and age of its end
    double gpu_active;          // 0..1, share of time the GPU was not in its OFF power state
    // Additional Energy Model channels, kept separate because their overlap with
    // CPU/GPU/DRAM aggregates is not documented. Never blindly sum these into a total.
    int n_other, other_truncated;
    m_power_channel other[M_MAX_POWER_CHANNELS];
} m_power;

typedef struct {
    double device, renderer, tiler;  // 0..1, IOAccelerator PerformanceStatistics
    uint64_t mem_in_use, mem_alloc;  // bytes
} m_gpu;

typedef struct {
    uint64_t total, used, app, wired, compressed, cached;  // bytes; used = app + wired + compressed
    uint64_t swap_total, swap_used;
    int pressure;                                           // 1 normal, 2 warning, 4 critical
} m_mem;

typedef struct {
    char iface[16];             // primary interface (from SystemConfiguration), "" if offline
    char ipv4[64];
    double rx_bps, tx_bps;      // bytes per second on the primary interface
    uint64_t rx_total, tx_total;  // bytes since the app started (the kernel's lifetime counters are
                                  // truncated to 32 bits for unentitled processes on macOS 27)
} m_net;

typedef struct { float actual, target, min, max; int manual; } m_fan;

typedef struct {
    float cpu_max, cpu_avg, gpu_max, gpu_avg;  // °C; CPU = Tp0*, GPU = Tg* (load-tested on Mac17,14)
    float ssd;                                 // °C from the IOHID "NAND CH0 temp" sensor, 0 if absent
    float sys_w;                               // SMC PSTR, whole-system power
    float usb_w;                               // SMC PU1C+PU2C+PU3C+PUAC: power delivered out of the USB ports
                                               // (5 V side). PSTR includes it: a 14 W lamp on USB-C 2 moved
                                               // PSTR by 15 W when switched off (2026-09-24).
    int nfans;
    m_fan fan[M_MAX_FANS];
} m_sensors;

#define M_TOP_PROCS 5

typedef struct { int pid; char name[64]; double cpu, watts; uint64_t mem; } m_proc;

typedef struct {
    m_proc by_cpu[M_TOP_PROCS], by_mem[M_TOP_PROCS], by_power[M_TOP_PROCS];
    int n;                  // entries filled in each list
    int readable, total;    // processes we could read (current user's) vs all processes
} m_procs;

int m_open(void);  // SMC connection, sensor scan, IOReport subscription; 0 on success
// Power-only initialization: primes the energy baseline without opening SMC or other metrics.
// Poll m_power_sample(); validity becomes true as new source timestamps arrive.
int m_power_open(void);
int m_cpu_sample(m_cpu *out);
int m_power_sample(m_power *out);
int m_gpu_sample(m_gpu *out);
int m_mem_sample(m_mem *out);
int m_net_sample(m_net *out);
int m_sensors_sample(m_sensors *out);
float m_usb_w(void);  // W the USB ports deliver to external devices (included in PSTR); needs the SMC open
// Top processes by CPU %, memory (phys footprint) and power (ri_energy_nj). Without root only the
// current user's processes are readable, so system daemons (WindowServer, kernel_task…) are absent.
int m_procs_sample(m_procs *out);
