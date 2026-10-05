#!/usr/bin/env python3
"""gen-retroarch-rf35h-cores.py <retroarch-src>
Terzo stadio, DOPO gen-retroarch-rf35h-menu.py e gen-retroarch-rf35h-submenus.py:
il sottomenu "Core Updates" in Device Settings, i core aggiornabili uno per uno.

    Device Settings
    +- ...
    +- Core Updates   -> Check for Updates, Update All Cores, Use System Cores,
    |                    poi una voce per core (dinamica: una riga per core in
    |                    /storage/.config/rf35h/cores.status, scritta da rf35h-cores)
    +- System Update

Le tre voci fisse e quelle per core non sono setting: sono entry aggiunte con
menu_entries_append nella displaylist (come la lista delle reti Wi-Fi), con
una label propria (rf35h_core_entry) e il nome del core come path. Il callback
OK legge il path, mette in coda (cores.queue) e avvia rf35h-cores.service; il
sottotitolo di ogni core e' la sua riga di cores.status, riletta al massimo
due volte al secondo. RetroArch non si riavvia: un core in /storage/cores
vale al prossimo caricamento di quel core.
Ogni ancora e' una riga scritta dai due stadi precedenti o dal sorgente di
RetroArch: se non e' unica lo script si ferma.
"""
import sys

if len(sys.argv) != 2:
    sys.exit("uso: gen-retroarch-rf35h-cores.py <retroarch-src>")
SRC = sys.argv[1]

def edit(path, pairs):
    p = f"{SRC}/{path}"
    s = open(p).read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"{path}: ancora trovata {s.count(old)} volte, attesa 1:\n{old[:160]}")
        s = s.replace(old, new)
    open(p, "w").write(s)
    print(f"  {path}: {len(pairs)} modifiche")

# le voci: enum (senza MENU_ENUM_LABEL_), label breve, testo, sottotitolo (en, it)
ENTRIES = [
    ("RF35H_CORES",         "rf35h_cores",         "Core Updates",
     "Update the emulator cores one by one from the cores release on GitHub, without a system update.",
     "Aggiornamenti dei core", "Aggiorna i core degli emulatori uno per uno dalla release dei core su GitHub, senza un aggiornamento di sistema."),
    ("RF35H_CORES_REFRESH", "rf35h_cores_refresh", "Check for Updates",
     "Download the list of available cores and compare it with the installed ones.",
     "Cerca aggiornamenti", "Scarica l'elenco dei core disponibili e lo confronta con quelli installati."),
    ("RF35H_CORES_ALL",     "rf35h_cores_all",     "Update All Cores",
     "Download every core that has a newer version. Each core is used the next time it is loaded.",
     "Aggiorna tutti i core", "Scarica ogni core che ha una versione piu' nuova. Ogni core vale dal suo prossimo caricamento."),
    ("RF35H_CORES_RESET",   "rf35h_cores_reset",   "Use System Cores",
     "Remove every updated core and go back to the cores of the installed system.",
     "Usa i core di sistema", "Toglie ogni core aggiornato e torna ai core del sistema installato."),
    ("RF35H_CORE_ENTRY",    "rf35h_core_entry",    "Core",
     "Select to update this core, or to go back to the system core if it was updated.",
     "Core", "Seleziona per aggiornare questo core, o per tornare a quello di sistema se era aggiornato."),
]

# ---------------------------------------------------------------- msg_hash.h
edit("msg_hash.h", [
    ("   MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST,\n",
     "   MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST,\n"
     "   MENU_ENUM_LABEL_DEFERRED_RF35H_CORES_LIST,\n"),
    ("   MENU_LABEL(RF35H_NTP_SETTINGS),\n",
     "   MENU_LABEL(RF35H_NTP_SETTINGS),\n"
     + "".join(f"   MENU_LABEL({e}),\n" for e, *_ in ENTRIES)),
])

