#!/bin/bash
# test-ci-build.sh - prove di tools/ci-build.sh senza una build e senza GitHub:
# collect e check-dist su immagini finte (SYSTEM squashfs vero dentro un .tar
# vero), pack con pacchetti interrotti, le note della release.
#
#   ./tools/test-ci-build.sh
#
# Nasce da un controllo che non era mai scattato: "unsquashfs -l | grep -q re3"
# sotto pipefail dava re3 assente proprio quando c'era. Le parti col SYSTEM
# richiedono mksquashfs e unsquashfs (squashfs-tools).
#
# ci-build.sh gira da una copia in un repository finto, con il CORES_DEFAULT
# della v1.0.0: le prove non cambiano se cambia il set di core. I core della
# v1.0.0 (V100_CORES) sono quelli delle sue note, cioe' del suo SYSTEM.
#
# rc si legge dentro eval (le condizioni di ok):
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
V100_DEFAULT="gambatte sameboy tgbdual fceumm nestopia genesis_plus_gx picodrive gearsystem snes9x2010 snes9x snes9x2005 mgba gpsp beetle_pce_fast beetle_pce fbneo fbalpha2012 mame2010 mame2015 mupen64plus_next parallel_n64 beetle_ngp race stella2014 stella melonds melondsds cap32 crocods flycast"
V100_CORES="cap32 crocods deva_adventures fbalpha2012 fbneo fceumm flycast gambatte gearsystem genesis_plus_gx gpsp gtasa ikemen mame2010 mame2015 mednafen_ngp mednafen_pce mednafen_pce_fast melonds melondsds mgba mupen64plus_next nestopia openxeenng parallel_n64 picodrive race sameboy snes9x snes9x2005 snes9x2010 stella stella2014 tgbdual"
# pacchetto:core come li installano i package.mk di Lakka (cp ..._libretro.so
# ${INSTALL}/usr/lib/libretro) e i nostri; core_info e retroarch nessun .so
v100_pkgs() {
	local p
	for p in ${V100_DEFAULT}; do
		case "${p}" in
			beetle_pce_fast) echo "${p}:mednafen_pce_fast" ;;
			beetle_pce)      echo "${p}:mednafen_pce" ;;
			beetle_ngp)      echo "${p}:mednafen_ngp" ;;
			*)               echo "${p}:${p}" ;;
		esac
	done
	echo "ikemen-go:ikemen gtasa:gtasa openxeenng:openxeenng deva_adventures:deva_adventures core_info: retroarch:"
}
REPO="${T}/repo"; mkdir -p "${REPO}/tools"
cp "${O}/tools/ci-build.sh" "${O}/tools/ci-release-notes.sh" "${REPO}/tools/"
printf 'LAKKA_COMMIT="e2cf2e5cc3bdbb274aac5e3b6849549f6995dca3"\nCORES_DEFAULT="%s"\n' "${V100_DEFAULT}" > "${REPO}/build-lakka-rf35h.sh"
CB="${REPO}/tools/ci-build.sh"
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

