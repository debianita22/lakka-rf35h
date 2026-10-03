#!/usr/bin/env python3
"""check-menu-labels.py <retroarch-src> <gcc-flags-file>

Ogni enum MENU_ENUM_LABEL_*RF35H* deve avere la sua stringa in
intl/msg_hash_lbl.h - compresi quelli DEFERRED_*_LIST. Senza, msg_hash_to_str()
torna "null" al momento del push e RetroArch, che aggancia il deferred push
per STRINGA (menu_cbs_deferred_push.c: `if (!string_is_equal(label, "null"))`),
tratta la label come percorso di directory: il sottomenu si apre e mostra solo
"Directory not found". E' successo sul device con i primi sottomenu.

Il controllo guarda il PREPROCESSATO di intl/msg_hash_us.c, che e' dove
msg_hash_lbl.h viene incluso dentro lo switch: cercare la stringa nel file
sbagliato (msg_hash.c) dava falsi positivi anche sul padre funzionante.

Raccoglie gli enum sia scritti per esteso sia generati dalla macro
MENU_LABEL(X) -> MENU_ENUM_LABEL_X.
"""
import re, subprocess, sys

if len(sys.argv) != 3:
    sys.exit("uso: check-menu-labels.py <retroarch-src> <gcc-flags-file>")
src, flagsf = sys.argv[1], sys.argv[2]
flags = open(flagsf).read().split()
# Le etichette RF35H in msg_hash_lbl.h stanno dentro #ifdef HAVE_LAKKA, che la
# build reale di Lakka definisce (HAVE_LAKKA=1 nel package.mk di RetroArch).
# Senza, il preprocessore scarta il blocco e il controllo segnala "23 enum senza
# stringa, menu vuoti": un falso allarme che ha quasi fatto "correggere" un
# menu funzionante. Lo si definisce qui, cosi' non dipende da chi scrive i flag.
if not any(f.startswith("-DHAVE_LAKKA") for f in flags):
    print("  (HAVE_LAKKA assente dai flag: aggiunto, come nella build di Lakka)")
    flags.append("-DHAVE_LAKKA=1")

h = open(f"{src}/msg_hash.h").read()
enums = set(re.findall(r"\bMENU_ENUM_LABEL_[A-Z0-9_]*RF35H[A-Z0-9_]*", h))
enums |= {"MENU_ENUM_LABEL_" + m for m in re.findall(r"\bMENU_LABEL\((RF35H_[A-Z0-9_]+)\)", h)}
enums = {e for e in enums if "_VALUE_" not in e and "SUBLABEL" not in e}

pre = subprocess.run(["gcc", "-E"] + flags + [f"{src}/intl/msg_hash_us.c"],
                     capture_output=True, text=True, cwd=src).stdout
missing = sorted(e for e in enums if f"case {e}:" not in pre)
for e in missing:
    print(f"  SENZA STRINGA LABEL: {e}")
if missing:
    sys.exit(f"{len(missing)} enum RF35H senza stringa in msg_hash_lbl.h: i loro menu si aprirebbero vuoti")
print(f"  tutti i {len(enums)} enum RF35H hanno la stringa label")
