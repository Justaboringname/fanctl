// In-memory AppleSMC stand-in for tests: two fans, a few CPU/GPU sensors, and the ~1 s F<i>md
// readback lag seen on Mac17,14 (a write shows up only after `md_lag_reads` further reads).
#include "../smc.h"
#include <string.h>

uint8_t smc_last_result;
float fake_temp = 40, fake_min = 1000, fake_max = 3625;
int fake_fail_reads, md_lag_reads;
static uint8_t md[2], md_visible[2];
static int md_pending[2];
static float tg[2] = {1000, 1000};
static const char *keys[] = {"FNum", "Tp00", "Tp04", "Tg0U", "Tg0X", "PSTR"};

uint8_t fake_md(int i) { return md[i]; }
float fake_tg(int i) { return tg[i]; }

int smc_open(void) { return 0; }
void smc_close(void) {}
int smc_count(uint32_t *n) { *n = sizeof keys / sizeof *keys; return 0; }
int smc_key_at(uint32_t i, char out[5]) { memcpy(out, keys[i], 5); return 0; }
int smc_read(const char *key, smc_val *out) { (void)key; memset(out, 0, sizeof *out); return -1; }
int smc_write(const char *key, const uint8_t *b, uint32_t n) { (void)key; (void)b; (void)n; return -1; }

int smc_read_float(const char *k, float *out) {
    if (fake_fail_reads) { fake_fail_reads--; return -2; }
    if (k[0] == 'T') { *out = fake_temp; return 0; }
    if (!strcmp(k, "PSTR")) { *out = 30; return 0; }
    if (k[0] != 'F' || (k[1] != '0' && k[1] != '1')) return -1;
    int i = k[1] - '0';
    if (!strcmp(k + 2, "Ac")) *out = tg[i];
    else if (!strcmp(k + 2, "Tg")) *out = tg[i];
    else if (!strcmp(k + 2, "Mn")) *out = fake_min;
    else if (!strcmp(k + 2, "Mx")) *out = fake_max;
    else return -1;
    return 0;
}

int smc_read_u8(const char *k, uint8_t *out) {
    if (!strcmp(k, "FNum")) { *out = 2; return 0; }
    if (k[0] != 'F' || strcmp(k + 2, "md")) return -1;
    int i = k[1] - '0';
    if (md_pending[i] && --md_pending[i] == 0) md_visible[i] = md[i];
    *out = md_visible[i];
    return 0;
}

int smc_write_u8(const char *k, uint8_t v) {
    int i = k[1] - '0';
    md[i] = v;
    if (md_lag_reads) md_pending[i] = md_lag_reads; else md_visible[i] = v;
    return 0;
}

int smc_write_float(const char *k, float v) { tg[k[1] - '0'] = v; return 0; }
