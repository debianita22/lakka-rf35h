/*
 * test-ikemen-libretro.c - prova il core lanciatore di IKEMEN GO con un
 * frontend finto, senza RetroArch e senza device.
 *
 *   cc -I<retroarch>/libretro-common/include -o t tools/test-ikemen-libretro.c -ldl
 *   ./t ./ikemen_libretro.so
 *
 * Il frontend finto implementa le chiamate d'ambiente che il core usa
 * (opzioni v1 intl e legacy, SET/GET_VARIABLE, messaggi, SHUTDOWN) e fa girare
 * i fotogrammi. Al posto di rf35h-ikemen c'e' uno script finto
 * (RF35H_IKEMEN_CMD) che registra gli argomenti.
 */
#include <dlfcn.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <libretro.h>

static struct {
   void *h;
   void (*set_environment)(retro_environment_t);
   void (*set_video_refresh)(retro_video_refresh_t);
   void (*set_audio_sample)(retro_audio_sample_t);
   void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
   void (*set_input_poll)(retro_input_poll_t);
   void (*set_input_state)(retro_input_state_t);
   void (*init)(void);
   void (*deinit)(void);
   unsigned (*api_version)(void);
   void (*get_system_info)(struct retro_system_info *);
   void (*get_system_av_info)(struct retro_system_av_info *);
   bool (*load_game)(const struct retro_game_info *);
   void (*unload_game)(void);
   void (*run)(void);
} core;

/* stato del frontend finto */
static unsigned lang, opt_version, video_calls, audio_frames;
static bool no_game, shutdown_req, fmt_ok;
static char keys_desc[256], values[8][32], current[32], last_msg[512];
static int nvalues, ignore_all;
static unsigned last_msg_cmd;

static void fe_log(enum retro_log_level level, const char *fmt, ...)
{
   va_list ap; (void)level;
   va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap);
}

static void set_values_from_def(const struct retro_core_option_definition *d)
{
   int i;
   nvalues = 0;
   for (i = 0; d[0].values[i].value && i < 8; i++)
      snprintf(values[nvalues++], sizeof(values[0]), "%s", d[0].values[i].value);
   snprintf(current, sizeof(current), "%s", d[0].default_value ? d[0].default_value : values[0]);
   snprintf(keys_desc, sizeof(keys_desc), "%s|%s", d[0].key, d[0].desc);
}

/* Come la callback ridotta di RetroArch per il sondaggio del core
 * (runloop_environ_cb_get_system_info): conosce solo SET_SUPPORT_NO_GAME. */
static bool env_restricted(unsigned cmd, void *data)
{
   (void)data;
   return cmd == RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME;
}

