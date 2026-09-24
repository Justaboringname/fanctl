// Prints every metric once per interval, for checking the menu bar numbers against
// macmon / vm_stat / netstat. Build: make metricsdump
#include "../metrics.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 5;
    double interval = argc > 2 ? atof(argv[2]) : 1.0;
    int r = m_open();
    if (r) { fprintf(stderr, "m_open failed (%d)\n", r); return 1; }
    for (int i = 0; i < n; i++) {
        usleep((useconds_t)(interval * 1e6));
        m_cpu c; m_power p; m_gpu g; m_mem m; m_net net; m_sensors s;
        m_cpu_sample(&c); m_power_sample(&p); m_gpu_sample(&g); m_mem_sample(&m); m_net_sample(&net); m_sensors_sample(&s);
        double pc = 0, mc = 0; int np = 0, nm = 0;
        for (int k = 0; k < c.ncpu; k++) {
            if (c.cluster[k] == 'P') { pc += c.core[k]; np++; }
            if (c.cluster[k] == 'M') { mc += c.core[k]; nm++; }
        }
        printf("CPU %5.1f%% (usr %4.1f sys %4.1f | P %5.1f%% M %5.1f%%)  %6.2f W (P %5.2f M %5.2f E %4.2f)\n",
               c.total * 100, c.user * 100, c.system * 100, np ? pc / np * 100 : 0, nm ? mc / nm * 100 : 0,
               p.cpu_w, p.cpu_p_w, p.cpu_m_w, p.cpu_e_w);
        printf("GPU dev %5.1f%% rend %5.1f%% tiler %5.1f%% active %5.1f%%  %6.2f W  mem %.2f GB  | ANE %.2f W DRAM %.2f W\n",
               g.device * 100, g.renderer * 100, g.tiler * 100, p.gpu_active * 100, p.gpu_w, g.mem_in_use / 1e9, p.ane_w, p.dram_w);
        printf("MEM used %.2f GB (app %.2f wired %.2f compr %.2f) cached %.2f total %.1f  swap %.2f/%.2f GB  pressure %d\n",
               m.used / 1073741824.0, m.app / 1073741824.0, m.wired / 1073741824.0, m.compressed / 1073741824.0,
               m.cached / 1073741824.0, m.total / 1073741824.0, m.swap_used / 1073741824.0, m.swap_total / 1073741824.0, m.pressure);
        printf("NET %s %s  rx %.1f KB/s tx %.1f KB/s  totals rx %.2f GB tx %.2f GB\n", net.iface, net.ipv4,
               net.rx_bps / 1024, net.tx_bps / 1024, net.rx_total / 1e9, net.tx_total / 1e9);
        printf("SNS CPU %.1f/%.1f GPU %.1f/%.1f SSD %.1f °C  SYS %.1f W  fans", s.cpu_max, s.cpu_avg, s.gpu_max, s.gpu_avg, s.ssd, s.sys_w);
        for (int k = 0; k < s.nfans; k++) printf(" %.0f%s", s.fan[k].actual, s.fan[k].manual ? "M" : "");
        printf("\n");
        m_procs pr;
        m_procs_sample(&pr);
        printf("PRC readable %d/%d\n", pr.readable, pr.total);
        for (int k = 0; k < pr.n; k++)
            printf("   cpu %-20s %5.1f%%   power %-20s %5.2f W   mem %-20s %6.0f MB\n", pr.by_cpu[k].name, pr.by_cpu[k].cpu * 100,
                   pr.by_power[k].name, pr.by_power[k].watts, pr.by_mem[k].name, pr.by_mem[k].mem / 1048576.0);
        printf("\n");
        fflush(stdout);
    }
    return 0;
}
