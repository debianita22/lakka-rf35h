/*
 * rf35h-coretest.c - carica i core libretro uno per uno come fa RetroArch, e
 * dice quali non partono.
 *
 *   rf35h-coretest [-t secondi] [-l cartella] core_libretro.so...
 *
 * Per ogni core, in un processo a parte (un core che va in crash o si blocca
 * non ferma gli altri), i passi di RetroArch quando apre un core:
 *   dlopen con RTLD_NOW      una libreria che manca o un simbolo non risolto si
 *                            vedono qui, come in RetroArch;
 *   i 25 simboli retro_*     RetroArch li vuole tutti (runloop.c, SYMBOL());
 *   retro_api_version, retro_set_environment, retro_get_system_info,
 *   retro_init, poi le callback di video, audio e input (RetroArch le passa
 *   dopo retro_init: Mesen ne ha bisogno);
 *   retro_deinit.
 * Nessun contenuto: retro_load_game no (i lanciatori, IKEMEN e GTA SA,
 * avvierebbero i loro servizi).
 *
 * L'ambiente risponde come RetroArch alle richieste che un core fa all'avvio:
 * log, prestazioni, rumble, cartelle (una temporanea, vuota: nessun BIOS),
 * lingua, opzioni (versione 2; GET_VARIABLE da' il valore predefinito, come
 * RetroArch senza configurazione: molti core non guardano se e' NULL), formato
 * dei pixel, descrittori. Al resto "no", come un frontend che non le conosce.
 *
 * Una riga per core su stdout:
 *   ok      <file> "<library_name>" <versione>[ (senza contenuto)] [<secondi>s]
 *   avviso  <file> "<library_name>" <versione>: retro_deinit: <perche'>
 *   NO      <file> <fase>: <perche'>
 * "avviso": il core parte, ma va in crash (o si blocca) chiuso senza contenuto,
 * cosa che in RetroArch succede di rado. Un crash dice la funzione (o il
 * file) e l'indirizzo. Esce 0 se nessun NO, 1 se no, 2 per un uso sbagliato.
 * Con -l, il log di ogni core (stdout, stderr e il log di libretro) in
 * <cartella>/<file>.log; senza, si buttano. -t: secondi per core (predefinito
 * 120: sotto qemu il dlopen dei core grandi e' lento).
 *
 * In CI (ci-build.sh coretest) gira sotto qemu-aarch64, sul SYSTEM della
 * release o sull'albero dei core, con le librerie che RetroArch ha gia' caricato
 * (--preload del loader): un core che conta su quelle (libm, libstdc++) va,
 * come sulla console. Sulla console: rf35h-coretest /usr/lib/libretro/<core>.
 *
 * libretro.h: tools/libretro/, quello di RetroArch 69a4f0ea1e8a
 * (libretro-common/include/libretro.h, licenza MIT nel file).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <ucontext.h>
#include <unistd.h>
#include <libretro.h>

/* i simboli che RetroArch carica tutti */
static const char *const syms[] = {
   "retro_init", "retro_deinit", "retro_api_version",
   "retro_get_system_info", "retro_get_system_av_info",
   "retro_set_environment", "retro_set_video_refresh",
   "retro_set_audio_sample", "retro_set_audio_sample_batch",
   "retro_set_input_poll", "retro_set_input_state",
   "retro_set_controller_port_device", "retro_reset", "retro_run",
   "retro_serialize_size", "retro_serialize", "retro_unserialize",
   "retro_cheat_reset", "retro_cheat_set", "retro_load_game",
   "retro_load_game_special", "retro_unload_game", "retro_get_region",
   "retro_get_memory_data", "retro_get_memory_size", NULL
};

static int rpipe = -1;            /* figlio -> padre */
static char dir[PATH_MAX];        /* la cartella delle prove, temporanea */
static char sysdir[PATH_MAX + 16]; /* <dir>/libretro: sistema, salvataggi, asset */
static char core_path[PATH_MAX];
static char cur_phase[64] = "avvio";
static bool no_game;

