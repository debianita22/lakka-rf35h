/* Confronto NEON vs C per s16<->float e per il resampler sinc, su arm64. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>
#include <libretro.h>
#include <audio/conversion/s16_to_float.h>
#include <audio/conversion/float_to_s16.h>
#include <audio/audio_resampler.h>

/* shim: il cpu_features_get() vero leggerebbe /proc/cpuinfo dell'host x86 */
static uint64_t fake_cpu = 0;
uint64_t cpu_features_get(void) { return fake_cpu; }
extern retro_resampler_t sinc_resampler;

#define N 48000
static int16_t in16[N]; static float inf[N], outf_c[N], outf_n[N]; static int16_t out16_c[N], out16_n[N];

static void gen(void) {
   for (int i = 0; i < N; i++) {
      double v = 0.6*sin(2*M_PI*440.0*i/48000.0) + 0.3*sin(2*M_PI*3000.0*i/48000.0);
      in16[i] = (int16_t)(v * 32767); inf[i] = (float)v;
   }
}
static double maxdiff_f(const float *a, const float *b, int n) { double m=0; for (int i=0;i<n;i++){ double d=fabs(a[i]-b[i]); if(d>m)m=d;} return m; }
static int maxdiff_i(const int16_t *a, const int16_t *b, int n) { int m=0; for (int i=0;i<n;i++){ int d=abs(a[i]-b[i]); if(d>m)m=d;} return m; }
static double rms(const float *a, int n){ double s=0; for(int i=0;i<n;i++) s+=a[i]*a[i]; return sqrt(s/n); }

static void resample(unsigned mask, double ratio, const float *in, size_t inframes, float *out, size_t *outframes) {
   /* init(config, bandwidth_mod, quality, mask): il rapporto va in resampler_data.ratio */
   void *re = sinc_resampler.init(NULL, 1.0, QUAL, mask);
   struct resampler_data d; memset(&d, 0, sizeof(d));
   d.data_in = in; d.data_out = out; d.input_frames = inframes; d.ratio = ratio;
   sinc_resampler.process(re, &d);
   *outframes = d.output_frames;
   sinc_resampler.free(re);
}

int main(void) {
   gen();
   /* --- conversioni: C --- */
   fake_cpu = 0; convert_s16_to_float_init_simd(); convert_float_to_s16_init_simd();
   convert_s16_to_float(outf_c, in16, N, 1.0f); convert_float_to_s16(out16_c, inf, N);
   /* --- conversioni: NEON --- */
   fake_cpu = RETRO_SIMD_NEON | RETRO_SIMD_ASIMD; convert_s16_to_float_init_simd(); convert_float_to_s16_init_simd();
   convert_s16_to_float(outf_n, in16, N, 1.0f); convert_float_to_s16(out16_n, inf, N);
   printf("s16->float  maxdiff NEON vs C: %.3g   (rms segnale %.3f)\n", maxdiff_f(outf_c, outf_n, N), rms(outf_c, N));
   printf("float->s16  maxdiff NEON vs C: %d LSB\n", maxdiff_i(out16_c, out16_n, N));

   /* --- resampler: stereo interleaved, 44100 -> 48000 e 32000 -> 48000 --- */
   static float st_in[2*24000], st_c[2*60000], st_n[2*60000];   /* 24000*2.18 = 52248 frame: serve spazio */
   for (int i = 0; i < 24000; i++) { st_in[2*i] = inf[i]; st_in[2*i+1] = 0.5f*inf[i]; }
   double ratios[6] = { 48000.0/44100.0, 48000.0/32000.0, 48000.0/22050.0, 1.0, 48000.0/32768.0, 48000.0/32040.0 };
   for (int r = 0; r < 6; r++) {
      size_t nc, nn;
      resample(0, ratios[r], st_in, 24000, st_c, &nc);
      resample(RESAMPLER_SIMD_NEON, ratios[r], st_in, 24000, st_n, &nn);
      double md = maxdiff_f(st_c, st_n, 2*(int)(nc<nn?nc:nn));
      printf("sinc ratio %.4f: frame C=%zu NEON=%zu  maxdiff=%.3g  rms C=%.3f NEON=%.3f  -> %s\n",
             ratios[r], nc, nn, md, rms(st_c, 2*nc), rms(st_n, 2*nn), (nc==nn && md < 1e-3) ? "IDENTICI" : "DIVERSI");
      if (md > 1e-3) {
         int first=-1, cnt=0, last=-1; double worst=0; int wi=-1;
         for (int i = 0; i < 2*(int)nc; i++) { double d = fabs(st_c[i]-st_n[i]); if (d > 1e-3) { if (first<0) first=i; last=i; cnt++; if (d>worst){worst=d; wi=i;} } }
         printf("   campioni diversi: %d su %d, primo=%d ultimo=%d, peggiore idx=%d C=%.3f NEON=%.3f\n", cnt, 2*(int)nc, first, last, wi, st_c[wi], st_n[wi]);
         printf("   canale del peggiore: %s\n", (wi%2)? "destro" : "sinistro");
      }
   }
   return 0;
}
