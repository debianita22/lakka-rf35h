#!/bin/bash
# test-core-patches.sh - prove di cores/pre-patch.sh, il pre_patch
# che apply.sh aggiunge ai core pinnati con patch di Lakka: una patch che si
# applica (come prima), una gia' nel sorgente (saltata), una che non si
# applica piu' con la versione di cores/patches (usata), una che dipende da
# quella prima, un rename (git apply), e i due modi di fallire.
#
#   ./tools/test-core-patches.sh
#
# Senza LibreELEC: PKG_DIR, PKG_BUILD, PKG_NAME e ROOT finti, e set -e come
# negli script di LibreELEC (scripts/unpack chiama pre_patch con pkg_call).
#
# rc si legge dentro eval (le condizioni di ok), PKG_* e ROOT dal pre_patch
# caricato con ".":
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }

# una patch -p1 da due versioni di un file: mkp <nome> <file> <prima> <dopo>
mkp() {
	mkdir -p "${T}/mk/a" "${T}/mk/b"
	printf '%b' "$3" > "${T}/mk/a/$2"; printf '%b' "$4" > "${T}/mk/b/$2"
	( cd "${T}/mk" && diff -u "a/$2" "b/$2" ) > "$1"
	rm -rf "${T}/mk"
}

# il sorgente "nuovo" di un core: la 02 e' gia' entrata upstream, la riga
# della 03 e' cambiata
setup() {
	rm -rf "${T}/pkg" "${T}/build"
	mkdir -p "${T}/pkg/patches-lakka" "${T}/pkg/patches-rf35h" "${T}/build"
	printf 'uno\ndue\ntre\nQUATTRO\ncinque\nSEI nuovo\nsette\n' > "${T}/build/a.txt"
	printf 'da rinominare\n' > "${T}/build/b.txt"
	L="${T}/pkg/patches-lakka"
	mkp "${L}/01-cambia.patch" a.txt 'uno\ndue\ntre\nquattro\ncinque\nsei\nsette\n' 'uno\nDUE\ntre\nquattro\ncinque\nsei\nsette\n'
	# la 01 e la 02 sono scritte sul sorgente vecchio, come quelle di Lakka
	mkp "${L}/02-gia-upstream.patch" a.txt 'uno\nDUE\ntre\nquattro\ncinque\nsei\nsette\n' 'uno\nDUE\ntre\nQUATTRO\ncinque\nsei\nsette\n'
	mkp "${L}/03-vecchia.patch" a.txt 'tre\nQUATTRO\ncinque\nsei\nsette\n' 'tre\nQUATTRO\ncinque\nsei (rf35h)\nsette\n'
	mkp "${T}/pkg/patches-rf35h/03-vecchia.patch" a.txt 'tre\nQUATTRO\ncinque\nSEI nuovo\nsette\n' 'tre\nQUATTRO\ncinque\nSEI nuovo (rf35h)\nsette\n'
	mkp "${L}/04-dopo-la-01.patch" a.txt 'uno\nDUE\ntre\n' 'uno\nDUE bis\ntre\n'
	cat > "${L}/05-rinomina.patch" <<-'EOF'
	diff --git a/b.txt b/c.txt
	similarity index 100%
	rename from b.txt
	rename to c.txt
	EOF
}

# pre_patch come lo chiama scripts/unpack: set -e, dalla radice dell'albero
run() {
	( set -e; cd "${T}"; PKG_DIR="${T}/pkg" PKG_BUILD="${T}/build" PKG_NAME=prova ROOT="${T}"
	  # shellcheck source=/dev/null
	  . "${O}/cores/pre-patch.sh"
	  pre_patch; echo "FINE pre_patch" ) > "${T}/out" 2>&1
}

echo "pre_patch: le patch di Lakka di un core al commit nuovo"
setup; run; rc=$?
ok "tutte a posto: esce 0" '[ "${rc}" = 0 ] && grep -q "^FINE pre_patch" "${T}/out"'
ok "  ...la 01 applicata come prima" 'grep -qx "DUE bis" "${T}/build/a.txt" && grep -q "^rf35h: APPLY PATCH pkg/patches-lakka/01-cambia.patch" "${T}/out"'
ok "  ...la 02, gia' entrata upstream, saltata (QUATTRO una volta sola)" 'grep -q "02-gia-upstream.patch e.* gia. nel sorgente (upstream): saltata" "${T}/out" && [ "$(grep -c QUATTRO "${T}/build/a.txt")" = 1 ]'
ok "  ...la 03 non si applica piu': la versione di cores/patches" 'grep -qx "SEI nuovo (rf35h)" "${T}/build/a.txt" && grep -q "03-vecchia.patch non si applica piu.: la versione di cores/patches/prova/" "${T}/out" && grep -q "APPLY PATCH pkg/patches-rf35h/03-vecchia.patch" "${T}/out"'
ok "  ...la 04, scritta sopra la 01, dopo la 01" 'grep -q "APPLY PATCH pkg/patches-lakka/04-dopo-la-01.patch" "${T}/out"'
ok "  ...il rename con git apply" '[ -f "${T}/build/c.txt" ] && [ ! -e "${T}/build/b.txt" ]'
ok "  ...nell'ordine dei nomi" '[ "$(grep -o "patches-[a-z0-9]*/0[0-9]" "${T}/out" | sed "s|.*/||" | tr "\n" " ")" = "01 02 03 04 05 " ]'

