#!/usr/bin/env python3
"""gen-retroarch-rf35h-submenus.py <retroarch-src>

Secondo stadio, da eseguire DOPO gen-retroarch-rf35h-menu.py: trasforma il
menu Device Settings da piatto ad albero.

    Device Settings
    +- Sleep Timer, Screen Brightness, USB-C Port, Audio Output, Compressed RAM
    +- LED Settings      -> Joystick LEDs, Status LEDs, LED Effect Speed
    +- Thumbnail Scraper -> Scrape Thumbnails, Only Missing, Region
    +- Network Time      -> NTP, Time Server
    +- System Update     (ultima voce, un'azione)

Perche' un secondo stadio e non un'estensione del primo: qui ogni ancora e' una
riga che il primo stadio ha appena scritto, quindi e' unica e nota. Nel primo
generatore le stesse stringhe compaiono in 4-5 punti diversi e i tentativi di
inserirvi i sottomenu sono falliti due volte su ancore ambigue.

Scelta di progetto: le impostazioni RESTANO tutte in SETTINGS_LIST_RF35H.
menu_displaylist_parse_settings_enum() le trova per enum ovunque siano, e i
sottomenu sono displaylist che le elencano. Tagliare i blocchi CONFIG_* da una
case e incollarli in un'altra e' l'operazione a piu' alto rischio e non cambia
nulla di cio' che l'utente vede. Le liste native (VIDEO, AUDIO) hanno una
SETTINGS_LIST propria: e' una differenza di raggruppamento interno, non di
comportamento, e la si puo' fare in un terzo passo se servira'.

Come il primo stadio: edit() esige che ogni ancora compaia esattamente una
volta, altrimenti si ferma senza scrivere.
"""
import sys

if len(sys.argv) != 2:
    sys.exit("uso: gen-retroarch-rf35h-submenus.py <retroarch-src>")
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

# I tre sottomenu: enum, nome minuscolo, voci (con tipo di parse), testi.
SUBS = [
    dict(U="LED", low="led",
         entries=[("MENU_ENUM_LABEL_RF35H_JOYLED", "PARSE_ONLY_STRING_OPTIONS"),
                  ("MENU_ENUM_LABEL_RF35H_STATUSLED", "PARSE_ONLY_STRING_OPTIONS"),
                  ("MENU_ENUM_LABEL_RF35H_LEDSPEED", "PARSE_ONLY_STRING_OPTIONS")],
         en="LED Settings",
         en_sub="Colours and effects of the stick rings and the two status LEDs.",
         it="Impostazioni LED",
         it_sub="Colori ed effetti degli anelli degli stick e dei due LED di stato."),
    dict(U="SCRAPER", low="scraper",
         entries=[("MENU_ENUM_LABEL_RF35H_SCRAPE", "PARSE_ACTION"),
                  ("MENU_ENUM_LABEL_RF35H_SCRAPE_MISSING", "PARSE_ONLY_BOOL"),
                  ("MENU_ENUM_LABEL_RF35H_SCRAPE_REGION", "PARSE_ONLY_STRING_OPTIONS")],
         en="Thumbnail Scraper",
         en_sub="Download box art, screenshots and title screens for the games in your playlists.",
         it="Scaricamento immagini",
         it_sub="Scarica copertine, schermate e schermi del titolo per i giochi nelle tue playlist."),
    dict(U="NTP", low="ntp_settings",
         entries=[("MENU_ENUM_LABEL_RF35H_NTP", "PARSE_ONLY_BOOL"),
                  ("MENU_ENUM_LABEL_RF35H_NTP_SERVER", "PARSE_ONLY_STRING_OPTIONS")],
         en="Network Time",
         en_sub="Keep the clock right over the network, and choose which server to ask.",
         it="Ora di rete",
         it_sub="Tiene l'ora giusta via rete, e sceglie a quale server chiederla."),
]
MOVED = {e for sub in SUBS for e, _ in sub["entries"]}

def L(sub):  return f"RF35H_{sub['U']}_SETTINGS"          # RF35H_LED_SETTINGS
def lo(sub): return f"rf35h_{sub['low']}"                  # rf35h_led