static const char *base_name(const char *p)
{
   const char *b = strrchr(p, '/');
   return b ? b + 1 : p;
}

/* Figlio -> padre, una riga per messaggio: "F <fase>" prima di ogni passo,
 * "I <informazioni del core>" quando e' partito, "R <risultato>" alla fine (o
 * dal gestore di un crash). */
static void tell(const char *fmt, ...)
{
   char buf[1024];
   va_list ap;
   int n;
   va_start(ap, fmt);
   n = vsnprintf(buf, sizeof(buf) - 1, fmt, ap);
   va_end(ap);
   if (n < 0)
      return;
   if (n > (int)sizeof(buf) - 2)
      n = sizeof(buf) - 2;
   if (buf[0] == 'F' && buf[1] == ' ')
      snprintf(cur_phase, sizeof(cur_phase), "%.*s", n - 2, buf + 2);
   buf[n++] = '\n';
   if (write(rpipe, buf, n) < 0)
      _exit(3);
}

/* Un crash nel core: dove (funzione, o file e scostamento, con dladdr) e su
 * quale indirizzo; poi lo stesso segnale, che il padre vede. */
static void on_crash(int sig, siginfo_t *si, void *uc)
{
   char buf[768];
   Dl_info di;
   void *pc = NULL;
   const char *where = "?";
   long off = 0;
   int n;
#if defined(__aarch64__)
   pc = (void *)((ucontext_t *)uc)->uc_mcontext.pc;
#elif defined(__x86_64__)
   pc = (void *)((ucontext_t *)uc)->uc_mcontext.gregs[REG_RIP];
#else
   (void)uc;
#endif
   memset(&di, 0, sizeof(di));
   if (pc && dladdr(pc, &di))
   {
      if (di.dli_sname)
      {
         where = di.dli_sname;
         off = (long)((char *)pc - (char *)di.dli_saddr);
      }
      else if (di.dli_fname)
      {
         where = base_name(di.dli_fname);
         off = (long)((char *)pc - (char *)di.dli_fbase);
      }
   }
   n = snprintf(buf, sizeof(buf), "R NO %s: segnale %d (%s) in %s+0x%lx, indirizzo %p\n",
                cur_phase, sig, strsignal(sig), where, off, si ? si->si_addr : NULL);
   if (n > 0 && write(rpipe, buf, (size_t)n < sizeof(buf) ? (size_t)n : sizeof(buf) - 1) < 0)
      _exit(3);
   signal(sig, SIG_DFL);
   raise(sig);
}

/* Le opzioni del core, chiave e valore predefinito, da SET_VARIABLES o
 * SET_CORE_OPTIONS* */
#define MAX_OPTS 4096
static struct { char *key, *val; } opts[MAX_OPTS];
static int nopts;

static void opt_add(const char *key, const char *val, size_t vlen)
{
   int i;
   if (!key || !val || nopts >= MAX_OPTS)
      return;
   for (i = 0; i < nopts; i++)
      if (!strcmp(opts[i].key, key))
         return;
   opts[nopts].key = strdup(key);
   opts[nopts].val = strndup(val, vlen);
   nopts++;
}

/* "Descrizione; predefinito|altro|..." */
static void opts_legacy(const struct retro_variable *v)
{
   for (; v && v->key; v++)
   {
      const char *d = v->value ? strstr(v->value, "; ") : NULL;
      if (d)
         opt_add(v->key, d + 2, strcspn(d + 2, "|"));
   }
}

static void opts_v1(const struct retro_core_option_definition *d)
{
   for (; d && d->key; d++)
   {
      const char *val = d->default_value ? d->default_value : d->values[0].value;
      if (val)
         opt_add(d->key, val, strlen(val));
   }
}

static void opts_v2(const struct retro_core_options_v2 *o)
{
   const struct retro_core_option_v2_definition *d;
   for (d = o ? o->definitions : NULL; d && d->key; d++)
   {
      const char *val = d->default_value ? d->default_value : d->values[0].value;
      if (val)
         opt_add(d->key, val, strlen(val));
   }
}