echo "pre_patch: quando fallisce"
setup; rm -f "${T}/pkg/patches-rf35h/03-vecchia.patch"; run; rc=$?
ok "la 03 non si applica, senza versione in cores/patches: errore (set -e)" '[ "${rc}" != 0 ] && ! grep -q "^FINE pre_patch" "${T}/out"'
ok "  ...con FAILED, il nome e le righe di patch che dicono dove" 'grep -q "^rf35h: 03-vecchia.patch FAILED: non si applica e non e. gia. nel sorgente (nessuna versione in cores/patches/prova/)" "${T}/out" && grep -q "^Hunk #1 FAILED" "${T}/out"'
ok "  ...e si ferma li': la 04 e la 05 non le tocca" '! grep -q "04-dopo\|05-rinomina" "${T}/out" && [ -f "${T}/build/b.txt" ]'
setup; mkp "${T}/pkg/patches-rf35h/03-vecchia.patch" a.txt 'tre\nquattro\ncinque\naltro\nsette\n' 'tre\nquattro\ncinque\naltro (rf35h)\nsette\n'; run; rc=$?
ok "nemmeno la versione di cores/patches si applica: errore" '[ "${rc}" != 0 ] && grep -q "^rf35h: 03-vecchia.patch FAILED: non si applica, nemmeno la versione di cores/patches/prova/" "${T}/out"'
setup; printf 'Superata: il codice che correggeva e stato riscritto upstream.\n' > "${T}/pkg/patches-rf35h/03-vecchia.patch"; run; rc=$?
ok "versione di cores/patches solo testo: la patch e' superata, si salta col perche'" '[ "${rc}" = 0 ] && grep -q "^rf35h: 03-vecchia.patch non si applica piu. ed e. superata (cores/patches/prova/): Superata: il codice" "${T}/out" && grep -qx "SEI nuovo" "${T}/build/a.txt"'
setup; rm -f "${T}/pkg/patches-lakka/"*.patch; run; rc=$?
ok "nessuna patch: esce 0 senza fare niente" '[ "${rc}" = 0 ] && [ "$(cat "${T}/out")" = "FINE pre_patch" ]'

echo "pre_patch: una patch su piu' file, entrata upstream solo in parte"
# come daphne-gcc14_buildfix: tre file, uno gia' corretto upstream. Davanti
# l'intestazione di git format-patch (col suo "---" e il diffstat), e in z.sql
# una riga tolta che comincia con "-- ": nel diff e' "--- ...", ma e' dentro
# un hunk e non apre un file nuovo.
setup
printf 'a\nb\nPRESENTE\nd\ne\n' > "${T}/build/x.txt"; printf '1\n2\n3\n' > "${T}/build/y.txt"; printf -- '-- commento\nselect 1;\n' > "${T}/build/z.sql"
rm -f "${T}/pkg/patches-lakka/"*.patch "${T}/pkg/patches-rf35h/"*.patch
M="${T}/pkg/patches-lakka/10-multi.patch"
printf 'From 0123 Mon Sep 17 00:00:00 2001\nSubject: [PATCH] prova\n\n---\n x.txt | 2 +-\n 3 files changed\n\n' > "${M}"
mkp "${T}/p1" x.txt 'a\nb\nc\nd\ne\n' 'a\nb\nPRESENTE\nd\ne\n'
mkp "${T}/p2" y.txt '1\n2\n3\n' '1\nDUE\n3\n'
mkp "${T}/p3" z.sql '-- commento\nselect 1;\n' 'select 1;\n'
cat "${T}/p1" "${T}/p2" "${T}/p3" >> "${M}"
run; rc=$?
ok "file per file: esce 0" '[ "${rc}" = 0 ] && grep -q "^rf35h: 10-multi.patch: file per file (3 file)" "${T}/out"'
ok "  ...x.txt gia' corretto upstream: saltato" 'grep -q "10-multi.patch (x.txt): gia. nel sorgente, saltato" "${T}/out" && [ "$(grep -c PRESENTE "${T}/build/x.txt")" = 1 ]'
ok "  ...y.txt e z.sql applicati (la riga \"-- \" tolta non spezza z.sql)" 'grep -qx DUE "${T}/build/y.txt" && [ "$(cat "${T}/build/z.sql")" = "select 1;" ] && grep -q "APPLY PATCH pkg/patches-lakka/10-multi.patch (z.sql)" "${T}/out"'
printf 'q\n' > "${T}/build/y.txt"; printf 'a\nb\nPRESENTE\nd\ne\n' > "${T}/build/x.txt"; printf -- '-- commento\nselect 1;\n' > "${T}/build/z.sql"
run; rc=$?
ok "file per file, ma un file non va ne' avanti ne' indietro: errore, niente toccato" '[ "${rc}" != 0 ] && grep -q "10-multi.patch FAILED" "${T}/out" && [ "$(cat "${T}/build/y.txt")" = q ] && [ "$(head -1 "${T}/build/z.sql")" = "-- commento" ]'

echo "le righe del fallimento, lette da core_why (ci-build.sh)"
setup; rm -f "${T}/pkg/patches-rf35h/03-vecchia.patch"; run
eval "$(sed -n '/^core_why() {/,/^}/p' "${O}/tools/ci-build.sh")"
ok "core_why mostra il FAILED di pre_patch e l'hunk" 'core_why "${T}/out" | grep -q "^rf35h: 03-vecchia.patch FAILED" && core_why "${T}/out" | grep -q "^Hunk #1 FAILED"'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
