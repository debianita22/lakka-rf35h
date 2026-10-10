#!/bin/bash
# test-rf35h-coretest.sh - prove di tools/rf35h-coretest.c (il test di
# caricamento dei core) con core finti, compilati qui per l'host: niente qemu,
# niente immagine.
#
#   ./tools/test-rf35h-coretest.sh
#
# Ogni core finto e' lo stesso sorgente con un difetto diverso (-DCASO=...):
# quelli visti nelle immagini vere (un simbolo non risolto, come dosbox senza
# glib; un crash in retro_deinit senza contenuto, come TyrQuake; una callback
# prima di retro_init, come Mesen) e gli altri modi di non partire.
# Le verifiche sono stringhe che ok() esegue con eval.
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
# senza punti nel nome: il core finto "come RACE" taglia all'ultimo punto
T="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-ct-XXXXXX")"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }

command -v gcc >/dev/null || { echo "serve gcc"; exit 1; }
gcc -O1 -Wall -Wextra -Werror -I"${O}/tools/libretro" -o "${T}/coretest" "${O}/tools/rf35h-coretest.c" -ldl \
	|| { echo "rf35h-coretest non compila"; exit 1; }

cat > "${T}/core.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <libretro.h>
static retro_environment_t env;
static retro_log_printf_t logf;
static int *after_init;
#if CASO == 4
void manca_in_libreria(void);
#endif
RETRO_API unsigned retro_api_version(void) { return CASO == 6 ? 2 : RETRO_API_VERSION; }
RETRO_API void retro_set_environment(retro_environment_t cb)
{
   static const struct retro_variable legacy[] = { { "finto_legacy", "Legacy; uno|due" }, { NULL, NULL } };
   static struct retro_core_option_v2_definition defs[] = {
      { "finto_v2", "V2", NULL, NULL, NULL, NULL, { { "acceso", NULL }, { "spento", NULL }, { NULL, NULL } }, "acceso" },
      { NULL, NULL, NULL, NULL, NULL, NULL, { { NULL, NULL } }, NULL } };
   static struct retro_core_options_v2 v2 = { NULL, defs };
   static struct retro_core_options_v2_intl intl = { &v2, NULL };
   bool yes = true;
   unsigned version = 0;
   env = cb;
   cb(RETRO_ENVIRONMENT_SET_VARIABLES, (void *)legacy);
   if (cb(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) && version >= 2)
      cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL, &intl);
   if (CASO == 2)
      cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &yes);
}
RETRO_API void retro_get_system_info(struct retro_system_info *info)
{
   memset(info, 0, sizeof(*info));
   info->library_name = CASO == 11 ? "" : "Finto";
   info->library_version = "1.0";
   info->valid_extensions = "bin";
}
RETRO_API void retro_init(void)
{
   struct retro_log_callback log;
   struct retro_variable v2 = { "finto_v2", NULL }, legacy = { "finto_legacy", NULL };
   if (env(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &log))
   {
      logf = log.log;
      logf(RETRO_LOG_INFO, "finto: retro_init\n");
   }
   /* come molti core: il valore dell'opzione senza guardare se e' NULL */
   env(RETRO_ENVIRONMENT_GET_VARIABLE, &v2);
   env(RETRO_ENVIRONMENT_GET_VARIABLE, &legacy);
   if (strcmp(v2.value, "acceso") || strcmp(legacy.value, "uno"))
      abort();
   after_init = malloc(sizeof(int));
#if CASO == 3
   *(volatile int *)0 = 1;
#elif CASO == 4
   manca_in_libreria();
#elif CASO == 7
   for (;;)
      pause();
#elif CASO == 8
   exit(5);
#elif CASO == 12
   {
      /* come np2kai: un file nella cartella corrente; come RACE: la cartella
       * dei salvataggi senza l'ultima estensione, piu' .ngf */
      const char *sd = NULL, *home = getenv("HOME");
      char p[4096], *dot;
      FILE *f = fopen("scritto_qui.cfg", "w");
      if (f) fclose(f);
      /* e uno nella casa */
      if (home && strlen(home) < sizeof(p) - 16)
      {
         snprintf(p, sizeof(p), "%s/.finto.cfg", home);
         if ((f = fopen(p, "w"))) fclose(f);
      }
      if (env(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, &sd) && sd && strlen(sd) < sizeof(p) - 8)
      {
         strcpy(p, sd);
         if ((dot = strrchr(p, '.')))
            *dot = 0;
         strcat(p, ".ngf");
         if ((f = fopen(p, "w"))) fclose(f);
      }
   }
#elif CASO == 9
   if (fork() == 0)
   {
      FILE *f = fopen(getenv("FINTO_PID"), "w");
      if (f) { fprintf(f, "%d\n", (int)getpid()); fclose(f); }
      for (;;)
         pause();
   }
#endif
}
RETRO_API void retro_deinit(void)
{
#if CASO == 5
   *(volatile int *)0 = 1;
#endif
   free(after_init);
}
/* come Mesen: usa cio' che retro_init ha preparato */
RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb) { (void)cb; *after_init = 1; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { (void)cb; }
RETRO_API void retro_set_input_poll(retro_input_poll_t cb) { (void)cb; }
RETRO_API void retro_set_input_state(retro_input_state_t cb) { (void)cb; }
RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) { memset(info, 0, sizeof(*info)); }
RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
RETRO_API void retro_reset(void) { }
RETRO_API void retro_run(void) { }
RETRO_API size_t retro_serialize_size(void) { return 0; }
RETRO_API bool retro_serialize(void *data, size_t size) { (void)data; (void)size; return false; }
RETRO_API bool retro_unserialize(const void *data, size_t size) { (void)data; (void)size; return false; }
RETRO_API void retro_cheat_reset(void) { }
RETRO_API void retro_cheat_set(unsigned i, bool e, const char *c) { (void)i; (void)e; (void)c; }
RETRO_API bool retro_load_game(const struct retro_game_info *game) { (void)game; return false; }
RETRO_API bool retro_load_game_special(unsigned t, const struct retro_game_info *g, size_t n) { (void)t; (void)g; (void)n; return false; }
RETRO_API void retro_unload_game(void) { }
#if CASO != 10
RETRO_API unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
#endif
RETRO_API void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
RETRO_API size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
EOF
# CASO: 1 buono, 2 senza contenuto, 3 crash in retro_init, 4 simbolo non
# risolto, 5 crash in retro_deinit, 6 API 2, 7 bloccato, 8 exit, 9 lascia un
# processo, 10 senza retro_get_region, 11 senza nome, 12 scrive un file nella
# cartella corrente
mk() { gcc -shared -fPIC -O0 -w -I"${O}/tools/libretro" -DCASO="$2" -o "${T}/$1_libretro.so" "${T}/core.c" "${@:3}"; }
mk buono 1; mk nogame 2; mk crashinit 3; mk nonrisolto 4; mk crashdeinit 5; mk api2 6
mk bloccato 7; mk esce 8; mk figlio 9; mk senzaregion 10; mk senzanome 11; mk scrive 12
# un core buono legato a una libreria che poi non c'e' (come un core che vuole
# una libreria fuori dall'immagine)
echo 'int mancante(void) { return 1; }' > "${T}/mancante.c"
gcc -shared -fPIC -o "${T}/libmancante.so" "${T}/mancante.c"
mk condip 1 -L"${T}" -Wl,--no-as-needed -lmancante; rm -f "${T}/libmancante.so"
# con un tetto: un test che si blocca (un processo del core mai fermato) e'
# un fallimento, non una prova che non finisce
c() { timeout 60 "${T}/coretest" "$@" > "${T}/out" 2> "${T}/err"; }
line() { grep " $1_libretro.so " "${T}/out"; }