# ---------------------------------------------------------------- msg_hash.h
edit("msg_hash.h", [
    ("   MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,\n",
     "   MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,\n"
     + "".join(f"   MENU_ENUM_LABEL_DEFERRED_{L(s)}_LIST,\n" for s in SUBS)),
    ("   MENU_LABEL(RF35H_SETTINGS),\n",
     "   MENU_LABEL(RF35H_SETTINGS),\n"
     + "".join(f"   MENU_LABEL({L(s)}),\n" for s in SUBS)),
])

# ----------------------------------------------------------- msg_hash_lbl.h
# Due stringhe per sottomenu, non una: la label della voce ("rf35h_led_settings")
# E quella della lista differita ("deferred_rf35h_led_settings_list"). Senza la
# seconda, msg_hash_to_str() torna "null" al momento del push, RetroArch non
# riconosce la label come lista di impostazioni e la tratta come percorso di
# directory: il sottomenu si apre e mostra solo "Directory not found". E' il
# bug visto sul device al primo test dei sottomenu.
edit("intl/msg_hash_lbl.h", [
    ('   "rf35h_settings"\n   )\n',
     '   "rf35h_settings"\n   )\n'
     + "".join(f'MSG_HASH(\n   MENU_ENUM_LABEL_{L(s)},\n   "{lo(s)}"\n   )\n' for s in SUBS)),
    ('   "deferred_rf35h_settings_list"\n   )\n',
     '   "deferred_rf35h_settings_list"\n   )\n'
     # la stringa deriva dall'ENUM, non dal nome breve: per NTP il nome breve e'
     # gia' "ntp_settings" e concatenare "_settings_list" raddoppiava la parola.
     + "".join(f'MSG_HASH(\n   MENU_ENUM_LABEL_DEFERRED_{L(s)}_LIST,\n   "deferred_{L(s).lower()}_list"\n   )\n' for s in SUBS)),
])

# ------------------------------------------------------------ msg_hash_us.h
US_ANCHOR = ('MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS,\n   "Device Settings"\n   )\n')
edit("intl/msg_hash_us.h", [
    (US_ANCHOR,
     US_ANCHOR + "".join(
         f'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_{L(s)},\n   "{s["en"]}"\n   )\n'
         f'MSG_HASH(\n   MENU_ENUM_SUBLABEL_{L(s)},\n   "{s["en_sub"]}"\n   )\n' for s in SUBS)),
])

# ------------------------------------------------------------ msg_hash_it.h
# Il primo stadio produce l'italiano copiando l'inglese e sostituendo i testi:
# qui le voci nuove non ci sono ancora, quindi si aggiungono direttamente.
IT_ANCHOR = ('MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS,\n')
it_path = f"{SRC}/intl/msg_hash_it.h"
it = open(it_path).read()
if it.count(IT_ANCHOR) == 1:
    i = it.index(IT_ANCHOR)
    j = it.index("   )\n", i) + len("   )\n")
    it = it[:j] + "".join(
        f'MSG_HASH(\n   MENU_ENUM_LABEL_VALUE_{L(s)},\n   "{s["it"]}"\n   )\n'
        f'MSG_HASH(\n   MENU_ENUM_SUBLABEL_{L(s)},\n   "{s["it_sub"]}"\n   )\n' for s in SUBS) + it[j:]
    open(it_path, "w").write(it)
    print(f"  intl/msg_hash_it.h: {len(SUBS)*2} stringhe")
else:
    print("  intl/msg_hash_it.h: ancora italiana assente, resta l'inglese (fallback di RetroArch)")

# ------------------------------------------------------- menu_displaylist.h
edit("menu/menu_displaylist.h", [
    ("   DISPLAYLIST_RF35H_SETTINGS_LIST,\n",
     "   DISPLAYLIST_RF35H_SETTINGS_LIST,\n"
     + "".join(f"   DISPLAYLIST_{L(s)}_LIST,\n" for s in SUBS)),
])

# ---------------------------------------------------------------- menu_cbs.h
edit("menu/menu_cbs.h", [
    ("   ACTION_OK_DL_RF35H_SETTINGS_LIST,\n",
     "   ACTION_OK_DL_RF35H_SETTINGS_LIST,\n"
     + "".join(f"   ACTION_OK_DL_{L(s)}_LIST,\n" for s in SUBS)),
])

