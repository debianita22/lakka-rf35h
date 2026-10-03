/*
 * ikemen_libretro.c - IKEMEN GO fra i "Core senza contenuto" di RetroArch.
 * devaOS / Lakka RF35H port. SPDX-License-Identifier: MIT
 *
 * Non emula niente: e' un lanciatore. IKEMEN GO e' un programma a se' (Go,
 * SDL2, OpenGL ES/OpenGL), mentre "Core senza contenuto" elenca solo
 * core libretro: quelli che nel loro .info hanno supports_no_game (e, col
 * filtro predefinito "Monouso", single_purpose). Questo core:
 *
 *  - dichiara che parte senza contenuto (SET_SUPPORT_NO_GAME);
 *  - mette il renderer di IKEMEN fra le sue opzioni, allineato a quello che
 *    IKEMEN usera' davvero ("rf35h-ikemen renderer": config.ini, anche se lo
 *    hai cambiato dentro IKEMEN o se e' tornato da solo a OpenGL ES);
 *  - per circa 2 s mostra un fotogramma nero e un avviso: il tempo per aprire
 *    il Menu rapido e cambiare il renderer. Col menu aperto RetroArch non
 *    chiama retro_run (menu_pause_libretro), quindi il conto si ferma, e
 *    "Chiudi contenuto" annulla l'avvio;
 *  - poi esegue "rf35h-ikemen start <renderer>": systemd avvia
 *    rf35h-ikemen.service, che e' in Conflicts= con retroarch.service, quindi
 *    chiude RetroArch (che salva ed esce come sempre) e lo riapre quando si
 *    esce da IKEMEN.
 *
 * Se il comando fallisce, o RetroArch non viene chiuso entro 15 s, si torna
 * al menu (RETRO_ENVIRONMENT_SHUTDOWN) con un messaggio.
 *
 * Vulkan non c'e' fra i renderer: Mesa PanVK sul Mali-G31 espone Vulkan 1.0,
 * il renderer Vulkan di IKEMEN vuole la 1.3 e, forzandola, parte senza errori
 * ma lascia lo schermo nero (provato sulla console, 25/9/2026). rf35h-ikemen lo
 * spegne anche dentro IKEMEN (IKEMEN_DISABLE_VULKAN, patch 0003).
 *
 * Per le prove fuori dal device: RF35H_IKEMEN_CMD sostituisce
 * /usr/bin/rf35h-ikemen.
 */
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#include <libretro.h>

#define FB_W          320
#define FB_H          240
#define RATE          44100
#define FPS           60
#define WAIT_FRAMES   (2 * FPS)    /* finestra per il Menu rapido */
#define GIVEUP_FRAMES (15 * FPS)   /* dopo il comando: RetroArch doveva essere chiuso */
#define KEY           "ikemen_renderer"

static uint32_t fb[FB_W * FB_H];               /* nero */
static int16_t  silence[2 * (RATE / FPS)];     /* stereo, un fotogramma */

static retro_environment_t        env_cb;
static retro_video_refresh_t      video_cb;
static retro_audio_sample_batch_t audio_batch_cb;
static retro_input_poll_t         input_poll_cb;
static retro_log_printf_t         log_cb;

static unsigned frame, launched_at;
static bool     launched, italian, msg_ext;

static const char *cmd_path(void)
{
   const char *p = getenv("RF35H_IKEMEN_CMD");
   return (p && *p) ? p : "/usr/bin/rf35h-ikemen";
}

#define T(it, en) (italian ? (it) : (en))

/* Opzioni: due renderer, OpenGL ES predefinito. */
static struct retro_core_option_definition opts_us[] = {
   { KEY, "Renderer",
     "OpenGL ES is the default. OpenGL 3.3 goes through Mesa's desktop GL on "
     "the same GPU. Vulkan is not offered: the Mali-G31 driver exposes Vulkan "
     "1.0 and IKEMEN needs 1.3. Applied when IKEMEN GO starts; IKEMEN's "
     "Options > Video changes the same setting.",
     { { "opengles", "OpenGL ES 3.2" },
       { "opengl",   "OpenGL 3.3" },
       { NULL, NULL } },
     "opengles" },
   { NULL, NULL, NULL, { { NULL, NULL } }, NULL },
};