echo "rf35h-coretest: i core che partono"
c -l "${T}/log" "${T}/buono_libretro.so" "${T}/nogame_libretro.so"; rc=$?
ok "buono e senza contenuto: ok, esce 0" '[ "${rc}" = 0 ] && line buono | grep -q "^ok      buono_libretro.so \"Finto\" 1.0 \[[0-9]*s\]$" && line nogame | grep -q "\"Finto\" 1.0 (senza contenuto) \["'
ok "  ...le opzioni coi valori predefiniti (v2 e legacy), la callback video dopo retro_init" 'line buono | grep -q "^ok"'
ok "  ...il log del core nella sua cartella, il riassunto su stderr" 'grep -q "^finto: retro_init" "${T}/log/buono_libretro.so.log" && grep -q "2 core, 0 non partono" "${T}/err"'

echo "rf35h-coretest: i core che non partono"
c -t 3 "${T}/nonrisolto_libretro.so" "${T}/crashinit_libretro.so" "${T}/api2_libretro.so" "${T}/senzaregion_libretro.so" \
	"${T}/senzanome_libretro.so" "${T}/esce_libretro.so" "${T}/bloccato_libretro.so" "${T}/nonce_libretro.so" "${T}/condip_libretro.so" \
	"${T}/buono_libretro.so"; rc=$?
