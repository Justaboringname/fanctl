#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

// Layout must match the kernel's SMCParamStruct (80 bytes).
typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;
_Static_assert(sizeof(SMCParam) == 80, "SMCParam layout");

enum { kSMCUserClient = 2, kCmdRead = 5, kCmdWrite = 6, kCmdKeyAtIndex = 8, kCmdKeyInfo = 9 };

static io_connect_t conn;
uint8_t smc_last_result;

static uint32_t k2u(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 | (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}
static void u2k(uint32_t v, char *s) { s[0] = v >> 24; s[1] = v >> 16; s[2] = v >> 8; s[3] = v; s[4] = 0; }

static int call(SMCParam *in, SMCParam *out) {
    size_t n = sizeof(*out);
    kern_return_t kr = IOConnectCallStructMethod(conn, kSMCUserClient, in, sizeof(*in), out, &n);
    smc_last_result = kr == kIOReturnSuccess ? out->result : 0xff;
    return kr != kIOReturnSuccess || out->result ? -1 : 0;
}

static int key_info(uint32_t key, SMCKeyInfo *ki) {
    SMCParam in = {0}, out = {0};
    in.key = key;
    in.data8 = kCmdKeyInfo;
    if (call(&in, &out)) return -1;
    *ki = out.keyInfo;
    return 0;
}

int smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return kr == kIOReturnSuccess ? 0 : -1;
}

void smc_close(void) {
    if (conn) IOServiceClose(conn);
    conn = 0;
}

int smc_read(const char *key, smc_val *out) {
    SMCKeyInfo ki;
    uint32_t k = k2u(key);
    memset(out, 0, sizeof(*out));
    memcpy(out->name, key, 4);
    if (key_info(k, &ki)) return -1;
    u2k(ki.dataType, out->type);
    out->size = ki.dataSize;
    out->attr = ki.dataAttributes;
    SMCParam in = {0}, res = {0};
    in.key = k;
    in.keyInfo.dataSize = ki.dataSize;
    in.data8 = kCmdRead;
    if (call(&in, &res)) return -2;
    memcpy(out->bytes, res.bytes, sizeof(out->bytes));
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    SMCKeyInfo ki;
    uint32_t k = k2u(key);
    if (key_info(k, &ki)) return -1;
    if (ki.dataSize != size) return -3;
    SMCParam in = {0}, out = {0};
    in.key = k;
    in.keyInfo.dataSize = size;
    in.data8 = kCmdWrite;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out) ? -2 : 0;
}

int smc_count(uint32_t *n) {
    smc_val v;
    if (smc_read("#KEY", &v)) return -1;
    *n = (uint32_t)v.bytes[0] << 24 | (uint32_t)v.bytes[1] << 16 | (uint32_t)v.bytes[2] << 8 | v.bytes[3];
    return 0;
}

int smc_key_at(uint32_t i, char out[5]) {
    SMCParam in = {0}, res = {0};
    in.data8 = kCmdKeyAtIndex;
    in.data32 = i;
    if (call(&in, &res)) return -1;
    u2k(res.key, out);
    return 0;
}

int smc_read_float(const char *key, float *out) {
    smc_val v;
    int r = smc_read(key, &v);
    if (r) return r;
    if (strcmp(v.type, "flt ") || v.size != 4) return -4;
    memcpy(out, v.bytes, 4);
    return 0;
}

int smc_read_u8(const char *key, uint8_t *out) {
    smc_val v;
    int r = smc_read(key, &v);
    if (r) return r;
    if (v.size != 1) return -4;
    *out = v.bytes[0];
    return 0;
}

int smc_write_float(const char *key, float v) {
    uint8_t b[4];
    memcpy(b, &v, 4);
    return smc_write(key, b, 4);
}

int smc_write_u8(const char *key, uint8_t v) { return smc_write(key, &v, 1); }