# ----------------------------------------------------------- msg_hash_lbl.h
edit("intl/msg_hash_lbl.h", [
    ('   "deferred_rf35h_ntp_settings_list"\n   )\n',
     '   "deferred_rf35h_ntp_settings_list"\n   )\n'
     'MSG_HASH(\n   MENU_ENUM_LABEL_DEFERRED_RF35H_CORES_LIST,\n   "deferred_rf35h_cores_list"\n   )\n'),
    ('   "rf35h_ntp_settings"\n   )\n',
     '   "rf35h_ntp_settings"\n   )\n'
     + "".join(f'MSG_HASH(\n   MENU_ENUM_LABEL_{e},\n   "{lo}"\n   )\n' for e, lo, *_ in ENTRIES)),
])

# ------------------------------------------------------- msg_hash_us.h / it.h
US_ANCHOR = 'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS,\n   "Network Time"\n   )\n'
edit("intl/msg_hash_us.h", [
    (US_ANCHOR, US_ANCHOR + "".join(
        f'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_{e},\n   "{en}"\n   )\n'
        f'MSG_HASH(\n   MENU_ENUM_SUBLABEL_{e},\n   "{en_sub}"\n   )\n' for e, lo, en, en_sub, it, it_sub in ENTRIES)),
])
IT_ANCHOR = 'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS,\n   "Ora di rete"\n   )\n'
edit("intl/msg_hash_it.h", [
    (IT_ANCHOR, IT_ANCHOR + "".join(
        f'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_{e},\n   "{it}"\n   )\n'
        f'MSG_HASH(\n   MENU_ENUM_SUBLABEL_{e},\n   "{it_sub}"\n   )\n' for e, lo, en, en_sub, it, it_sub in ENTRIES)),
])

# ------------------------------------------------------- menu_displaylist.h
edit("menu/menu_displaylist.h", [
    ("   DISPLAYLIST_RF35H_NTP_SETTINGS_LIST,\n",
     "   DISPLAYLIST_RF35H_NTP_SETTINGS_LIST,\n   DISPLAYLIST_RF35H_CORES_LIST,\n"),
])

# ---------------------------------------------------------------- menu_cbs.h
edit("menu/menu_cbs.h", [
    ("   ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST,\n",
     "   ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST,\n   ACTION_OK_DL_RF35H_CORES_LIST,\n"),
])