static const char *opt_get(const char *key)
{
   int i;
   for (i = 0; key && i < nopts; i++)
      if (!strcmp(opts[i].key, key))
         return opts[i].val;
   return NULL;
}

static void RETRO_CALLCONV fe_log(enum retro_log_level level, const char *fmt, ...)
{
   va_list ap;
   (void)level;
   va_start(ap, fmt);
   vfprintf(stderr, fmt, ap);
   va_end(ap);
}

/* l'interfaccia delle prestazioni: RetroArch la da' sempre, e qualche core la
 * usa senza guardare se c'e' */
static retro_time_t RETRO_CALLCONV fe_time_usec(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (retro_time_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}
static uint64_t RETRO_CALLCONV fe_cpu_features(void) { return 0; }
static retro_perf_tick_t RETRO_CALLCONV fe_perf_counter(void) { return 0; }
static void RETRO_CALLCONV fe_perf(struct retro_perf_counter *c) { (void)c; }
static void RETRO_CALLCONV fe_perf_log(void) { }
static bool RETRO_CALLCONV fe_rumble(unsigned p, enum retro_rumble_effect e, uint16_t s)
{
   (void)p; (void)e; (void)s;
   return true;
}

static bool RETRO_CALLCONV fe_env(unsigned cmd, void *data)
{
   switch (cmd)
   {
      case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
         ((struct retro_log_callback *)data)->log = fe_log;
         return true;
      case RETRO_ENVIRONMENT_GET_PERF_INTERFACE:
      {
         struct retro_perf_callback *cb = data;
         cb->get_time_usec = fe_time_usec;
         cb->get_cpu_features = fe_cpu_features;
         cb->get_perf_counter = fe_perf_counter;
         cb->perf_register = fe_perf;
         cb->perf_start = fe_perf;
         cb->perf_stop = fe_perf;
         cb->perf_log = fe_perf_log;
         return true;
      }
      case RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE:
         ((struct retro_rumble_interface *)data)->set_rumble_state = fe_rumble;
         return true;
      case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
      case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
      case RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
         *(const char **)data = sysdir;
         return true;
      case RETRO_ENVIRONMENT_GET_LIBRETRO_PATH:
         *(const char **)data = core_path;
         return true;
      case RETRO_ENVIRONMENT_GET_LANGUAGE:
         *(unsigned *)data = RETRO_LANGUAGE_ENGLISH;
         return true;
      case RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS:
         *(unsigned *)data = 4;
         return true;
      case RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
         *(int *)data = 3;
         return true;
      case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION:
      case RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
         *(unsigned *)data = 1;
         return true;
      case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
         *(unsigned *)data = 2;
         return true;
      case RETRO_ENVIRONMENT_SET_VARIABLES:
         opts_legacy(data);
         return true;
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS:
         opts_v1(data);
         return true;
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL:
         if (data)
            opts_v1(((const struct retro_core_options_intl *)data)->us);
         return true;
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
         opts_v2(data);
         return true;
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
         if (data)
            opts_v2(((const struct retro_core_options_v2_intl *)data)->us);
         return true;
      case RETRO_ENVIRONMENT_GET_VARIABLE:
      {
         struct retro_variable *v = data;
         if (!v)
            return false;
         v->value = opt_get(v->key);
         return v->value != NULL;
      }
      case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
         *(bool *)data = false;
         return true;
      case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME:
         no_game = data && *(const bool *)data;
         return true;
      case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
      {
         enum retro_pixel_format f = *(const enum retro_pixel_format *)data;
         return f == RETRO_PIXEL_FORMAT_XRGB8888 || f == RETRO_PIXEL_FORMAT_RGB565
             || f == RETRO_PIXEL_FORMAT_0RGB1555;
      }
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
      case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
      case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS:
      case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
      case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
      case RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO:
      case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
      case RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS:
      case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
      case RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE:
      case RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL:
      case RETRO_ENVIRONMENT_SET_MESSAGE:
      case RETRO_ENVIRONMENT_SET_MESSAGE_EXT:
      case RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE:
      case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE:
      case RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK:
         return true;
      default:
         return false;
   }
}

static void RETRO_CALLCONV fe_video(const void *d, unsigned w, unsigned h, size_t p)
{
   (void)d; (void)w; (void)h; (void)p;
}
static void RETRO_CALLCONV fe_sample(int16_t l, int16_t r) { (void)l; (void)r; }
static size_t RETRO_CALLCONV fe_batch(const int16_t *d, size_t n) { (void)d; return n; }
static void RETRO_CALLCONV fe_poll(void) { }
static int16_t RETRO_CALLCONV fe_state(unsigned p, unsigned d, unsigned i, unsigned id)
{
   (void)p; (void)d; (void)i; (void)id;
   return 0;
}

/* un simbolo del core come funzione */
#define SYM(h, type, name) ((type)dlsym((h), (name)))

/* il figlio: un core, poi _exit (niente distruttori: i core restano con
 * thread e file aperti) */
static void child(const char *path)
{
   static char altstack[64 * 1024];
   const int sigs[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, 0 };
   const char *const *s;
   struct retro_system_info info;
   struct sigaction sa;
   stack_t ss;
   unsigned api;
   void *h;
   int i;

   snprintf(core_path, sizeof(core_path), "%s", path);
   ss.ss_sp = altstack;
   ss.ss_size = sizeof(altstack);
   ss.ss_flags = 0;
   sigaltstack(&ss, NULL);
   memset(&sa, 0, sizeof(sa));
   sa.sa_sigaction = on_crash;
   sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESETHAND;
   for (i = 0; sigs[i]; i++)
      sigaction(sigs[i], &sa, NULL);

   tell("F dlopen");
   h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
   if (!h)
   {
      /* "<percorso del core>: undefined symbol: x": il core e' gia' nella
       * riga, resta il perche'. Una libreria che manca ("libx.so.1: cannot
       * open shared object file...") resta col suo nome. */
      const char *e = dlerror();
      size_t n = strlen(path);

      if (e && !strncmp(e, path, n) && !strncmp(e + n, ": ", 2))
         e += n + 2;
      tell("R NO dlopen: %s", e ? e : "?");
      _exit(0);
   }
   for (s = syms; *s; s++)
      if (!dlsym(h, *s))
      {
         tell("R NO simboli: manca %s", *s);
         _exit(0);
      }
   tell("F retro_api_version");
   api = SYM(h, unsigned (*)(void), "retro_api_version")();
   if (api != RETRO_API_VERSION)
   {
      tell("R NO retro_api_version: %u invece di %u", api, RETRO_API_VERSION);
      _exit(0);
   }
   tell("F retro_set_environment");
   SYM(h, void (*)(retro_environment_t), "retro_set_environment")(fe_env);
   tell("F retro_get_system_info");
   memset(&info, 0, sizeof(info));
   SYM(h, void (*)(struct retro_system_info *), "retro_get_system_info")(&info);
   if (!info.library_name || !*info.library_name)
   {
      tell("R NO retro_get_system_info: library_name vuoto");
      _exit(0);
   }
   tell("F retro_init");
   SYM(h, void (*)(void), "retro_init")();
   tell("F callback");
   SYM(h, void (*)(retro_video_refresh_t), "retro_set_video_refresh")(fe_video);
   SYM(h, void (*)(retro_audio_sample_t), "retro_set_audio_sample")(fe_sample);
   SYM(h, void (*)(retro_audio_sample_batch_t), "retro_set_audio_sample_batch")(fe_batch);
   SYM(h, void (*)(retro_input_poll_t), "retro_set_input_poll")(fe_poll);
   SYM(h, void (*)(retro_input_state_t), "retro_set_input_state")(fe_state);
   tell("I \"%s\" %s%s", info.library_name,
        info.library_version && *info.library_version ? info.library_version : "-",
        no_game ? " (senza contenuto)" : "");
   tell("F retro_deinit");
   SYM(h, void (*)(void), "retro_deinit")();
   tell("R ok");
   _exit(0);
}

/* le righe arrivate dal figlio in buf: l'ultima fase, le informazioni, il
 * risultato */
static void parse(char *buf, size_t *have, char *phase, char *info, char *result, size_t sz)
{
   char *p, *nl;
   for (p = buf; (nl = strchr(p, '\n')); p = nl + 1)
   {
      *nl = 0;
      if (p[0] && p[1] == ' ')
      {
         if (p[0] == 'F')
            snprintf(phase, sz, "%s", p + 2);
         else if (p[0] == 'I')
            snprintf(info, sz, "%s", p + 2);
         else if (p[0] == 'R')
            snprintf(result, sz, "%s", p + 2);
      }
   }
   *have = strlen(p);
   memmove(buf, p, *have + 1);
   if (*have >= 8191)
      *have = 0;
}

static int run(const char *path, unsigned timeout, const char *logdir)
{
   char buf[8192], phase[1024] = "avvio", result[1024] = "", info[1024] = "", why[1100];
   int fds[2], st = 0, fd;
   bool timed_out = false, exited = false;
   time_t t0 = time(NULL);
   struct pollfd pfd;
   size_t have = 0;
   ssize_t n;
   pid_t pid;

   if (pipe(fds) < 0)
   {
      perror("pipe");
      return 1;
   }
   pid = fork();
   if (pid < 0)
   {
      perror("fork");
      return 1;
   }
   if (pid == 0)
   {
      close(fds[0]);
      rpipe = fds[1];
      if (logdir)
      {
         char lp[PATH_MAX];
         snprintf(lp, sizeof(lp), "%s/%s.log", logdir, base_name(path));
         fd = open(lp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      }
      else
         fd = open("/dev/null", O_WRONLY);
      if (fd >= 0)
      {
         dup2(fd, 1);
         dup2(fd, 2);
         close(fd);
      }
      fd = open("/dev/null", O_RDONLY);
      if (fd >= 0)
      {
         dup2(fd, 0);
         close(fd);
      }
      /* un gruppo di processi suo: quello che lascia si ferma tutto insieme */
      setpgid(0, 0);
      /* nella cartella delle prove, col percorso intero del core: chi scrive
       * nella cartella corrente (np2kai il suo np2.cfg) non lascia file dove
       * il test e' stato lanciato */
      {
         char abs[PATH_MAX];
         const char *p = path;

         if (path[0] != '/' && realpath(path, abs))
            p = abs;
         if (chdir(sysdir) < 0)
            perror(sysdir);
         /* e la casa: sulla console e' /storage, qui quella delle prove (un
          * core che scrive in $HOME non finisce in quella di chi lancia) */
         setenv("HOME", sysdir, 1);
         unsetenv("XDG_CONFIG_HOME");
         unsetenv("XDG_DATA_HOME");
         unsetenv("XDG_CACHE_HOME");
         child(p);
      }
      _exit(0);
   }
   close(fds[1]);
   /* Si legge finche' il figlio scrive; ma un processo lasciato dal core tiene
    * aperta la pipe anche dopo che il figlio e' uscito: quindi poll a scatti,
    * e appena il figlio e' uscito si vuota la pipe senza aspettare. */
   pfd.fd = fds[0];
   pfd.events = POLLIN;
   for (;;)
   {
      if (poll(&pfd, 1, 100) > 0)
      {
         n = read(fds[0], buf + have, sizeof(buf) - 1 - have);
         if (n == 0)
            break;
         if (n > 0)
         {
            have += (size_t)n;
            buf[have] = 0;
            parse(buf, &have, phase, info, result, sizeof(phase));
            continue;
         }
      }
      if (waitpid(pid, &st, WNOHANG) == pid)
      {
         exited = true;
         fcntl(fds[0], F_SETFL, O_NONBLOCK);
         while ((n = read(fds[0], buf + have, sizeof(buf) - 1 - have)) > 0)
         {
            have += (size_t)n;
            buf[have] = 0;
            parse(buf, &have, phase, info, result, sizeof(phase));
         }
         break;
      }
      if (time(NULL) - t0 >= (time_t)timeout)
      {
         timed_out = true;
         break;
      }
   }
   close(fds[0]);
   kill(-pid, SIGKILL);
   if (!exited)
      while (waitpid(pid, &st, 0) < 0 && errno == EINTR)
         ;

   if (!timed_out && !strcmp(result, "ok"))
   {
      printf("ok      %s %s [%lds]\n", base_name(path), info, (long)(time(NULL) - t0));
      return 0;
   }
   if (timed_out)
      snprintf(why, sizeof(why), "%s: tempo scaduto (%u s)", phase, timeout);
   else if (!strncmp(result, "NO ", 3))
      snprintf(why, sizeof(why), "%s", result + 3);
   else if (WIFSIGNALED(st))
      snprintf(why, sizeof(why), "%s: segnale %d (%s)", phase, WTERMSIG(st), strsignal(WTERMSIG(st)));
   else
      snprintf(why, sizeof(why), "%s: uscito con %d senza finire", phase,
               WIFEXITED(st) ? WEXITSTATUS(st) : -1);
   /* partito, ma non si chiude: un avviso, non un core che non va */
   if (info[0] && !strcmp(phase, "retro_deinit"))
   {
      printf("avviso  %s %s: %s\n", base_name(path), info, why);
      return 0;
   }
   printf("NO      %s %s\n", base_name(path), why);
   return 1;
}

static int rm_one(const char *p, const struct stat *st, int flag, struct FTW *f)
{
   (void)st; (void)f;
   if (flag == FTW_DP)
      rmdir(p);
   else
      unlink(p);
   return 0;
}

static int usage(const char *me)
{
   fprintf(stderr, "uso: %s [-t secondi] [-l cartella] core_libretro.so...\n", me);
   return 2;
}

int main(int argc, char **argv)
{
   const char *logdir = NULL, *tmp = getenv("TMPDIR");
   unsigned timeout = 120;
   int c, bad = 0, i;

   while ((c = getopt(argc, argv, "t:l:")) != -1)
   {
      if (c == 't')
         timeout = (unsigned)strtoul(optarg, NULL, 10);
      else if (c == 'l')
         logdir = optarg;
      else
         return usage(argv[0]);
   }
   if (optind >= argc || !timeout)
      return usage(argv[0]);
   if (logdir && mkdir(logdir, 0755) < 0 && errno != EEXIST)
   {
      perror(logdir);
      return 2;
   }
   snprintf(dir, sizeof(dir), "%s/rf35h-coretest-XXXXXX", tmp && *tmp ? tmp : "/tmp");
   if (!mkdtemp(dir))
   {
      perror("mkdtemp");
      return 2;
   }
   /* le cartelle date ai core (e quella corrente) una sotto, e nessun punto
    * nel nome: RACE senza contenuto prende la cartella dei salvataggi per il
    * gioco, ne toglie l'ultima estensione e aggiunge .ngf. Con
    * rf35h-coretest.XXXXXX scriveva <TMPDIR>/rf35h-coretest.ngf, fuori. */
   snprintf(sysdir, sizeof(sysdir), "%s/libretro", dir);
   if (mkdir(sysdir, 0755) < 0)
   {
      perror(sysdir);
      return 2;
   }
   setvbuf(stdout, NULL, _IOLBF, 0);
   for (i = optind; i < argc; i++)
      bad += run(argv[i], timeout, logdir);
   /* la cartella delle prove, con quello che i core ci hanno scritto (nftw, non
    * system("rm -rf"): sotto qemu senza binfmt un programma aarch64 non parte) */
   nftw(dir, rm_one, 16, FTW_DEPTH | FTW_PHYS);
   fprintf(stderr, "rf35h-coretest: %d core, %d non partono\n", argc - optind, bad);
   return bad ? 1 : 0;
}
