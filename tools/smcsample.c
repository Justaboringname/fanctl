// Prints SMC float keys as CSV at a fixed interval (read-only), e.g. to watch the power rails while
// plugging a USB device in or out:   build/smcsample 60 0.5 PSTR PDTR PU1C PU2C
#include "../smc.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: smcsample <samples> <interval-seconds> <KEY>...\n");
        return 2;
    }
    int n = atoi(argv[1]);
    double every = atof(argv[2]);
    if (smc_open()) {
        fprintf(stderr, "cannot open AppleSMC\n");
        return 1;
    }
    printf("t");
    for (int k = 3; k < argc; k++) printf(",%s", argv[k]);
    printf("\n");
    for (int i = 0; i < n; i++) {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        printf("%.3f", tv.tv_sec + tv.tv_usec / 1e6);
        for (int k = 3; k < argc; k++) {
            float v = NAN;
            smc_read_float(argv[k], &v);
            printf(",%.4f", v);
        }
        printf("\n");
        fflush(stdout);
        if (i + 1 < n) usleep((useconds_t)(every * 1e6));
    }
    smc_close();
    return 0;
}