static struct retro_core_option_definition opts_it[] = {
   { KEY, "Renderer",
     "OpenGL ES e' il predefinito. OpenGL 3.3 passa dal GL desktop di Mesa "
     "sulla stessa GPU. Vulkan non c'e': il driver del Mali-G31 espone Vulkan "
     "1.0 e IKEMEN vuole la 1.3. Si applica all'avvio di IKEMEN GO; "
     "Opzioni > Video di IKEMEN cambia la stessa impostazione.",
     { { "opengles", "OpenGL ES 3.2" },
       { "opengl",   "OpenGL 3.3" },
       { NULL, NULL } },
     "opengles" },
   { NULL, NULL, NULL, { { NULL, NULL } }, NULL },
};

/* "vulkan" puo' ancora arrivare da uno stato salvato da una versione
 * precedente: non e' valido, e resta il renderer che IKEMEN usera' davvero. */
static bool valid_renderer(const char *v)
{
   return v && (!strcmp(v, "opengles") || !strcmp(v, "opengl"));
}

static void notify(const char *msg, unsigned ms)
{
   if (msg_ext)
   {
      struct retro_message_ext m;
      m.msg      = msg;
      m.duration = ms;
      m.priority = 3;
      m.level    = RETRO_LOG_INFO;
      m.target   = RETRO_MESSAGE_TARGET_ALL;
      m.type     = RETRO_MESSAGE_TYPE_NOTIFICATION;
      m.progress = -1;
      if (env_cb(RETRO_ENVIRONMENT_SET_MESSAGE_EXT, &m))
         return;
   }
   {
      struct retro_message m;
      m.msg    = msg;
      m.frames = ms * FPS / 1000;
      env_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &m);
   }
}

static void logmsg(enum retro_log_level level, const char *msg)
{
   if (log_cb)
      log_cb(level, "[IKEMEN GO] %s\n", msg);
}

/* system() con SIGCHLD al default: se RetroArch lo ha messo a SIG_IGN (lo fa
 * la sintesi vocale), system() non potrebbe raccogliere il figlio e
 * risponderebbe -1 anche a comando riuscito. */
static int run_cmd(const char *cmd)
{
   struct sigaction dfl, old;
   int rc;
   memset(&dfl, 0, sizeof(dfl));
   dfl.sa_handler = SIG_DFL;
   sigemptyset(&dfl.sa_mask);
   sigaction(SIGCHLD, &dfl, &old);
   rc = system(cmd);
   sigaction(SIGCHLD, &old, NULL);
   return (rc != -1 && WIFEXITED(rc)) ? WEXITSTATUS(rc) : -1;
}

/* L'opzione mostra il renderer che IKEMEN usera' davvero. */
static void mirror_renderer(void)
{
   char cmd[512], line[64] = "";
   struct retro_variable var;
   FILE *f;
   size_t n;

   snprintf(cmd, sizeof(cmd), "'%s' renderer 2>/dev/null", cmd_path());
   if (!(f = popen(cmd, "r")))
      return;
   if (!fgets(line, sizeof(line), f))
      line[0] = '\0';
   pclose(f);
   n = strcspn(line, "\r\n");
   line[n] = '\0';
   if (!valid_renderer(line))
      return;
   var.key   = KEY;
   var.value = line;
   env_cb(RETRO_ENVIRONMENT_SET_VARIABLE, &var);
}

static bool launch(void)
{
   char cmd[512];
   struct retro_variable var;
   var.key   = KEY;
   var.value = NULL;
   if (!env_cb(RETRO_ENVIRONMENT_GET_VARIABLE, &var) || !valid_renderer(var.value))
      var.value = "";   /* nessuna scelta valida: resta quella di IKEMEN */
   snprintf(cmd, sizeof(cmd), "'%s' start %s >/dev/null 2>&1", cmd_path(), var.value);
   logmsg(RETRO_LOG_INFO, cmd);
   return run_cmd(cmd) == 0;
}