# --------------------------------------------------------- cbs/menu_cbs_ok.c
OK_FUNCS = r'''
/* devaOS RF35H: Core Updates. Le voci della lista (menu_displaylist.c) non
 * sono setting: il path e' il nome del core (rf35h_core_entry) o la label
 * della voce fissa. Il lavoro lo fa rf35h-cores.service, dalla coda
 * cores.queue; lo stato per core lo scrive in cores.status, e lo legge il
 * sottotitolo. */
#define RF35H_CORES_QUEUE  "/storage/.config/rf35h/cores.queue"
#define RF35H_CORES_STATUS "/storage/.config/rf35h/cores.status"

static bool rf35h_cores_enqueue(const char *what)
{
   FILE *f = fopen(RF35H_CORES_QUEUE, "a");
   if (!f)
      return false;
   fprintf(f, "%s\n", what);
   fclose(f);
   if (system("systemctl --no-block start rf35h-cores.service >/dev/null 2>&1")) { }
   return true;
}

/* la riga di stato di un core: "<core> <so> <stato...>", in st solo lo stato */
static bool rf35h_core_state(const char *core, char *st, size_t len)
{
   char line[256];
   FILE *f = fopen(RF35H_CORES_STATUS, "r");
   st[0]   = '\0';
   if (!f)
      return false;
   while (fgets(line, sizeof(line), f))
   {
      char *p = strchr(line, ' ');
      size_t n = p ? (size_t)(p - line) : 0;
      if (n && n == strlen(core) && !strncmp(line, core, n))
      {
         char *q = strchr(p + 1, ' ');   /* dopo il .so */
         if (q)
         {
            strlcpy(st, q + 1, len);
            st[strcspn(st, "\r\n")] = '\0';
         }
         break;
      }
   }
   fclose(f);
   return st[0] != '\0';
}

static void rf35h_cores_msg(const char *msg, enum message_queue_category cat)
{
   runloop_msg_queue_push(msg, strlen(msg), 1,
         cat == MESSAGE_QUEUE_CATEGORY_WARNING ? 300 : 180, true, NULL,
         MESSAGE_QUEUE_ICON_DEFAULT, cat);
}

static int action_ok_rf35h_cores_refresh(const char *path,
      const char *label, unsigned type, size_t idx, size_t entry_idx)
{
   (void)path; (void)label; (void)type; (void)idx; (void)entry_idx;
   if (rf35h_unit_active("rf35h-cores.service"))
      rf35h_cores_msg("Core update in progress, see the entries below", MESSAGE_QUEUE_CATEGORY_INFO);
   else if (rf35h_cores_enqueue("refresh"))
      rf35h_cores_msg("Checking the cores release, the entries below update in a moment", MESSAGE_QUEUE_CATEGORY_INFO);
   else
      rf35h_cores_msg("Cannot write /storage/.config/rf35h", MESSAGE_QUEUE_CATEGORY_WARNING);
   return 0;
}

static int action_ok_rf35h_cores_all(const char *path,
      const char *label, unsigned type, size_t idx, size_t entry_idx)
{
   (void)path; (void)label; (void)type; (void)idx; (void)entry_idx;
   if (rf35h_unit_active("rf35h-cores.service"))
      rf35h_cores_msg("Core update in progress, see the entries below", MESSAGE_QUEUE_CATEGORY_INFO);
   else if (rf35h_cores_enqueue("all"))
      rf35h_cores_msg("Updating every core with a newer version, progress below", MESSAGE_QUEUE_CATEGORY_INFO);
   else
      rf35h_cores_msg("Cannot write /storage/.config/rf35h", MESSAGE_QUEUE_CATEGORY_WARNING);
   return 0;
}

static int action_ok_rf35h_cores_reset(const char *path,
      const char *label, unsigned type, size_t idx, size_t entry_idx)
{
   struct menu_state *menu_st = menu_state_get_ptr();
   (void)path; (void)label; (void)type; (void)idx; (void)entry_idx;
   if (rf35h_unit_active("rf35h-cores.service"))
   {
      rf35h_cores_msg("Core update in progress: wait for it to finish", MESSAGE_QUEUE_CATEGORY_WARNING);
      return 0;
   }
   /* veloce (toglie file): in linea, cosi' la lista si ridisegna gia' giusta */
   if (system("/usr/bin/rf35h-cores reset all >/dev/null 2>&1") == 0)
      rf35h_cores_msg("Back to the system cores: they are used the next time each core is loaded", MESSAGE_QUEUE_CATEGORY_INFO);
   else
      rf35h_cores_msg("Could not remove the updated cores (rf35h-cores reset all)", MESSAGE_QUEUE_CATEGORY_WARNING);
   menu_st->flags |= MENU_ST_FLAG_ENTRIES_NEED_REFRESH | MENU_ST_FLAG_PREVENT_POPULATE;
   return 0;
}

/* una voce per core: aggiorna se c'e' una versione nuova, torna al core di
 * sistema se era aggiornato, riprova dopo un errore */
static int action_ok_rf35h_core_entry(const char *path,
      const char *label, unsigned type, size_t idx, size_t entry_idx)
{
   char st[160];
   char cmd[256];
   struct menu_state *menu_st = menu_state_get_ptr();
   (void)label; (void)type; (void)idx; (void)entry_idx;
   if (string_is_empty(path) || strlen(path) > 64 || strspn(path, "abcdefghijklmnopqrstuvwxyz0123456789_") != strlen(path))
      return 0;
   if (!rf35h_core_state(path, st, sizeof(st)))
   {
      rf35h_cores_msg("No status for this core yet: run Check for Updates", MESSAGE_QUEUE_CATEGORY_INFO);
      return 0;
   }
   if (!strncmp(st, "available", 9) || !strncmp(st, "error", 5))
   {
      if (rf35h_unit_active("rf35h-cores.service"))
         rf35h_cores_msg("Core update in progress: this one is queued after it", MESSAGE_QUEUE_CATEGORY_INFO);
      if (rf35h_cores_enqueue(path))
         rf35h_cores_msg("Core update started, progress below the entry", MESSAGE_QUEUE_CATEGORY_INFO);
      else
         rf35h_cores_msg("Cannot write /storage/.config/rf35h", MESSAGE_QUEUE_CATEGORY_WARNING);
   }
   else if (!strncmp(st, "updated", 7))
   {
      if (rf35h_unit_active("rf35h-cores.service"))
      {
         rf35h_cores_msg("Core update in progress: wait for it to finish", MESSAGE_QUEUE_CATEGORY_WARNING);
         return 0;
      }
      snprintf(cmd, sizeof(cmd), "/usr/bin/rf35h-cores reset %s >/dev/null 2>&1", path);
      if (system(cmd) == 0)
         rf35h_cores_msg("Back to the system core, used the next time this core is loaded", MESSAGE_QUEUE_CATEGORY_INFO);
      else
         rf35h_cores_msg("Could not remove the updated core", MESSAGE_QUEUE_CATEGORY_WARNING);
      menu_st->flags |= MENU_ST_FLAG_ENTRIES_NEED_REFRESH | MENU_ST_FLAG_PREVENT_POPULATE;
   }
   else if (!strncmp(st, "downloading", 11))
      rf35h_cores_msg("This core is downloading", MESSAGE_QUEUE_CATEGORY_INFO);
   else if (!strncmp(st, "needs", 5))
      rf35h_cores_msg("This core needs a newer system: use System Update first", MESSAGE_QUEUE_CATEGORY_WARNING);
   else if (!strncmp(st, "custom", 6))
      rf35h_cores_msg("A core you copied yourself is in /storage/cores: it is left alone", MESSAGE_QUEUE_CATEGORY_INFO);
   else
      rf35h_cores_msg("This core is up to date", MESSAGE_QUEUE_CATEGORY_INFO);
   return 0;
}
'''
edit("menu/cbs/menu_cbs_ok.c", [
    ("      case ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST;\n",
     "      case ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST;\n"
     "      case ACTION_OK_DL_RF35H_CORES_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_CORES_LIST;\n"),
    ("      case ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST:\n#endif\n      case ACTION_OK_DL_USER_SETTINGS_LIST:\n",
     "      case ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST:\n      case ACTION_OK_DL_RF35H_CORES_LIST:\n#endif\n      case ACTION_OK_DL_USER_SETTINGS_LIST:\n"),
    ("STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_ntp_settings, ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST)\n",
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_ntp_settings, ACTION_OK_DL_RF35H_NTP_SETTINGS_LIST)\n"
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_cores, ACTION_OK_DL_RF35H_CORES_LIST)\n"),
    # le funzioni dopo action_ok_rf35h_update (usano rf35h_unit_active, definita
    # dal primo stadio li' vicino: prima darebbero "conflicting types")
    ("         MESSAGE_QUEUE_ICON_DEFAULT, cat);\n   return 0;\n}\n#endif\n",
     "         MESSAGE_QUEUE_ICON_DEFAULT, cat);\n   return 0;\n}\n" + OK_FUNCS + "#endif\n"),
    ("         {MENU_ENUM_LABEL_RF35H_NTP_SETTINGS,                       action_ok_rf35h_ntp_settings},\n",
     "         {MENU_ENUM_LABEL_RF35H_NTP_SETTINGS,                       action_ok_rf35h_ntp_settings},\n"
     "         {MENU_ENUM_LABEL_RF35H_CORES,                              action_ok_rf35h_cores},\n"
     "         {MENU_ENUM_LABEL_RF35H_CORES_REFRESH,                      action_ok_rf35h_cores_refresh},\n"
     "         {MENU_ENUM_LABEL_RF35H_CORES_ALL,                          action_ok_rf35h_cores_all},\n"
     "         {MENU_ENUM_LABEL_RF35H_CORES_RESET,                        action_ok_rf35h_cores_reset},\n"
     "         {MENU_ENUM_LABEL_RF35H_CORE_ENTRY,                         action_ok_rf35h_core_entry},\n"),
])

