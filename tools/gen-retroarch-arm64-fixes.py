#!/usr/bin/env python3
"""RetroArch su aarch64: NEON che non c'era, e un nome per la CPU.

Due difetti trovati leggendo System Information sull'RF35H ("CPU Model: N/A",
"CPU Features: ASIMD"):

1. NEON. Il flag runtime RETRO_SIMD_NEON e i percorsi NEON del resampler audio
   (sinc), della conversione s16<->float e del decoder JPEG sono guardati da
   `__ARM_NEON__` o HAVE_NEON. Su aarch64 GCC definisce `__ARM_NEON` (ACLE,
   senza underscore finali), e Lakka passa --enable-neon solo su ARM a 32 bit.
   Risultato: su ogni Lakka a 64 bit l'audio di RetroArch gira in C puro e il
   flag non viene mai impostato. pixconv.c accetta gia' `__ARM_NEON`: si fa
   lo stesso negli altri. Le implementazioni sono tutte intrinsics ACLE (le
   .S a 32 bit stanno dietro HAVE_ARM_NEON_ASM_OPTIMIZATIONS, che resta off).
   Verificato: compilano con il cross-compiler aarch64.

2. CPU Model. Su Linux RetroArch legge "model name" da /proc/cpuinfo, che su
   ARM64 mainline non esiste. Fallback: "CPU implementer"/"CPU part" -> nome
   del core (0x41/0xd04 = Cortex-A35), piu' il SoC dal secondo compatible di
   /proc/device-tree ("xifan,rf35h\\0rockchip,rk3326" -> "Rockchip RK3326").
   Risultato: "Rockchip RK3326 (Cortex-A35)". Vale per qualunque board ARM.

Ancore esatte: se un'ancora manca, lo script si ferma.
"""
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ra/src"

def edit(path, pairs):
    p = f"{SRC}/{path}"
    s = open(p).read()
    for old, new in pairs:
        if s.count(old) < 1:
            sys.exit(f"{path}: ancora non trovata:\n{old[:120]}")
        s = s.replace(old, new)
    open(p, "w").write(s)
    print(f"  {path}: {len(pairs)} modifiche")

GUARD_OLD = "#if (defined(__ARM_NEON__) || defined(HAVE_NEON))"
GUARD_NEW = "#if (defined(__ARM_NEON__) || defined(__ARM_NEON) || defined(HAVE_NEON))"

edit("libretro-common/audio/resampler/drivers/sinc_resampler.c", [(GUARD_OLD, GUARD_NEW)])
edit("libretro-common/audio/conversion/s16_to_float.c", [(GUARD_OLD, GUARD_NEW)])
edit("libretro-common/audio/conversion/float_to_s16.c", [(GUARD_OLD, GUARD_NEW)])
edit("libretro-common/formats/jpeg/rjpeg.c", [
    ("#if !defined(RJPEG_NO_SIMD) && !defined(RJPEG_NEON) && (defined(__ARM_NEON__) || defined(HAVE_NEON))",
     "#if !defined(RJPEG_NO_SIMD) && !defined(RJPEG_NEON) && (defined(__ARM_NEON__) || defined(__ARM_NEON) || defined(HAVE_NEON))"),
])