# collect in una cartella di lavoro finta: W/lakka-rf35h-build con target/,
# install_pkg/ (PKGS: "pacchetto:core ...", core vuoto = nessun .so) e il log
# della build. $1: radice del SYSTEM; $2: il resoconto di --keep-going.
collect() {
	local w="${T}/w" ip d log
	rm -rf "${w}"; mkdir -p "${w}/lakka-rf35h-build"
	mkimg "$1" "${w}/lakka-rf35h-build/target"
	for ip in ${PKGS:-}; do
		d="${w}/lakka-rf35h-build/build.Lakka-RK3326.aarch64/install_pkg/${ip%%:*}-1.0"
		mkdir -p "${d}/usr/lib/libretro"
		printf 'INFO_PKG_NAME="%s"\n' "${ip%%:*}" > "${d}/.libreelec-package"
		[ -z "${ip#*:}" ] || mkelf "${d}/usr/lib/libretro/${ip#*:}_libretro.so" 10
	done
	log="${w}/lakka-rf35h-build/build-rf35h-20261004-120000.log"; echo log > "${log}"
	if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "${log%.log}-core-saltati.txt"; fi
	W="${w}" RF35H_VERSION=v9.9.9 bash "${CB}" collect > "${T}/collect.out" 2>&1
}
# check-dist sui file di collect (quelli che il job release scarica)
checkdist() { bash "${CB}" check-dist "${T}/w/dist" > "${T}/check.out" 2>&1; }

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

	echo "core e giochi della build completa (i core veri della v1.0.0)"
	# shellcheck disable=SC2086  # elenchi di parole
	mkroot "${R}" ${V100_CORES}
	PKGS="$(v100_pkgs)"
	collect "${R}"; rc=$?
	ok "v1.0.0: collect esce 0, core-packages.txt dalla build" '[ "${rc}" = 0 ] && grep -qx "beetle_pce_fast mednafen_pce_fast" "${T}/w/dist/core-packages.txt" && grep -qx "ikemen-go ikemen" "${T}/w/dist/core-packages.txt"'
	ok "  ...34 core, niente manca, nessun avviso" '[ "$(wc -l < "${T}/w/dist/cores.txt")" = 34 ] && [ ! -s "${T}/w/dist/missing.txt" ] && ! grep -q incompleta "${T}/collect.out"'
	checkdist; rc=$?
	ok "v1.0.0: check-dist esce 0 (30 core di CORES_DEFAULT e 4 giochi)" '[ "${rc}" = 0 ] && grep -q "ok: i 30 core di CORES_DEFAULT, giochi: ikemen gtasa openxeenng deva_adventures" "${T}/check.out"'

	# beetle_pce_fast non compila: --keep-going lo lascia fuori e lo scrive
	rm "${R}/usr/lib/libretro/mednafen_pce_fast_libretro.so"
	PKGS="$(v100_pkgs | sed 's/beetle_pce_fast:mednafen_pce_fast//')"
	collect "${R}" "  beetle_pce_fast    log: build-rf35h-20261004-120000-beetle_pce_fast-fallito.log"; rc=$?
	ok "un core lasciato fuori: collect esce 0 ma avvisa" '[ "${rc}" = 0 ] && grep -qx "beetle_pce_fast" "${T}/w/dist/missing.txt" && [ -s "${T}/w/dist/dropped.txt" ]'
	checkdist; rc=$?
	ok "  ...check-dist lo ferma e dice cosa manca" '[ "${rc}" != 0 ] && grep -q "release incompleta: mancano: beetle_pce_fast; lasciati fuori dalla build: beetle_pce_fast" "${T}/check.out"'
	rc="$(RF35H_ALLOW_INCOMPLETE=true bash "${CB}" check-dist "${T}/w/dist" > "${T}/check.out" 2>&1; echo $?)"
	ok "  ...con allow_incomplete passa" '[ "${rc}" = 0 ]'
	DIST="${T}/w/dist"; GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 bash "${REPO}/tools/ci-release-notes.sh" "${DIST}" > "${T}/notes.md" 2>/dev/null
	ok "  ...e le note lo dicono" 'grep -q "^- beetle_pce_fast$" "${T}/notes.md" && grep -q "^Missing compared with a complete build: beetle_pce_fast\.$" "${T}/notes.md"'

	# installato dalla build ma non nel SYSTEM (e nessun resoconto)
	mkelf "${R}/usr/lib/libretro/mednafen_pce_fast_libretro.so"; rm "${R}/usr/lib/libretro/mgba_libretro.so"
	PKGS="$(v100_pkgs)"
	collect "${R}"; checkdist; rc=$?
	ok "un .so installato che manca nel SYSTEM: check-dist lo ferma" '[ "${rc}" != 0 ] && grep -qx "mgba (mgba_libretro.so)" "${T}/w/dist/missing.txt" && [ ! -s "${T}/w/dist/dropped.txt" ]'
	# un gioco mancante
	mkelf "${R}/usr/lib/libretro/mgba_libretro.so"; rm "${R}/usr/lib/libretro/ikemen_libretro.so"
	PKGS="$(v100_pkgs | sed 's/ikemen-go:ikemen//')"
	collect "${R}"; checkdist; rc=$?
	ok "IKEMEN GO mancante: check-dist lo ferma" '[ "${rc}" != 0 ] && grep -qx "ikemen" "${T}/w/dist/missing.txt"'
	mkelf "${R}/usr/lib/libretro/ikemen_libretro.so"
	PKGS="$(v100_pkgs)"
	# un resoconto vecchio (tentativo fallito prima) non conta; quello dell'ultima build si'
	collect "${R}"; echo "  mgba    log: x" > "${T}/w/lakka-rf35h-build/build-rf35h-20261004-110000-core-saltati.txt"
	touch -d '2026-10-04 11:00' "${T}/w/lakka-rf35h-build/build-rf35h-20261004-110000-core-saltati.txt"
	echo log > "${T}/w/lakka-rf35h-build/build-rf35h-20261004-110000.log"; touch -d '2026-10-04 11:00' "${T}/w/lakka-rf35h-build/build-rf35h-20261004-110000.log"
	rm -rf "${T}/w/dist"; mkimg "${R}" "${T}/w/lakka-rf35h-build/target"
	W="${T}/w" RF35H_VERSION=v9.9.9 bash "${CB}" collect > "${T}/collect.out" 2>&1; rc=$?
	ok "resoconto di un tentativo precedente: dropped.txt vuoto" '[ "${rc}" = 0 ] && [ ! -s "${T}/w/dist/dropped.txt" ]'
	collect "${R}" "  mgba    log: x"; checkdist; rc=$?
	ok "tutti i core ma un resoconto dell'ultima build: check-dist lo ferma" '[ "${rc}" != 0 ] && [ ! -s "${T}/w/dist/missing.txt" ] && grep -q "lasciati fuori dalla build: mgba" "${T}/check.out"'

	# re3 nei file scaricati (un artifact diverso da quello che collect ha visto)
	collect "${R}"
	mkelf "${R}/usr/lib/libretro/re3_libretro.so"; mkimg "${R}" "${T}/w/re3"; rm "${R}/usr/lib/libretro/re3_libretro.so"
	cp "${T}/w/re3/${NAME}.tar" "${T}/w/dist/"
	checkdist; rc=$?
	ok "re3 nel .tar scaricato: check-dist lo ferma" '[ "${rc}" != 0 ] && grep -q "re3 nel SYSTEM" "${T}/check.out"'
	collect "${R}"; rm "${T}/w/dist/core-packages.txt"
	checkdist; rc=$?
	ok "artifact senza core-packages.txt: check-dist si ferma" '[ "${rc}" != 0 ] && grep -q "manca .*core-packages.txt" "${T}/check.out"'
	unset PKGS