# ------------------------------------------------------ cbs/menu_cbs_title.c
edit("menu/cbs/menu_cbs_title.c", [
    ("DEFAULT_TITLE_MACRO(action_get_rf35h_ntp_settings_list, MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS)\n",
     "DEFAULT_TITLE_MACRO(action_get_rf35h_ntp_settings_list, MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS)\n"
     "DEFAULT_TITLE_MACRO(action_get_rf35h_cores_list, MENU_ENUM_LABEL_VALUE_RF35H_CORES)\n"),
    ("      {MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST, action_get_rf35h_ntp_settings_list},\n",
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST, action_get_rf35h_ntp_settings_list},\n"
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_CORES_LIST, action_get_rf35h_cores_list},\n"),
])

# --------------------------------------------------- cbs/menu_cbs_sublabel.c
SUB_FUNC = r'''
/* devaOS RF35H: il sottotitolo di una voce per core e' la sua riga di
 * cores.status (scritta da rf35h-cores), letta al massimo due volte al
 * secondo per tutta la lista. Un download senza il servizio e' stato
 * interrotto (RetroArch riavviato, console spenta). */
static int action_bind_sublabel_rf35h_core_entry(
      file_list_t *list, unsigned type, unsigned i,
      const char *label, const char *path,
      char *s, size_t len)
{
   static char cache[8192];
   static retro_time_t last_read = 0;
   retro_time_t now = cpu_features_get_time_usec();
   const char *p;
   char st[160];
   (void)list; (void)type; (void)i; (void)label;
   if (!last_read || now - last_read > 500000)
   {
      FILE *f   = fopen("/storage/.config/rf35h/cores.status", "r");
      size_t n  = 0;
      last_read = now;
      cache[0]  = '\0';
      if (f)
      {
         n = fread(cache, 1, sizeof(cache) - 1, f);
         cache[n] = '\0';
         fclose(f);
      }
   }
   st[0] = '\0';
   if (!string_is_empty(path))
   {
      size_t pl = strlen(path);
      for (p = cache; p && *p; p = strchr(p, '\n') ? strchr(p, '\n') + 1 : NULL)
      {
         if (!strncmp(p, path, pl) && p[pl] == ' ')
         {
            const char *q = strchr(p + pl + 1, ' ');
            if (q)
            {
               strlcpy(st, q + 1, sizeof(st));
               st[strcspn(st, "\r\n")] = '\0';
            }
            break;
         }
      }
   }
   if (!strncmp(st, "downloading", 11) && !rf35h_unit_active("rf35h-cores.service"))
      strlcpy(st, "interrupted: select to try again", sizeof(st));
   if (!strncmp(st, "image", 5))
      snprintf(s, len, "System core %s, up to date", st + 6);
   else if (!strncmp(st, "updated", 7))
      snprintf(s, len, "Updated core %s. Select to go back to the system core", st + 8);
   else if (!strncmp(st, "available", 9))
      snprintf(s, len, "Update available: %s. Select to install it", st + 10);
   else if (!strncmp(st, "needs", 5))
      strlcpy(s, "A newer core exists, but it needs a system update first", len);
   else if (!strncmp(st, "custom", 6))
      strlcpy(s, "A core you copied yourself is in /storage/cores", len);
   else if (st[0])
      strlcpy(s, st, len);
   else
      strlcpy(s, "No information yet: Check for Updates", len);
   return 1;
}
'''
edit("menu/cbs/menu_cbs_sublabel.c", [
    ("DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_ntp_settings, MENU_ENUM_SUBLABEL_RF35H_NTP_SETTINGS)\n",
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_ntp_settings, MENU_ENUM_SUBLABEL_RF35H_NTP_SETTINGS)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_cores, MENU_ENUM_SUBLABEL_RF35H_CORES)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_cores_refresh, MENU_ENUM_SUBLABEL_RF35H_CORES_REFRESH)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_cores_all, MENU_ENUM_SUBLABEL_RF35H_CORES_ALL)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_cores_reset, MENU_ENUM_SUBLABEL_RF35H_CORES_RESET)\n"),
    # dopo action_bind_sublabel_rf35h_update (rf35h_unit_active e' definita li')
    ('   snprintf(s, len, "%s\\n%s", msg_hash_to_str(MENU_ENUM_SUBLABEL_RF35H_UPDATE), st);\n   return 1;\n}\n#endif\n',
     '   snprintf(s, len, "%s\\n%s", msg_hash_to_str(MENU_ENUM_SUBLABEL_RF35H_UPDATE), st);\n   return 1;\n}\n' + SUB_FUNC + "#endif\n"),
    ("         case MENU_ENUM_LABEL_RF35H_NTP_SETTINGS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_ntp_settings);\n            break;\n",
     "         case MENU_ENUM_LABEL_RF35H_NTP_SETTINGS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_ntp_settings);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_CORES:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_cores);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_CORES_REFRESH:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_cores_refresh);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_CORES_ALL:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_cores_all);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_CORES_RESET:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_cores_reset);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_CORE_ENTRY:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_core_entry);\n            break;\n"),
])