ok "esce 1, e il buono in fondo va lo stesso" '[ "${rc}" = 1 ] && line buono | grep -q "^ok" && grep -q "10 core, 9 non partono" "${T}/err"'
ok "simbolo non risolto: dlopen e il simbolo, senza il percorso del core (come dosbox senza glib)" 'line nonrisolto | grep -qx "NO      nonrisolto_libretro.so dlopen: undefined symbol: manca_in_libreria"'
ok "una libreria che manca: col suo nome" 'line condip | grep -qx "NO      condip_libretro.so dlopen: libmancante.so: cannot open shared object file: No such file or directory"'
ok "crash in retro_init: la fase, il segnale, la funzione e l'indirizzo" 'line crashinit | grep -q "^NO      crashinit_libretro.so retro_init: segnale 11 (Segmentation fault) in retro_init+0x[0-9a-f]*, indirizzo (nil)$"'
ok "API 2, simbolo mancante, nome vuoto" 'line api2 | grep -q "retro_api_version: 2 invece di 1" && line senzaregion | grep -q "simboli: manca retro_get_region" && line senzanome | grep -q "retro_get_system_info: library_name vuoto"'
ok "exit dentro retro_init, tempo scaduto, file che non c'e'" 'line esce | grep -q "retro_init: uscito con 5 senza finire" && line bloccato | grep -q "retro_init: tempo scaduto (3 s)" && line nonce | grep -qx "NO      nonce_libretro.so dlopen: cannot open shared object file: No such file or directory"'

echo "rf35h-coretest: avvisi, processi lasciati, uso"
c "${T}/crashdeinit_libretro.so"; rc=$?
ok "crash in retro_deinit dopo un avvio buono: avviso, esce 0 (come TyrQuake)" '[ "${rc}" = 0 ] && line crashdeinit | grep -q "^avviso  crashdeinit_libretro.so \"Finto\" 1.0: retro_deinit: segnale 11 (Segmentation fault) in retro_deinit+0x"'
FINTO_PID="${T}/figlio.pid" c "${T}/figlio_libretro.so"; rc=$?
# fermato vuol dire sparito o zombie (in un container chi lo raccoglie puo'
# metterci un po')
gone() { local s; s="$(ps -o stat= -p "$1" 2>/dev/null)"; [ -z "${s}" ] || [ "${s#Z}" != "${s}" ]; }
ok "un core che lascia un processo: il test finisce e lo ferma" '[ "${rc}" = 0 ] && [ -s "${T}/figlio.pid" ] && sleep 0.2 && gone "$(cat "${T}/figlio.pid")"'
c; rc1=$?; c -t 0 "${T}/buono_libretro.so"; rc2=$?; c -x "${T}/buono_libretro.so"; rc3=$?
ok "uso sbagliato: esce 2" '[ "${rc1}" = 2 ] && [ "${rc2}" = 2 ] && [ "${rc3}" = 2 ]'
TMPDIR="${T}/tmpd" ; mkdir -p "${TMPDIR}"; TMPDIR="${TMPDIR}" c "${T}/buono_libretro.so"
ok "la cartella temporanea dei core non resta" '[ -z "$(ls -A "${T}/tmpd")" ]'
mkdir -p "${T}/qui" "${T}/tmpq" "${T}/casa"; ( cd "${T}/qui" && HOME="${T}/casa" TMPDIR="${T}/tmpq" c ../scrive_libretro.so ); rc=$?
ok "un core che scrive nella cartella corrente, accanto ai salvataggi e in \$HOME: niente resta fuori, il percorso relativo va" '[ "${rc}" = 0 ] && line scrive | grep -q "^ok" && [ -z "$(ls -A "${T}/qui")" ] && [ -z "$(ls -A "${T}/tmpq")" ] && [ -z "$(ls -A "${T}/casa")" ]'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