void retro_set_environment(retro_environment_t cb)
{
   bool no_game = true;
   unsigned version = 0, lang = RETRO_LANGUAGE_ENGLISH;
   struct retro_log_callback logging;

   env_cb = cb;
   cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &no_game);
   /* RetroArch richiama retro_set_environment anche sul core gia' caricato
    * (CMD_EVENT_LOAD_CORE_PERSIST, libretro_get_environment_info): prima con una
    * callback ridotta, poi con quella vera ma in modalita' "ignora tutto", dove
    * ogni richiesta risponde false. Quindi si aggiorna solo cio' che la
    * callback sa dire, senza tornare ai valori di ripiego. */
   logging.log = NULL;
   if (cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging) && logging.log)
      log_cb = logging.log;
   if (cb(RETRO_ENVIRONMENT_GET_LANGUAGE, &lang))
      italian = (lang == RETRO_LANGUAGE_ITALIAN);
   version = 0;
   if (cb(RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION, &version))
      msg_ext = (version >= 1);

   version = 0;
   if (cb(RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION, &version) && version >= 1)
   {
      struct retro_core_options_intl intl;
      intl.us    = opts_us;
      intl.local = italian ? opts_it : NULL;
      cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL, &intl);
   }
   else
   {
      struct retro_variable vars[2];
      vars[0].key   = KEY;
      vars[0].value = "Renderer; opengles|opengl";
      vars[1].key   = NULL;
      vars[1].value = NULL;
      cb(RETRO_ENVIRONMENT_SET_VARIABLES, vars);
   }
}

void retro_set_video_refresh(retro_video_refresh_t cb)           { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb)             { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_batch_cb = cb; }
void retro_set_input_poll(retro_input_poll_t cb)                 { input_poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb)               { (void)cb; }

unsigned retro_api_version(void) { return RETRO_API_VERSION; }
void retro_init(void)   { }
void retro_deinit(void) { }

void retro_get_system_info(struct retro_system_info *info)
{
   memset(info, 0, sizeof(*info));
   info->library_name     = "IKEMEN GO";
   info->library_version  = "1.0.0";
   info->valid_extensions = "";
   info->need_fullpath    = true;
   info->block_extract    = true;
}

void retro_get_system_av_info(struct retro_system_av_info *info)
{
   memset(info, 0, sizeof(*info));
   info->timing.fps            = FPS;
   info->timing.sample_rate    = RATE;
   info->geometry.base_width   = FB_W;
   info->geometry.base_height  = FB_H;
   info->geometry.max_width    = FB_W;
   info->geometry.max_height   = FB_H;
   info->geometry.aspect_ratio = 4.0f / 3.0f;
}

void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
void retro_reset(void) { frame = 0; launched = false; }

bool retro_load_game(const struct retro_game_info *game)
{
   enum retro_pixel_format fmt = RETRO_PIXEL_FORMAT_XRGB8888;
   (void)game;
   if (!env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt))
      return false;
   if (access(cmd_path(), X_OK) != 0)
   {
      notify(T("IKEMEN GO non e' installato in questa immagine",
               "IKEMEN GO is not installed on this image"), 4000);
      return false;
   }
   mirror_renderer();
   frame    = 0;
   launched = false;
   notify(T("IKEMEN GO parte fra 2 s. Renderer: Menu rapido (Select+Start) > Opzioni del core",
            "IKEMEN GO starts in 2 s. Renderer: Quick Menu (Select+Start) > Core Options"), 2500);
   return true;
}

bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num)
{
   (void)type; (void)info; (void)num;
   return false;
}

void retro_unload_game(void) { }

void retro_run(void)
{
   input_poll_cb();
   video_cb(fb, FB_W, FB_H, FB_W * sizeof(uint32_t));
   if (audio_batch_cb)
      audio_batch_cb(silence, RATE / FPS);
   frame++;

   if (!launched && frame >= WAIT_FRAMES)
   {
      launched    = true;
      launched_at = frame;
      if (launch())
         notify(T("Avvio di IKEMEN GO...", "Starting IKEMEN GO..."), 5000);
      else
      {
         logmsg(RETRO_LOG_ERROR, "rf35h-ikemen start fallito");
         notify(T("IKEMEN GO non parte: vedi /storage/rf35h-logs",
                  "Could not start IKEMEN GO: see /storage/rf35h-logs"), 5000);
         env_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
      }
   }
   else if (launched && frame - launched_at == GIVEUP_FRAMES)
   {
      logmsg(RETRO_LOG_ERROR, "RetroArch non e' stato chiuso: avvio non riuscito");
      notify(T("IKEMEN GO non e' partito: vedi /storage/rf35h-logs",
               "IKEMEN GO did not start: see /storage/rf35h-logs"), 5000);
      env_cb(RETRO_ENVIRONMENT_SHUTDOWN, NULL);
   }
}

size_t retro_serialize_size(void) { return 0; }
bool retro_serialize(void *data, size_t size)         { (void)data; (void)size; return false; }
bool retro_unserialize(const void *data, size_t size) { (void)data; (void)size; return false; }
void retro_cheat_reset(void) { }
void retro_cheat_set(unsigned index, bool enabled, const char *code) { (void)index; (void)enabled; (void)code; }
unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