# ---------------------------------------------- cbs/menu_cbs_deferred_push.c
edit("menu/cbs/menu_cbs_deferred_push.c", [
    ("GENERIC_DEFERRED_PUSH(deferred_push_rf35h_ntp_settings_list, DISPLAYLIST_RF35H_NTP_SETTINGS_LIST)\n",
     "GENERIC_DEFERRED_PUSH(deferred_push_rf35h_ntp_settings_list, DISPLAYLIST_RF35H_NTP_SETTINGS_LIST)\n"
     "GENERIC_DEFERRED_PUSH(deferred_push_rf35h_cores_list, DISPLAYLIST_RF35H_CORES_LIST)\n"),
    ("      {MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST, deferred_push_rf35h_ntp_settings_list},\n",
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_NTP_SETTINGS_LIST, deferred_push_rf35h_ntp_settings_list},\n"
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_CORES_LIST, deferred_push_rf35h_cores_list},\n"),
])

# --------------------------------------------------------- menu_displaylist.c
CORES_CASE = r'''      case DISPLAYLIST_RF35H_CORES_LIST:
         {
            /* devaOS RF35H: tre azioni fisse, poi una voce per core dalle
             * righe di cores.status ("<core> <so> <stato>"): le scrive
             * rf35h-cores (al boot, e a ogni refresh). Senza il file, lo
             * script lo scrive al volo (solo dall'elenco dell'immagine,
             * niente rete). Le voci non sono setting: hanno label propria e
             * il nome del core come path (vedi menu_cbs_ok.c). */
            static const struct { enum msg_hash_enums lbl, val; } fixed[] = {
               {MENU_ENUM_LABEL_RF35H_CORES_REFRESH, MENU_ENUM_LABEL_VALUE_RF35H_CORES_REFRESH},
               {MENU_ENUM_LABEL_RF35H_CORES_ALL,     MENU_ENUM_LABEL_VALUE_RF35H_CORES_ALL},
               {MENU_ENUM_LABEL_RF35H_CORES_RESET,   MENU_ENUM_LABEL_VALUE_RF35H_CORES_RESET},
            };
            char line[256];
            FILE *f;
            size_t k;
            for (k = 0; k < ARRAY_SIZE(fixed); k++)
            {
               if (menu_entries_append(list,
                        msg_hash_to_str(fixed[k].val),
                        msg_hash_to_str(fixed[k].lbl),
                        fixed[k].lbl, MENU_SETTING_ACTION, 0, 0, NULL))
                  count++;
            }
            if (!(f = fopen("/storage/.config/rf35h/cores.status", "r")))
            {
               if (system("/usr/bin/rf35h-cores status >/dev/null 2>&1")) { }
               f = fopen("/storage/.config/rf35h/cores.status", "r");
            }
            if (f)
            {
               while (fgets(line, sizeof(line), f))
               {
                  char *sp = strchr(line, ' ');
                  if (!sp || sp == line)
                     continue;
                  *sp = '\0';
                  if (strspn(line, "abcdefghijklmnopqrstuvwxyz0123456789_") != strlen(line))
                     continue;
                  if (menu_entries_append(list, line,
                           msg_hash_to_str(MENU_ENUM_LABEL_RF35H_CORE_ENTRY),
                           MENU_ENUM_LABEL_RF35H_CORE_ENTRY,
                           MENU_SETTING_ACTION, 0, 0, NULL))
                     count++;
               }
               fclose(f);
            }
         }
         break;
'''
dl_path = f"{SRC}/menu/menu_displaylist.c"
dl = open(dl_path).read()
NTP_CASE = "      case DISPLAYLIST_RF35H_NTP_SETTINGS_LIST:\n         {\n            static const menu_displaylist_build_info_t build_list[] = {\n"
assert dl.count(NTP_CASE) == 1, "case NTP non trovato"
dl = dl.replace(NTP_CASE, CORES_CASE + NTP_CASE)
# nel padre: Core Updates prima di System Update
UPD_ROW = "               {MENU_ENUM_LABEL_RF35H_UPDATE,                                          PARSE_ACTION},\n"
assert dl.count(UPD_ROW) == 1, "riga System Update non trovata"
dl = dl.replace(UPD_ROW, "               {MENU_ENUM_LABEL_RF35H_CORES,                                           PARSE_ACTION},\n" + UPD_ROW)
# la lista generica (flag di push e refresh, "nessuna voce" se vuota)
GEN = "         case DISPLAYLIST_RF35H_NTP_SETTINGS_LIST:\n#endif\n#ifdef HAVE_LAKKA_SWITCH\n"
assert dl.count(GEN) == 1, "lista generica non trovata"
dl = dl.replace(GEN, "         case DISPLAYLIST_RF35H_NTP_SETTINGS_LIST:\n         case DISPLAYLIST_RF35H_CORES_LIST:\n#endif\n#ifdef HAVE_LAKKA_SWITCH\n")
open(dl_path, "w").write(dl)
print("  menu/menu_displaylist.c: case Core Updates, voce nel padre, lista generica")

