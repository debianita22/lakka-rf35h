#!/usr/bin/env python3
"""Per ogni riga che nomina RF35H nei sorgenti generati, ricostruisce la pila
degli #if attivi e segnala se una condizione che non e' nostra (HAVE_LAKKA) la
racchiude: e' l'errore fatto due volte, con le stringhe e con i setting.
Uso: check-ifdef-nesting.py <albero> file..."""
import sys, re
root = sys.argv[1]; bad = 0
for f in sys.argv[2:]:
    stack = []
    for n, line in enumerate(open(f"{root}/{f}", errors="replace"), 1):
        t = line.strip()
        if t.startswith("#if"):
            # gli include guard (#ifndef FOO_H) non sono condizioni di build
            stack.append("guard" if re.match(r"#ifndef\s+\w*_H_*\b", t) else t)
        elif t.startswith("#elif"): stack[-1:] = [t] if stack else [t]
        elif t.startswith("#else"): stack[-1:] = ["#else of " + stack[-1]] if stack else []
        elif t.startswith("#endif"): stack = stack[:-1]
        elif "RF35H" in line or "rf35h" in line:
            # Lakka definisce HAVE_LAKKA, HAVE_MENU, HAVE_CONFIGFILE, HAVE_NETWORKING:
            # stare sotto quelli e' normale. Tutto il resto e' estraneo.
            OK = ("HAVE_LAKKA)", "HAVE_LAKKA\n", "HAVE_LAKKA", "HAVE_MENU", "HAVE_CONFIGFILE", "HAVE_NETWORKING", "HAVE_WIFI", "RF35H_")
            foreign = [c for c in stack if c != "guard" and ("HAVE_LAKKA_SWITCH" in c or not any(k in c for k in OK))]
            if foreign:
                bad += 1; print(f"  {f}:{n}  sotto {' > '.join(foreign)}  :: {t[:60]}")
print("nessuna occorrenza RF35H sotto un #if estraneo" if not bad else f"{bad} occorrenze sotto #if estranei")
sys.exit(1 if bad else 0)