# --------------------------------------------------------- cbs/menu_cbs_ok.c
edit("menu/cbs/menu_cbs_ok.c", [
    ("      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST;\n",
     "      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST;\n"
     + "".join(f"      case ACTION_OK_DL_{L(s)}_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_{L(s)}_LIST;\n" for s in SUBS)),
    ("#ifdef HAVE_LAKKA\n      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n#endif\n",
     "#ifdef HAVE_LAKKA\n      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n"
     + "".join(f"      case ACTION_OK_DL_{L(s)}_LIST:\n" for s in SUBS) + "#endif\n"),
    ("STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_settings, ACTION_OK_DL_RF35H_SETTINGS_LIST)\n",
     "STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_settings, ACTION_OK_DL_RF35H_SETTINGS_LIST)\n"
     + "".join(f"STATIC_DEFAULT_ACTION_OK_FUNC(action_ok_{lo(s)}, ACTION_OK_DL_{L(s)}_LIST)\n" for s in SUBS)),
    ("         {MENU_ENUM_LABEL_RF35H_SETTINGS,                      action_ok_rf35h_settings},\n",
     "         {MENU_ENUM_LABEL_RF35H_SETTINGS,                      action_ok_rf35h_settings},\n"
     + "".join(f"         {{MENU_ENUM_LABEL_{L(s)},{' ' * max(1, 41 - len(L(s)))}action_ok_{lo(s)}}},\n" for s in SUBS)),
])

# ------------------------------------------------------ cbs/menu_cbs_title.c
edit("menu/cbs/menu_cbs_title.c", [
    ("DEFAULT_TITLE_MACRO(action_get_rf35h_settings_list,             MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS)\n",
     "DEFAULT_TITLE_MACRO(action_get_rf35h_settings_list,             MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS)\n"
     + "".join(f"DEFAULT_TITLE_MACRO(action_get_{lo(s)}_list, MENU_ENUM_LABEL_VALUE_{L(s)})\n" for s in SUBS)),
    ("      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,                  action_get_rf35h_settings_list},\n",
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,                  action_get_rf35h_settings_list},\n"
     + "".join(f"      {{MENU_ENUM_LABEL_DEFERRED_{L(s)}_LIST, action_get_{lo(s)}_list}},\n" for s in SUBS)),
])

# --------------------------------------------------- cbs/menu_cbs_sublabel.c
edit("menu/cbs/menu_cbs_sublabel.c", [
    ("DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_settings,                MENU_ENUM_SUBLABEL_RF35H_SETTINGS)\n",
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_settings,                MENU_ENUM_SUBLABEL_RF35H_SETTINGS)\n"
     + "".join(f"DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_{lo(s)}, MENU_ENUM_SUBLABEL_{L(s)})\n" for s in SUBS)),
    ("         case MENU_ENUM_LABEL_RF35H_SETTINGS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_settings);\n            break;\n",
     "         case MENU_ENUM_LABEL_RF35H_SETTINGS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_settings);\n            break;\n"
     + "".join(f"         case MENU_ENUM_LABEL_{L(s)}:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_{lo(s)});\n            break;\n" for s in SUBS)),
])

# ---------------------------------------------- cbs/menu_cbs_deferred_push.c
edit("menu/cbs/menu_cbs_deferred_push.c", [
    ("GENERIC_DEFERRED_PUSH(deferred_push_rf35h_settings_list,            DISPLAYLIST_RF35H_SETTINGS_LIST)\n",
     "GENERIC_DEFERRED_PUSH(deferred_push_rf35h_settings_list,            DISPLAYLIST_RF35H_SETTINGS_LIST)\n"
     + "".join(f"GENERIC_DEFERRED_PUSH(deferred_push_{lo(s)}_list, DISPLAYLIST_{L(s)}_LIST)\n" for s in SUBS)),
    ("      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST, deferred_push_rf35h_settings_list},\n",
     "      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST, deferred_push_rf35h_settings_list},\n"
     + "".join(f"      {{MENU_ENUM_LABEL_DEFERRED_{L(s)}_LIST, deferred_push_{lo(s)}_list}},\n" for s in SUBS)),
])

