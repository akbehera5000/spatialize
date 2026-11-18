#ifndef SOFA_BRIDGE_H
#define SOFA_BRIDGE_H
/// Loads a SOFA HRTF set with libmysofa, resampled to `rate`. On success returns 0 and hands
/// back M measurements: `ir` holds M × 2 × `len` impulse responses (left then right, each
/// delayed by its stored onset) and `dir` holds M unit vectors (x forward, y left, z up).
/// Free both with sofa_free.
int sofa_load(const char *path, float rate, int len, int *m, float **ir, float **dir);
void sofa_free(float *p);
#endif