MODEL_FALLBACK = r'''
#if defined(__linux__) && (defined(__aarch64__) || defined(__arm__))
#include <ctype.h>
/* Su ARM64 mainline /proc/cpuinfo non ha "model name". Si ricostruisce un
 * nome da "CPU implementer"/"CPU part" e dal SoC dichiarato nel device tree:
 * "xifan,rf35h\0rockchip,rk3326" -> "Rockchip RK3326 (Cortex-A35)". */
static const char *cpu_features_arm_part_name(unsigned implementer, unsigned part)
{
   if (implementer == 0x41) /* ARM Ltd. */
   {
      switch (part)
      {
         case 0xd03: return "Cortex-A53";
         case 0xd04: return "Cortex-A35";
         case 0xd05: return "Cortex-A55";
         case 0xd07: return "Cortex-A57";
         case 0xd08: return "Cortex-A72";
         case 0xd09: return "Cortex-A73";
         case 0xd0a: return "Cortex-A75";
         case 0xd0b: return "Cortex-A76";
         case 0xd0d: return "Cortex-A77";
         case 0xd41: return "Cortex-A78";
         case 0xd46: return "Cortex-A510";
         case 0xd47: return "Cortex-A710";
         case 0xd4d: return "Cortex-A715";
         default:    break;
      }
   }
   return NULL;
}

static void cpu_features_arm_model_name(char *s, int len)
{
   char line[128];
   char soc[64]       = {0};
   unsigned impl      = 0;
   unsigned part      = 0;
   const char *core   = NULL;
   RFILE *fp;

   fp = filestream_open("/proc/cpuinfo",
         RETRO_VFS_FILE_ACCESS_READ, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (fp)
   {
      while (filestream_gets(fp, line, sizeof(line)))
      {
         const char *v = strchr(line, ':');
         if (!v)
            continue;
         if (!impl && !strncmp(line, "CPU implementer", 15))
            impl = (unsigned)strtoul(v + 1, NULL, 0);
         else if (!part && !strncmp(line, "CPU part", 8))
            part = (unsigned)strtoul(v + 1, NULL, 0);
         if (impl && part)
            break;
      }
      filestream_close(fp);
   }
   core = cpu_features_arm_part_name(impl, part);

   /* compatible e' una lista di stringhe separate da NUL: la prima e' la
    * board, la seconda il SoC ("rockchip,rk3326") */
   fp = filestream_open("/proc/device-tree/compatible",
         RETRO_VFS_FILE_ACCESS_READ, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (fp)
   {
      char buf[256];
      int64_t n = filestream_read(fp, buf, sizeof(buf) - 1);
      filestream_close(fp);
      if (n > 0)
      {
         const char *p   = buf;
         const char *end = buf + n;
         int idx         = 0;
         buf[n]          = '\0';
         while (p < end && *p)
         {
            size_t l = strlen(p);
            if (idx == 1)
            {
               const char *comma = strchr(p, ',');
               if (comma && comma[1])
               {
                  size_t i, sl;
                  /* vendor con l'iniziale maiuscola, modello maiuscolo */
                  snprintf(soc, sizeof(soc), "%.*s %s",
                        (int)(comma - p), p, comma + 1);
                  soc[0] = (char)toupper((unsigned char)soc[0]);
                  /* devaOS RF35H: snprintf tronca a 63 caratteri. Con un
                   * vendor di 63 o piu' il modello non c'e', e il ciclo
                   * partiva oltre la fine di soc[]: ci si ferma alla sua
                   * lunghezza vera. */
                  sl = strlen(soc);
                  for (i = (size_t)(comma - p) + 1; i < sl; i++)
                     soc[i] = (char)toupper((unsigned char)soc[i]);
               }
               break;
            }
            p += l + 1;
            idx++;
         }
      }
   }

   if (soc[0] && core)
      snprintf(s, len, "%s (%s)", soc, core);
   else if (soc[0])
      strlcpy(s, soc, len);
   else if (core)
      strlcpy(s, core, len);
   else if (impl || part)
      snprintf(s, len, "ARM 0x%02x part 0x%03x", impl, part);
}
#endif

void cpu_features_get_model_name(char *s, int len)'''

edit("libretro-common/features/features_cpu.c", [
    # il flag runtime
    ('''   if (check_arm_cpu_feature("asimd"))
   {
      cpu |= RETRO_SIMD_ASIMD;
#ifdef __ARM_NEON__
      cpu |= RETRO_SIMD_NEON;''',
     '''   if (check_arm_cpu_feature("asimd"))
   {
      cpu |= RETRO_SIMD_ASIMD;
#if defined(__ARM_NEON__) || defined(__ARM_NEON)
      cpu |= RETRO_SIMD_NEON;'''),
    # l'helper, prima della funzione
    ("\nvoid cpu_features_get_model_name(char *s, int len)", MODEL_FALLBACK),
    # il fallback dopo la lettura di "model name"
    ('''         break;
      }

      filestream_close(fp);

#if defined(WEBOS)''',
     '''         break;
      }

      filestream_close(fp);

#if defined(__aarch64__) || defined(__arm__)
      if (!s[0])
         cpu_features_arm_model_name(s, len);
#endif

#if defined(WEBOS)'''),
])
print("tutte le ancore trovate, sorgente modificato")