static bool env(unsigned cmd, void *data)
{
   if (ignore_all)   /* RUNLOOP_FLAG_IGNORE_ENVIRONMENT_CB */
      return false;
   switch (cmd)
   {
      case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: no_game = *(bool *)data; return true;
      case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: ((struct retro_log_callback *)data)->log = fe_log; return true;
      case RETRO_ENVIRONMENT_GET_LANGUAGE: *(unsigned *)data = lang; return true;
      case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION: *(unsigned *)data = 1; return true;
      case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *(unsigned *)data = opt_version; return true;
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
      {
         const struct retro_core_options_intl *i = data;
         set_values_from_def(i->us);
         if (i->local) /* il frontend userebbe le stringhe locali: le registro */
            snprintf(keys_desc, sizeof(keys_desc), "%s|%s|%s", i->local[0].key, i->local[0].desc,
                     i->local[0].info ? i->local[0].info : "");
         return true;
      }
      case RETRO_ENVIRONMENT_SET_VARIABLES:
      {
         const struct retro_variable *v = data;
         const char *p = strchr(v[0].value, ';');
         char buf[128];
         nvalues = 0;
         snprintf(keys_desc, sizeof(keys_desc), "%s|legacy|%s", v[0].key, v[0].value);
         if (p) {
            char *tok, *save;
            snprintf(buf, sizeof(buf), "%s", p + 2);
            for (tok = strtok_r(buf, "|", &save); tok && nvalues < 8; tok = strtok_r(NULL, "|", &save))
               snprintf(values[nvalues++], sizeof(values[0]), "%s", tok);
         }
         snprintf(current, sizeof(current), "%s", values[0]);
         return true;
      }
      case RETRO_ENVIRONMENT_SET_VARIABLE:
      {
         const struct retro_variable *v = data;
         int i;
         if (!v) return true;
         for (i = 0; i < nvalues; i++)
            if (!strcmp(values[i], v->value)) { snprintf(current, sizeof(current), "%s", v->value); return true; }
         return false;   /* come RetroArch: valore non ammesso */
      }
      case RETRO_ENVIRONMENT_GET_VARIABLE:
      {
         struct retro_variable *v = data;
         v->value = current;
         return true;
      }
      case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
         fmt_ok = (*(enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888);
         return fmt_ok;
      case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
         snprintf(last_msg, sizeof(last_msg), "%s", ((struct retro_message_ext *)data)->msg);
         last_msg_cmd = cmd;
         return true;
      case RETRO_ENVIRONMENT_SET_MESSAGE:
         snprintf(last_msg, sizeof(last_msg), "%s", ((struct retro_message *)data)->msg);
         last_msg_cmd = cmd;
         return true;
      case RETRO_ENVIRONMENT_SHUTDOWN: shutdown_req = true; return true;
      default: return false;
   }
}

static void video(const void *d, unsigned w, unsigned h, size_t pitch)
{ (void)d; if (w == 320 && h == 240 && pitch == 320 * 4) video_calls++; }
static void audio1(int16_t l, int16_t r) { (void)l; (void)r; }
static size_t audio(const int16_t *d, size_t frames) { (void)d; audio_frames += frames; return frames; }
static void poll_(void) { }
static int16_t state_(unsigned p, unsigned d, unsigned i, unsigned id) { (void)p; (void)d; (void)i; (void)id; return 0; }

#define SYM(f) do { *(void **)&core.f = dlsym(core.h, "retro_" #f); if (!core.f) { fprintf(stderr, "manca retro_" #f "\n"); exit(2); } } while (0)

/* Ogni sessione ricarica il core da zero, come RetroArch che lo chiude con
 * dlclose() quando si esce dal contenuto: niente stato che passa di prova in prova. */
static const char *core_path;
static void open_core(void)
{
   if (!(core.h = dlopen(core_path, RTLD_NOW | RTLD_LOCAL))) { fprintf(stderr, "%s\n", dlerror()); exit(2); }
   SYM(set_environment); SYM(set_video_refresh); SYM(set_audio_sample); SYM(set_audio_sample_batch);
   SYM(set_input_poll); SYM(set_input_state); SYM(init); SYM(deinit); SYM(api_version);
   SYM(get_system_info); SYM(get_system_av_info); SYM(load_game); SYM(unload_game); SYM(run);
}
static void close_core(void) { dlclose(core.h); memset(&core, 0, sizeof(core)); }

static char dir[256], log_path[300], fake[300];
static int pass, fail;
static void ok(const char *what, int cond) { if (cond) { pass++; printf("  ok    %s\n", what); } else { fail++; printf("  FALLITO %s\n", what); } }

static void write_fake(const char *state, int start_rc)
{
   FILE *f = fopen(fake, "w");
   fprintf(f, "#!/bin/sh\necho \"$*\" >> '%s'\n"
              "case \"$1\" in renderer) echo '%s' ;; start) exit %d ;; esac\n", log_path, state, start_rc);
   fclose(f); chmod(fake, 0755);
   unlink(log_path);
}

static char *read_log(void)
{
   static char buf[1024]; size_t n = 0; FILE *f = fopen(log_path, "r");
   buf[0] = '\0';
   if (f) { n = fread(buf, 1, sizeof(buf) - 1, f); buf[n] = '\0'; fclose(f); }
   return buf;
}

/* un ciclo completo: environment, init, load, n fotogrammi (con cambio
 * dell'opzione al fotogramma change_at, se > 0) */
static unsigned reprobe_at;   /* fotogramma in cui RetroArch risonda il core */
static bool session(unsigned language, unsigned optv, unsigned frames,
                    unsigned change_at, const char *change_to)
{
   unsigned i; bool loaded;
   lang = language; opt_version = optv; shutdown_req = false; no_game = false;
   video_calls = audio_frames = 0; last_msg[0] = '\0';
   open_core();
   core.set_environment(env);
   core.set_video_refresh(video); core.set_audio_sample(audio1); core.set_audio_sample_batch(audio);
   core.set_input_poll(poll_); core.set_input_state(state_);
   core.init();
   loaded = core.load_game(NULL);
   for (i = 1; loaded && i <= frames && !shutdown_req; i++)
   {
      if (change_at && i == change_at) snprintf(current, sizeof(current), "%s", change_to);
      if (reprobe_at && i == reprobe_at)
      {  /* CMD_EVENT_LOAD_CORE_PERSIST -> libretro_get_environment_info */
         core.set_environment(env_restricted);
         ignore_all = 1; core.set_environment(env); ignore_all = 0;
      }
      core.run();
   }
   if (loaded) core.unload_game();
   core.deinit();
   close_core();
   return loaded;
}

int main(int argc, char **argv)
{
   struct retro_system_info si; struct retro_system_av_info av;
   if (argc < 2) { fprintf(stderr, "uso: %s ikemen_libretro.so\n", argv[0]); return 2; }
   snprintf(dir, sizeof(dir), "/tmp/ikl-%d", (int)getpid()); mkdir(dir, 0755);
   snprintf(log_path, sizeof(log_path), "%s/calls", dir);
   snprintf(fake, sizeof(fake), "%s/rf35h-ikemen", dir);
   setenv("RF35H_IKEMEN_CMD", fake, 1);
   /* un loader Vulkan presente non deve riportare Vulkan fra le opzioni */
   setenv("IKEMEN_VK_LOADER", "/bin/sh", 1);

   core_path = argv[1];
   open_core();
   core.get_system_info(&si); core.get_system_av_info(&av);
   ok("API 1, IKEMEN GO, senza contenuto (need_fullpath, niente estensioni)",
      core.api_version() == RETRO_API_VERSION && !strcmp(si.library_name, "IKEMEN GO")
      && si.need_fullpath && si.valid_extensions && !*si.valid_extensions);
   ok("AV: 320x240, 60 fps, 44100 Hz", av.geometry.base_width == 320 && av.geometry.base_height == 240
      && av.timing.fps == 60 && av.timing.sample_rate == 44100);
   close_core();

   /* 1. italiano, IKEMEN su opengl: attesa, poi start opengl */
   write_fake("opengl", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 119, 0, NULL);
   ok("supports_no_game dichiarato, formato XRGB8888", no_game && fmt_ok);
   ok("opzioni: 2 renderer (opengles, opengl), niente vulkan, testi italiani",
      nvalues == 2 && !strcmp(values[0], "opengles") && !strcmp(values[1], "opengl")
      && strstr(keys_desc, "Vulkan non c'e'"));
   ok("opzione allineata allo stato di IKEMEN (opengl)", !strcmp(current, "opengl"));
   ok("119 fotogrammi: ancora nessun avvio, avviso mostrato",
      !strstr(read_log(), "start") && strstr(last_msg, "Menu rapido") && video_calls == 119 && audio_frames == 119 * 735);
   write_fake("opengl", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 120, 0, NULL);
   ok("fotogramma 120: 'start opengl', nessuno SHUTDOWN", strstr(read_log(), "start opengl") && !shutdown_req
      && strstr(last_msg, "Avvio di IKEMEN GO"));

   /* 1b. RetroArch risonda il core mentre gira (come CMD_EVENT_LOAD_CORE_PERSIST):
    * lingua, messaggi estesi e callback vera devono sopravvivere */
   write_fake("opengl", 0); reprobe_at = 10;
   session(RETRO_LANGUAGE_ITALIAN, 1, 125, 0, NULL);
   reprobe_at = 0;
   ok("sondaggio a core avviato: resta italiano, messaggi estesi, start opengl",
      strstr(last_msg, "Avvio di IKEMEN GO") && last_msg_cmd == RETRO_ENVIRONMENT_SET_MESSAGE_EXT
      && strstr(read_log(), "start opengl") && !shutdown_req);

   /* 2. il renderer cambiato dal Menu rapido durante l'attesa vince */
   write_fake("opengl", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 130, 60, "opengles");
   ok("cambio a opengles durante l'attesa: 'start opengles'", strstr(read_log(), "start opengles") != NULL);

   /* 3. inglese, stato 'vulkan' rimasto da una versione precedente: non passa */
   write_fake("vulkan", 0);
   session(RETRO_LANGUAGE_ENGLISH, 1, 130, 0, NULL);
   ok("inglese: 2 renderer, testi inglesi", nvalues == 2 && strstr(keys_desc, "Renderer") && !strstr(keys_desc, "Vulkan non"));
   ok("  ...stato 'vulkan' non allineato, parte con opengles", !strcmp(current, "opengles") && strstr(read_log(), "start opengles"));

   /* 3b. un valore 'vulkan' dal frontend (.opt vecchio) non viene passato */
   write_fake("opengles", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 130, 60, "vulkan");
   ok("valore 'vulkan' dal frontend: start senza renderer, decide rf35h-ikemen",
      strstr(read_log(), "start") && !strstr(read_log(), "vulkan") && !shutdown_req);

   /* 4. frontend con opzioni legacy (versione 0) */
   write_fake("opengl", 0);
   session(RETRO_LANGUAGE_ENGLISH, 0, 130, 0, NULL);
   ok("opzioni legacy: 'Renderer; opengles|opengl', stato opengl", strstr(keys_desc, "legacy|Renderer; opengles|opengl")
      && !strcmp(current, "opengl") && strstr(read_log(), "start opengl"));

   /* 5. start che fallisce: torna al menu */
   write_fake("opengles", 1);
   session(RETRO_LANGUAGE_ITALIAN, 1, 200, 0, NULL);
   ok("start fallito: SHUTDOWN e messaggio", shutdown_req && strstr(last_msg, "non parte"));

   /* 6. start riuscito ma RetroArch non viene chiuso: dopo 15 s si torna al menu */
   write_fake("opengles", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 120 + 899, 0, NULL);
   ok("14,98 s dopo l'avvio: si aspetta ancora", !shutdown_req);
   write_fake("opengles", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 120 + 900, 0, NULL);
   ok("15 s dopo l'avvio: SHUTDOWN e messaggio", shutdown_req && strstr(last_msg, "non e' partito"));

   /* 7. SIGCHLD ignorato dal frontend (RetroArch dopo la sintesi vocale) */
   signal(SIGCHLD, SIG_IGN);
   write_fake("opengles", 0);
   session(RETRO_LANGUAGE_ITALIAN, 1, 130, 0, NULL);
   ok("SIGCHLD ignorato: l'avvio riesce lo stesso", strstr(read_log(), "start opengles") && !shutdown_req);
   signal(SIGCHLD, SIG_DFL);

   /* 8. lanciatore assente: il core non si carica */
   unlink(fake);
   ok("rf35h-ikemen assente: load_game fallisce con messaggio",
      !session(RETRO_LANGUAGE_ITALIAN, 1, 10, 0, NULL) && strstr(last_msg, "non e' installato"));

   printf("--- %d ok, %d falliti\n", pass, fail);
   {  char rm[320]; snprintf(rm, sizeof(rm), "rm -rf '%s'", dir); if (system(rm)) { } }
   return fail ? 1 : 0;
}