else
	skip=$((skip + 1)); echo "  (salto collect: serve squashfs-tools)"
fi

# le prove usano il CORES_DEFAULT della v1.0.0; quello vero deve restare una
# riga che default_cores sa leggere (lo stesso sed)
echo "CORES_DEFAULT del repository"
ok "una riga sola, leggibile da ci-build.sh (default_cores)" '[ "$(sed -n "s/^CORES_DEFAULT=\"\(.*\)\"$/\1/p" "${O}/build-lakka-rf35h.sh" | wc -w)" -ge 10 ] && grep -qF "sed -n '"'"'s/^CORES_DEFAULT=\"\(.*\)\"\$/\1/p'"'"'" "${O}/tools/ci-build.sh"'

# --- pack: i pacchetti interrotti fuori dallo stato -------------------------------
echo "pack: pacchetti interrotti"
# zstd finto (lo stato resta un tar qualunque): la prova non dipende da zstd
mkdir -p "${T}/bin"; printf '#!/bin/sh\nexec cat\n' > "${T}/bin/zstd"; chmod +x "${T}/bin/zstd"
PW="${T}/pw"; B="${PW}/lakka-rf35h-build/build.Lakka-RK3326.aarch64"
pkgdir() { mkdir -p "${B}/build/$2"; printf 'INFO_PKG_NAME="%s"\n' "$1" > "${B}/build/$2/.libreelec-package"; echo x > "${B}/build/$2/file"; }
stamp() { mkdir -p "${B}/.stamps/$1"; echo "STAMP_PKG_NAME=\"$1\"" > "${B}/.stamps/$1/build_$2"; }
owner() { mkdir -p "${B}/.threads/locks"; echo "1 1 build $1" > "${B}/.threads/locks/$1.build.owner"; }
mkpw() {
	rm -rf "${PW}"; mkdir -p "${B}/install_pkg/mgba-1.0/usr/lib/libretro"
	# mgba: il link ucciso alla scadenza, un .so di 0 byte piu' nuovo degli oggetti
	pkgdir mgba mgba-1.0; : > "${B}/build/mgba-1.0/mgba_libretro.so"; owner mgba:target
	# gcc: host finito, target interrotto
	pkgdir gcc gcc-15.1.0; stamp gcc host; owner gcc:target
	# mesa: finito proprio mentre lo si fermava (stamp scritto, lock ancora li')
	pkgdir mesa mesa-26.0; stamp mesa target; owner mesa:target
	# retroarch: solo scompattato (lo legge ikemen-go), nessun job
	pkgdir retroarch retroarch-1.21
	# linux: fatto, la cartella resta (verify-kernel)
	pkgdir linux linux-7.2.9; stamp linux target
	# un nome che comincia come quello di un interrotto, ma e' un altro pacchetto
	pkgdir mgba-tools mgba-tools-2.0; stamp mgba-tools target
}
pack() { ( export PATH="${T}/bin:${PATH}"; W="${PW}" bash "${CB}" pack 1 "${1:-}" > "${T}/pack.out" 2>&1 ); }
mkpw; pack; rc=$?
tar -tf "${PW}/state-1.tar.zst" > "${T}/state.list" 2>/dev/null
inst() { grep -q "^lakka-rf35h-build/build.Lakka-RK3326.aarch64/$1" "${T}/state.list"; }
ok "pack esce 0 e lo stato si legge" '[ "${rc}" = 0 ] && [ -s "${T}/state.list" ]'
ok "mgba interrotto: cartella di build fuori dallo stato, niente .so di 0 byte" '! inst build/mgba-1.0/ && [ ! -e "${B}/build/mgba-1.0" ]'
ok "gcc:target interrotto: cartella e tutti gli stamp di gcc via" '! inst build/gcc-15.1.0/ && [ -z "$(ls "${B}/.stamps/gcc")" ]'
ok "mesa finito (stamp): cartella e stamp restano" 'inst build/mesa-26.0/file && inst .stamps/mesa/build_target'
ok "retroarch solo scompattato, linux fatto: restano" 'inst build/retroarch-1.21/file && inst build/linux-7.2.9/file && inst .stamps/linux/build_target'
ok "mgba-tools (altro pacchetto, nome simile): resta" 'inst build/mgba-tools-2.0/file && inst .stamps/mgba-tools/build_target'
ok "install_pkg resta (lo rifa' la build del pacchetto)" 'inst install_pkg/mgba-1.0/'
ok "lo dice nel log" 'grep -q "interrotti: gcc:target mgba:target: si rifanno da capo (2 cartelle" "${T}/pack.out"'
mkpw; rm -rf "${B}/.threads"; pack failed; rc=$?
ok "senza .threads (nessuna build in questa parte): non toglie niente" '[ "${rc}" = 0 ] && [ -e "${B}/build/mgba-1.0" ] && [ -e "${B}/build/gcc-15.1.0" ]'

if [ "${skip}" = 0 ]; then echo "--- ${pass} ok, ${fail} falliti"; else echo "--- ${pass} ok, ${fail} falliti, ${skip} parti saltate"; fi
[ "${fail}" = 0 ]
