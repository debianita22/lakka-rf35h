#!/bin/bash
# test-ci-build.sh - prove di tools/ci-build.sh senza una build e senza GitHub:
# collect su un'immagine finta (SYSTEM squashfs vero dentro un .tar vero).
#
#   ./tools/test-ci-build.sh
#
# Nasce da un controllo che non era mai scattato: "unsquashfs -l | grep -q re3"
# sotto pipefail dava re3 assente proprio quando c'era. Le parti col SYSTEM
# richiedono mksquashfs e unsquashfs (squashfs-tools).
#
# rc si legge dentro eval (le condizioni di ok):
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
CB="${O}/tools/ci-build.sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0; skip=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
# fuori dalle actions: niente annotazioni, output e riassunti
unset GITHUB_ACTIONS GITHUB_OUTPUT GITHUB_STEP_SUMMARY GITHUB_ENV

# Un .so finto ma ben fatto: intestazione ELF64 little-endian aarch64 ET_DYN,
# <n> byte di contenuto, poi la tabella delle sezioni (2 voci da 64 byte), come
# la lascia un linker che ha finito.
le8() { local h i; h="$(printf '%016x' "$1")"; for i in 14 12 10 8 6 4 2 0; do printf '\\x%s' "${h:${i}:2}"; done; }
mkelf() {
	local f="$1" n="${2:-1000}"
	{
		printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00'   # e_ident
		printf '\x03\x00\xb7\x00\x01\x00\x00\x00'                          # ET_DYN, EM_AARCH64, versione
		printf '\x00\x00\x00\x00\x00\x00\x00\x00'                          # e_entry
		printf '\x00\x00\x00\x00\x00\x00\x00\x00'                          # e_phoff
		printf '%b' "$(le8 $((64 + n)))"                                    # e_shoff
		printf '\x00\x00\x00\x00\x40\x00\x38\x00\x00\x00\x40\x00\x02\x00\x01\x00'
		head -c "${n}" /dev/zero
		head -c 128 /dev/zero
	} > "${f}"
}

# Un'immagine finta come la lascia make image in target/: <nome>.img.gz e
# <nome>.tar con <nome>/target/SYSTEM. $1: cartella radice del SYSTEM.
NAME="Lakka-RK3326.aarch64-Next-v9.9.9-rf35h"
mkimg() {
	local root="$1" out="$2" st="${T}/stage"
	rm -rf "${st}"; mkdir -p "${st}/${NAME}/target" "${out}"
	mksquashfs "${root}" "${st}/${NAME}/target/SYSTEM" -noappend -quiet -no-progress > /dev/null
	echo kernel > "${st}/${NAME}/target/KERNEL"
	tar -C "${st}" -cf "${out}/${NAME}.tar" "${NAME}"
	echo img | gzip > "${out}/${NAME}.img.gz"
}
# Un SYSTEM con i core <nomi> (ELF buoni) e i loro .info, piu' abbastanza file
# perche' l'elenco superi di molto il buffer di una pipe (64 KB)
mkroot() {
	local r="$1" c i; shift
	rm -rf "${r}"; mkdir -p "${r}/usr/lib/libretro" "${r}/usr/share/molti" "${r}/usr/bin"
	for c in "$@"; do
		mkelf "${r}/usr/lib/libretro/${c}_libretro.so"
		echo "display_name = \"${c}\"" > "${r}/usr/lib/libretro/${c}_libretro.info"
	done
	for i in $(seq 1 4000); do : > "${r}/usr/share/molti/un-file-con-un-nome-abbastanza-lungo-${i}.dat"; done
}

# collect in una cartella di lavoro finta: W/lakka-rf35h-build/target
collect() {
	local w="${T}/w"
	rm -rf "${w}"; mkdir -p "${w}/lakka-rf35h-build"
	mkimg "$1" "${w}/lakka-rf35h-build/target"
	if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "${w}/lakka-rf35h-build/build-rf35h-20261004-120000-core-saltati.txt"; fi
	W="${w}" RF35H_VERSION=v9.9.9 bash "${CB}" collect > "${T}/collect.out" 2>&1
}

