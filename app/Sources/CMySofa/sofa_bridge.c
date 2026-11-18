#include "sofa_bridge.h"
#include "mysofa.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

int sofa_load(const char *path, float rate, int len, int *outM, float **outIR, float **outDir) {
    int filterlen = 0, err = 0;
    struct MYSOFA_EASY *e = mysofa_open(path, rate, &filterlen, &err);
    if (!e) return err ? err : -1;
    int M = (int)e->hrtf->M;
    float *ir = calloc((size_t)M * 2 * len, sizeof(float));
    float *dir = malloc((size_t)M * 3 * sizeof(float));
    float *l = malloc((size_t)filterlen * sizeof(float));
    float *r = malloc((size_t)filterlen * sizeof(float));
    if (!ir || !dir || !l || !r) { free(ir); free(dir); free(l); free(r); mysofa_close(e); return -2; }
    const float *pos = e->hrtf->SourcePosition.values; /* cartesian after mysofa_open */
    for (int m = 0; m < M; m++) {
        float x = pos[3 * m], y = pos[3 * m + 1], z = pos[3 * m + 2];
        float n = sqrtf(x * x + y * y + z * z);
        if (n <= 0) n = 1;
        dir[3 * m] = x / n; dir[3 * m + 1] = y / n; dir[3 * m + 2] = z / n;
        float dl = 0, dr = 0;
        mysofa_getfilter_float(e, x, y, z, l, r, &dl, &dr);
        int sl = (int)lrintf(dl * rate), sr = (int)lrintf(dr * rate);
        for (int k = 0; k < filterlen; k++) {
            if (sl + k >= 0 && sl + k < len) ir[(size_t)(2 * m) * len + sl + k] = l[k];
            if (sr + k >= 0 && sr + k < len) ir[(size_t)(2 * m + 1) * len + sr + k] = r[k];
        }
    }
    free(l); free(r);
    mysofa_close(e);
    *outM = M; *outIR = ir; *outDir = dir;
    return 0;
}

void sofa_free(float *p) { free(p); }