# ------------------------------------------------------------- menu_setting.c
# la CONFIG_ACTION che apre il sottomenu (PARSE_ACTION nel padre la cerca qui)
edit("menu/menu_setting.c", [
    ("            CONFIG_ACTION(\n                  list, list_info,\n"
     "                  MENU_ENUM_LABEL_RF35H_NTP_SETTINGS,\n"
     "                  MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS,\n"
     "                  &group_info,\n                  &subgroup_info,\n                  parent_group);\n",
     "            CONFIG_ACTION(\n                  list, list_info,\n"
     "                  MENU_ENUM_LABEL_RF35H_NTP_SETTINGS,\n"
     "                  MENU_ENUM_LABEL_VALUE_RF35H_NTP_SETTINGS,\n"
     "                  &group_info,\n                  &subgroup_info,\n                  parent_group);\n"
     "            /* Core Updates: apre la lista dei core (menu_displaylist.c) */\n"
     "            CONFIG_ACTION(\n                  list, list_info,\n"
     "                  MENU_ENUM_LABEL_RF35H_CORES,\n"
     "                  MENU_ENUM_LABEL_VALUE_RF35H_CORES,\n"
     "                  &group_info,\n                  &subgroup_info,\n                  parent_group);\n"),
])

print("core updates: sorgente modificato")