if command -v mksquashfs >/dev/null 2>&1 && command -v unsquashfs >/dev/null 2>&1; then
	echo "collect: il SYSTEM"
	R="${T}/root"
	mkroot "${R}" gambatte mednafen_pce_fast mgba
	collect "${R}"; rc=$?
	ok "immagine buona: collect esce 0" '[ "${rc}" = 0 ]'
	ok "  ...cores.txt dal SYSTEM" '[ "$(tr "\n" " " < "${T}/w/dist/cores.txt")" = "gambatte mednafen_pce_fast mgba " ]'
	ok "  ...update.txt, SHA256SUMS, dropped.txt" '[ -s "${T}/w/dist/update.txt" ] && ( cd "${T}/w/dist" && sha256sum -c --quiet SHA256SUMS ) && [ -f "${T}/w/dist/dropped.txt" ]'

	mkelf "${R}/usr/lib/libretro/re3_libretro.so"
	collect "${R}"; rc=$?
	ok "re3_libretro.so nel SYSTEM: collect fallisce e lo dice" '[ "${rc}" != 0 ] && grep -q "re3 nel SYSTEM" "${T}/collect.out" && [ ! -d "${T}/w/dist" ]'
	# il controllo di prima sullo stesso SYSTEM, per confronto (solo stampato:
	# dipende da quando unsquashfs prende il SIGPIPE)
	old="$(bash -c 'set -euo pipefail; if unsquashfs -l "$1" | grep -qiE "re3_libretro|/re3([/.]|$)"; then echo trovato; else echo perso; fi' _ "${T}/w/check/SYSTEM" 2>/dev/null)"
	echo "        (il controllo vecchio, unsquashfs -l | grep -q, sullo stesso SYSTEM: re3 ${old:-?})"
	rm -f "${R}/usr/lib/libretro/re3_libretro.so"
	mkdir -p "${R}/usr/share/re3"; echo x > "${R}/usr/share/re3/gta3.ini"
	collect "${R}"; rc=$?
	ok "una cartella re3/: collect fallisce" '[ "${rc}" != 0 ] && grep -q "re3 nel SYSTEM" "${T}/collect.out"'
	rm -r "${R}/usr/share/re3"

	: > "${R}/usr/lib/libretro/mgba_libretro.so"
	collect "${R}"; rc=$?
	ok "un core di 0 byte: collect fallisce e lo nomina" '[ "${rc}" != 0 ] && grep -q "core rotti.*mgba_libretro.so (0 byte)" "${T}/collect.out"'
	mkelf "${R}/usr/lib/libretro/mgba_libretro.so" 5000
	head -c 3000 "${R}/usr/lib/libretro/mgba_libretro.so" > "${T}/half"; cp "${T}/half" "${R}/usr/lib/libretro/mgba_libretro.so"
	collect "${R}"; rc=$?
	ok "un core troncato (ELF senza la tabella delle sezioni): fallisce" '[ "${rc}" != 0 ] && grep -q "mgba_libretro.so (3000 byte" "${T}/collect.out"'
	echo "non sono un ELF" > "${R}/usr/lib/libretro/mgba_libretro.so"
	collect "${R}"; rc=$?
	ok "un core che non e' un ELF: fallisce" '[ "${rc}" != 0 ] && grep -q "core rotti.*mgba_libretro.so" "${T}/collect.out"'
	cp /bin/sh "${R}/usr/lib/libretro/mgba_libretro.so"
	if [ "$(uname -m)" != aarch64 ]; then
		collect "${R}"; rc=$?
		ok "un ELF di un'altra architettura: fallisce" '[ "${rc}" != 0 ] && grep -q "core rotti.*mgba_libretro.so" "${T}/collect.out"'
	fi
	mkelf "${R}/usr/lib/libretro/mgba_libretro.so"
	: > "${R}/usr/lib/libretro/mgba_libretro.info"
	collect "${R}"; rc=$?
	ok "un .info vuoto: fallisce" '[ "${rc}" != 0 ] && grep -q "mgba_libretro.info (0 byte)" "${T}/collect.out"'
	echo 'display_name = "mGBA"' > "${R}/usr/lib/libretro/mgba_libretro.info"
	collect "${R}"; rc=$?
	ok "di nuovo tutto a posto: esce 0" '[ "${rc}" = 0 ]'
else
	skip=$((skip + 1)); echo "  (salto collect: serve squashfs-tools)"
fi

if [ "${skip}" = 0 ]; then echo "--- ${pass} ok, ${fail} falliti"; else echo "--- ${pass} ok, ${fail} falliti, ${skip} parti saltate"; fi
[ "${fail}" = 0 ]