# --------------------------------------------------------- menu_displaylist.c
def child_case(sub):
    rows = "".join(f"               {{{e},{' ' * max(1, 72 - len(e))}{t}}},\n" for e, t in sub["entries"])
    return (f"      case DISPLAYLIST_{L(sub)}_LIST:\n"
            "         {\n"
            "            static const menu_displaylist_build_info_t build_list[] = {\n"
            f"{rows}"
            "            };\n\n"
            "            rf35h_sync_settings(settings);\n\n"
            "            for (i = 0; i < ARRAY_SIZE(build_list); i++)\n"
            "            {\n"
            "               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(list,\n"
            "                        build_list[i].enum_idx,  build_list[i].parse_type,\n"
            "                        false) == 0)\n"
            "                  count++;\n"
            "            }\n"
            "         }\n"
            "         break;\n")

dl_path = f"{SRC}/menu/menu_displaylist.c"
dl = open(dl_path).read()
# 1) i tre case figli, prima del padre
PARENT = "      case DISPLAYLIST_RF35H_SETTINGS_LIST:\n         {\n            static const menu_displaylist_build_info_t build_list[] = {\n"
assert dl.count(PARENT) == 1, "case padre non trovato"
dl = dl.replace(PARENT, "".join(child_case(s) for s in SUBS) + PARENT)
# 2) nel padre: via le voci spostate, dentro le tre azioni che aprono i figli
i = dl.index(PARENT) + len(PARENT)
j = dl.index("            };\n", i)
rows = dl[i:j].split("\n")
kept = [r for r in rows if r.strip() and not any(e + "," in r for e in MOVED)]
removed = len([r for r in rows if r.strip()]) - len(kept)
assert removed == len(MOVED), f"spostate {removed} voci, attese {len(MOVED)}"
# le azioni vanno come PARSE_ACTION, e prendono la posizione delle voci uscite:
# LED dopo la luminosita', poi porte/audio/zram gia' presenti, poi scraper e NTP
actions = {s["U"]: f"               {{MENU_ENUM_LABEL_{L(s)},{' ' * max(1, 72 - len('MENU_ENUM_LABEL_' + L(s)))}PARSE_ACTION}}," for s in SUBS}
out = []
last = []   # System Update resta l'ultima voce, dopo i sottomenu
for r in kept:
    if "MENU_ENUM_LABEL_RF35H_UPDATE," in r:
        last.append(r)
        continue
    out.append(r)
    if "MENU_ENUM_LABEL_RF35H_BRIGHTNESS," in r:
        out.append(actions["LED"])
out.append(actions["SCRAPER"])
out.append(actions["NTP"])
out += last
dl = dl[:i] + "\n".join(out) + "\n" + dl[j:]
# 3) la lista generica che manda le displaylist al parser
GEN = "#ifdef HAVE_LAKKA\n         case DISPLAYLIST_RF35H_SETTINGS_LIST:\n#endif\n"
assert dl.count(GEN) == 1, "lista generica non trovata"
dl = dl.replace(GEN, "#ifdef HAVE_LAKKA\n         case DISPLAYLIST_RF35H_SETTINGS_LIST:\n"
                + "".join(f"         case DISPLAYLIST_{L(s)}_LIST:\n" for s in SUBS) + "#endif\n")
open(dl_path, "w").write(dl)
print(f"  menu/menu_displaylist.c: 3 case figli, {removed} voci spostate, 3 azioni nel padre")

# ------------------------------------------------------------- menu_setting.c
# Le tre CONFIG_ACTION che aprono i figli, dentro SETTINGS_LIST_RF35H.
# Ancora: la CONFIG_ACTION dello scraper, unica e nostra.
ms_path = f"{SRC}/menu/menu_setting.c"
ms = open(ms_path).read()
SCRAPE_ACT = ("            CONFIG_ACTION(\n                  list, list_info,\n"
              "                  MENU_ENUM_LABEL_RF35H_SCRAPE,\n"
              "                  MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE,\n")
assert ms.count(SCRAPE_ACT) == 1, "CONFIG_ACTION dello scraper non trovata"
new_actions = "".join(
    "            /* apre il sottomenu */\n"
    "            CONFIG_ACTION(\n                  list, list_info,\n"
    f"                  MENU_ENUM_LABEL_{L(s)},\n"
    f"                  MENU_ENUM_LABEL_VALUE_{L(s)},\n"
    "                  &group_info,\n                  &subgroup_info,\n                  parent_group);\n"
    for s in SUBS)
ms = ms.replace(SCRAPE_ACT, new_actions + SCRAPE_ACT)
open(ms_path, "w").write(ms)
print("  menu/menu_setting.c: 3 CONFIG_ACTION")

print("sottomenu: sorgente modificato")
