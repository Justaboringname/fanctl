// Minimal AppleSMC client: read/write keys through the AppleSMC user client.
#pragma once
#include <stdint.h>

typedef struct {
    char name[5];
    char type[5];
    uint32_t size;
    uint8_t attr;
    uint8_t bytes[32];
} smc_val;

extern uint8_t smc_last_result;  // firmware result byte of the last call (0x84 not found, 0x86 not writable, ...)

int smc_open(void);
void smc_close(void);
int smc_read(const char *key, smc_val *out);          // 0 ok, -1 no such key, -2 read error
int smc_write(const char *key, const uint8_t *bytes, uint32_t size);  // needs root
int smc_count(uint32_t *n);
int smc_key_at(uint32_t i, char out[5]);

// Typed helpers. Apple Silicon SMC floats are little-endian IEEE754 ("flt ").
int smc_read_float(const char *key, float *out);
int smc_read_u8(const char *key, uint8_t *out);
int smc_write_float(const char *key, float v);
int smc_write_u8(const char *key, uint8_t v);
