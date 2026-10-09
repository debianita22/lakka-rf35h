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
		printf '%b' "$(le8 "${3:-$((64 + n))}")"                            # e_shoff ($3: un altro)
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
	mkelf "${R}/usr/lib/libretro/mgba_libretro.so" 1000 -64
	collect "${R}"; rc=$?
	ok "un core con e_shoff assurdo (bit alto: negativo in bash): fallisce" '[ "${rc}" != 0 ] && grep -q "core rotti.*mgba_libretro.so" "${T}/collect.out"'
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

	# GitHub non accetta nella release un file da 2 GiB in su (truncate: un
	# file sparso, niente spazio su disco)
	collect "${R}"
	rm -rf "${T}/w/dist"; mkimg "${R}" "${T}/w/lakka-rf35h-build/target"
	truncate -s 2147483648 "${T}/w/lakka-rf35h-build/target/${NAME}.img.gz"
	W="${T}/w" RF35H_VERSION=v9.9.9 bash "${CB}" collect > "${T}/collect.out" 2>&1; rc=$?
	ok "un .img.gz da 2 GiB: collect esce 0 (l'artifact serve lo stesso)" '[ "${rc}" = 0 ] && [ -f "${T}/w/dist/${NAME}.img.gz" ]'
	checkdist; rc=$?
	ok "  ...check-dist lo ferma e lo nomina" '[ "${rc}" != 0 ] && grep -q "file oltre i 2 GiB, la release non si pubblica: ${NAME}.img.gz:2147483648" "${T}/check.out"'
	truncate -s 2147483647 "${T}/w/dist/${NAME}.img.gz"
	checkdist; rc=$?
	ok "  ...un byte sotto il limite passa" '[ "${rc}" = 0 ]'
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
	# l'immagine in costruzione (fuori) e due cartelle "image" dentro i
	# pacchetti (restano: un'esclusione non ancorata le toglieva)
	mkdir -p "${B}/image/system" "${B}/build/linux-7.2.9/drivers/usb/image" "${B}/install_pkg/mgba-1.0/usr/share/image"
	echo x > "${B}/image/system/f"; echo x > "${B}/build/linux-7.2.9/drivers/usb/image/Kconfig"
	echo x > "${B}/install_pkg/mgba-1.0/usr/share/image/pic"
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
ok "build.*/image e .threads fuori dallo stato" '! inst image/ && ! inst .threads/'
ok "una cartella image dentro un pacchetto resta (kernel, install_pkg)" 'inst build/linux-7.2.9/drivers/usb/image/Kconfig && inst install_pkg/mgba-1.0/usr/share/image/pic'
mkpw; rm -rf "${B}/.threads"; pack failed; rc=$?
ok "senza .threads (nessuna build in questa parte): non toglie niente" '[ "${rc}" = 0 ] && [ -e "${B}/build/mgba-1.0" ] && [ -e "${B}/build/gcc-15.1.0" ]'

# --- version e publish, con gh e git finti ------------------------------------------
# git: FAKE_SHA (il commit della build), FAKE_ON_MAIN (yes: e' sul ramo
# principale), FAKE_LS_REMOTE (righe di git ls-remote). gh: FAKE_RELEASES
# (righe "<id> <bozza>" delle release col tag), FAKE_LATEST (tag della latest;
# vuoto: 404; ERRORE: 500). Le chiamate finiscono in calls.log.
FB="${T}/fakebin"; mkdir -p "${FB}"
cat > "${FB}/git" <<'EOF'
#!/bin/bash
echo "git $*" >> "${CALLS}"
[ "$1" = -C ] && shift 2
while [ "${1:-}" = -c ]; do shift 2; done   # -c user.name=... (pins-merge)
case "$1 ${2:-}" in
	"rev-parse --short=7") echo "${FAKE_SHA:0:7}" ;;
	"rev-parse --is-shallow-repository") echo false ;;
	"rev-parse --verify")
		case "${4:-}" in HEAD^{commit}|"${FAKE_SHA}"^{commit}) echo "${FAKE_SHA}" ;; *) exit 1 ;; esac ;;
	"fetch "*) ;;
	"merge-base --is-ancestor") [ "${FAKE_ON_MAIN:-yes}" = yes ] ;;
	# i workflow del commit uguali a quelli di main? (FAKE_WF_DIFF: no)
	"diff --quiet") [ -z "${FAKE_WF_DIFF:-}" ] ;;
	"ls-remote --tags") [ -z "${FAKE_LS_REMOTE:-}" ] || printf '%b\n' "${FAKE_LS_REMOTE}" ;;
	*) echo "git finto: $*" >&2; exit 2 ;;
esac
EOF
cat > "${FB}/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "${CALLS}"
case "$*" in
	"api --paginate repos/"*"/releases?per_page=100 "*) [ -z "${FAKE_RELEASES:-}" ] || printf '%s\n' "${FAKE_RELEASES}" ;;
	"api repos/"*"/releases/latest "*)
		case "${FAKE_LATEST:-}" in
			'') echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
			ERRORE) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
			*) echo "${FAKE_LATEST}" ;;
		esac ;;
	# publish_from: il run (path, stato, commit) e i suoi artifact
	"api repos/"*"/actions/runs/"[0-9]*" --jq "*)
		[ -n "${FAKE_RUN:-}" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
		printf '%b\n' "${FAKE_RUN}" ;;
	"api --paginate repos/"*"/actions/runs/"*"/artifacts?per_page=100 "*) [ -z "${FAKE_RUN_ART:-}" ] || echo "${FAKE_RUN_ART}" ;;
	"release create "*)
		[ -z "${FAKE_CREATE_403:-}" ] || { echo "HTTP 403: Resource not accessible by integration (https://api.github.com/repos/o/r/releases)" >&2; exit 1; }
		[ -z "${FAKE_CREATE_FAIL:-}" ] || { echo "HTTP 422: ${FAKE_CREATE_FAIL} (https://api.github.com/repos/o/r/releases)" >&2; exit 1; } ;;
	"api -X DELETE "*|"release upload "*|"release edit "*) ;;
	*) echo "gh finto: $*" >&2; exit 2 ;;
esac
EOF
cat >> "${FB}/git" <<'EOF'
EOF
# commit e push dei pin (pins-merge): solo registrati
sed -i 's|^\t"ls-remote --tags")|\t"commit "*\|"push "*) ;;\n\t"ls-remote --tags")|' "${FB}/git"
chmod +x "${FB}/git" "${FB}/gh"
SHA=0123456789abcdef0123456789abcdef01234567
export CALLS="${T}/calls.log"
# ci-build.sh <comando> con gh e git finti; uscita in run.out, output in out.txt
fake() {
	: > "${CALLS}"; : > "${T}/out.txt"
	( export PATH="${FB}:${PATH}" GITHUB_REPOSITORY=o/r DEFAULT_BRANCH=main GITHUB_SHA="${FAKE_GITHUB_SHA:-${SHA}}" \
		GITHUB_RUN_NUMBER=7 GITHUB_OUTPUT="${T}/out.txt" FAKE_SHA="${SHA}"
	  bash "${CB}" "$@" > "${T}/run.out" 2>&1 )
}
outv() { sed -n "s/^$1=//p" "${T}/out.txt"; }
called() { grep -q -- "$1" "${CALLS}"; }

echo "version (job setup)"
vers() { GITHUB_EVENT_NAME="$1" GITHUB_REF_TYPE="$2" GITHUB_REF_NAME="$3" IN_VERSION="${4:-}" IN_PRERELEASE="${5:-false}" fake version; }
vers workflow_dispatch branch main v1.1.0-rc1 false; rc=$?
ok "Run workflow v1.1.0-rc1 senza la casella: pre-release" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = true ] && [ "$(outv publish)" = true ]'
vers workflow_dispatch branch main v1.1.0 true; rc=$?
ok "Run workflow v1.1.0 con la casella: pre-release" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = true ]'
vers workflow_dispatch branch main v1.1.0 false; rc=$?
ok "Run workflow v1.1.0 da main: release, non pre-release" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = false ] && [ "$(outv version)" = v1.1.0 ]'
vers workflow_dispatch branch prova v1.1.0 false; rc=$?
ok "Run workflow v1.1.0 da un altro ramo: si ferma" '[ "${rc}" != 0 ] && grep -q "solo pre-release" "${T}/run.out"'
FAKE_ON_MAIN=no vers workflow_dispatch branch prova v1.1.0 true; rc=$?
ok "  ...con la casella pre-release: va" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = true ]'
FAKE_ON_MAIN=no vers push tag v1.1.0; rc=$?
ok "tag v1.1.0 su un commit fuori da main: si ferma" '[ "${rc}" != 0 ] && grep -q "non e. su main" "${T}/run.out" && called "merge-base --is-ancestor ${SHA} refs/remotes/origin/main"'
vers push tag v1.1.0; rc=$?
ok "tag v1.1.0 su main: release" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = false ]'
FAKE_ON_MAIN=no vers push tag v1.1.0-rc2; rc=$?
ok "tag v1.1.0-rc2 da qualunque ramo: pre-release" '[ "${rc}" = 0 ] && [ "$(outv prerelease)" = true ] && ! called merge-base'
FAKE_LS_REMOTE="1111111111111111111111111111111111111111\trefs/tags/v1.1.0" vers workflow_dispatch branch main v1.1.0 false; rc=$?
ok "Run workflow con un tag che esiste gia': si ferma" '[ "${rc}" != 0 ] && grep -q "il tag v1.1.0 esiste gia" "${T}/run.out"'
FAKE_RELEASES="42 false" vers push tag v1.1.0; rc=$?
ok "release gia' pubblicata: si ferma" '[ "${rc}" != 0 ] && grep -q "la release v1.1.0 esiste gia" "${T}/run.out"'
vers workflow_dispatch branch main ""; rc=$?
ok "Run workflow senza version: build di prova" '[ "${rc}" = 0 ] && [ "$(outv publish)" = false ] && [ "$(outv version)" = ci-7-0123456 ]'
IN_RESUME=123 vers workflow_dispatch branch main v1.1.0; rc=$?
ok "resume_run con una version: si ferma" '[ "${rc}" != 0 ] && grep -q "resume_run solo per le build di prova" "${T}/run.out"'
# publish_from: i file di un altro run, il suo commit
RUNOK=".github/workflows/build.yml\tcompleted\t${SHA}"
FAKE_GITHUB_SHA=ffffffffffffffffffffffffffffffffffffffff FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from: release con i file e il commit di quel run" '[ "${rc}" = 0 ] && [ "$(outv from)" = 555 ] && [ "$(outv build_sha)" = "${SHA}" ] && [ "$(outv publish)" = true ] && called "merge-base --is-ancestor ${SHA} refs/remotes/origin/main"'
vers workflow_dispatch branch main v1.1.0 false; rc=$?
ok "  ...senza: from vuoto, build_sha il commit del run" '[ "${rc}" = 0 ] && [ -z "$(outv from)" ] && [ "$(outv build_sha)" = "${SHA}" ]'
FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=55x vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from non numerico: si ferma" '[ "${rc}" != 0 ] && grep -q "publish_from: un ID di run" "${T}/run.out"'
FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main ""; rc=$?
ok "publish_from senza version: si ferma" '[ "${rc}" != 0 ] && grep -q "con la version della build" "${T}/run.out"'
FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 IN_RESUME=12 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from con resume_run: si ferma" '[ "${rc}" != 0 ] && grep -q "resume_run" "${T}/run.out"'
FAKE_RUN=".github/workflows/build.yml\tin_progress\t${SHA}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from di un run non finito: si ferma" '[ "${rc}" != 0 ] && grep -q "non e. finito" "${T}/run.out"'
FAKE_RUN=".github/workflows/cores.yml\tcompleted\t${SHA}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from di un run che non e' una build: si ferma" '[ "${rc}" != 0 ] && grep -q "non e. una build" "${T}/run.out"'
FAKE_RUN="${RUNOK}" FAKE_RUN_ART="" IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from senza l'artifact della versione: si ferma" '[ "${rc}" != 0 ] && grep -q "non ha i file della v1.3.1" "${T}/run.out" && called "artifacts?per_page=100"'
FAKE_RUN="" IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from di un run che non c'e': si ferma" '[ "${rc}" != 0 ] && grep -q "il run 555 non si legge" "${T}/run.out"'
FAKE_ON_MAIN=no FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from di una build fuori da main: si ferma" '[ "${rc}" != 0 ] && grep -q "non e. su main" "${T}/run.out"'
# un commit coi workflow diversi da quelli di main: il GITHUB_TOKEN non puo'
# crearne il tag (v1.4.0)
FAKE_WF_DIFF=1 vers workflow_dispatch branch main v1.3.1 false; rc=$?
ok "Run workflow da un commit coi workflow diversi da main: va, con un avviso" '[ "${rc}" = 0 ] && [ "$(outv publish)" = true ] && grep -q "attenzione: i .github/workflows di ${SHA:0:12} non sono piu. quelli di main" "${T}/run.out"'
vers workflow_dispatch branch main v1.3.1 false; rc=$?
ok "  ...coi workflow uguali a main: va, senza avviso" '[ "${rc}" = 0 ] && [ "$(outv publish)" = true ] && ! grep -q "attenzione" "${T}/run.out"'
FAKE_WF_DIFF=1 vers push tag v1.3.1; rc=$?
ok "  ...con il push del tag invece: va (il tag c'e')" '[ "${rc}" = 0 ] && [ "$(outv publish)" = true ]'
FAKE_WF_DIFF=1 FAKE_LS_REMOTE="${SHA}\trefs/tags/v1.3.1" FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "  ...publish_from con il tag gia' creato sul commit della build: va" '[ "${rc}" = 0 ] && [ "$(outv from)" = 555 ]'
FAKE_LS_REMOTE="1111111111111111111111111111111111111111\trefs/tags/v1.3.1" FAKE_RUN="${RUNOK}" FAKE_RUN_ART=99 IN_PUBLISH_FROM=555 vers workflow_dispatch branch main v1.3.1; rc=$?
ok "publish_from con il tag su un altro commit: si ferma" '[ "${rc}" != 0 ] && grep -q "il tag v1.3.1 esiste gia" "${T}/run.out"'

echo "publish (job release)"
PD="${T}/pubdist"; mkdir -p "${PD}"
touch "${PD}/${NAME}.img.gz" "${PD}/${NAME}.tar" "${PD}/update.txt" "${PD}/SHA256SUMS" "${PD}/RELEASE-NOTES.md"
pub() { VERSION="$1" PRERELEASE="${2:-false}" fake publish "${PD}"; }
# l'ordine: create (bozza) -> upload -> edit (pubblicata), l'ultima con --latest=$1
seq_ok() { [ "$(grep -oE '^gh release (create|upload|edit)' "${CALLS}" | tr '\n' ' ')" = "gh release create gh release upload gh release edit " ] && grep -q -- "^gh release edit .*--draft=false --latest=$1$" "${CALLS}"; }
FAKE_LATEST=v1.1.0 pub v1.2.0; rc=$?
ok "v1.2.0 dopo la v1.1.0: latest" '[ "${rc}" = 0 ] && seq_ok true && called "release create v1.2.0 --repo o/r --draft --target ${SHA}" && called "release upload v1.2.0 --repo o/r --clobber"'
ok "  ...non pre-release" '! called "--prerelease"'
FAKE_LATEST=v1.1.0 pub v1.0.1; rc=$?
ok "v1.0.1 dopo la v1.1.0: pubblicata, ma non latest" '[ "${rc}" = 0 ] && seq_ok false'
FAKE_LATEST=v1.9.0 pub v1.10.0; rc=$?
ok "v1.10.0 dopo la v1.9.0: latest (ordine delle versioni, non delle stringhe)" '[ "${rc}" = 0 ] && seq_ok true'
pub v1.0.0; rc=$?
ok "la prima release (nessuna latest, 404): latest" '[ "${rc}" = 0 ] && seq_ok true'
FAKE_LATEST=v1.1.0-rc1 pub v1.1.0; rc=$?
ok "v1.1.0 dopo una v1.1.0-rc1 promossa a mano a latest: latest" '[ "${rc}" = 0 ] && seq_ok true'
FAKE_LATEST=v1.1.0 pub v1.1.0-rc2 false; rc=$?
ok "v1.1.0-rc2 dopo la v1.1.0: pre-release, la latest resta" '[ "${rc}" = 0 ] && seq_ok false'
FAKE_LATEST=ERRORE pub v1.2.0; rc=$?
ok "latest illeggibile (500): si ferma prima di creare" '[ "${rc}" != 0 ] && ! called "release create"'
FAKE_LATEST=v1.0.0 FAKE_ON_MAIN=no pub v1.1.0-rc1 false; rc=$?
ok "v1.1.0-rc1 (anche con PRERELEASE=false, fuori da main): pre-release, mai latest" '[ "${rc}" = 0 ] && seq_ok false && called "release create v1.1.0-rc1 .*--prerelease" && ! called "releases/latest"'
FAKE_ON_MAIN=no pub v1.2.0; rc=$?
ok "release fuori da main: si ferma prima di creare" '[ "${rc}" != 0 ] && ! called "release create"'
FAKE_LS_REMOTE="1111111111111111111111111111111111111111\trefs/tags/v1.2.0" pub v1.2.0; rc=$?
ok "tag v1.2.0 gia' su un altro commit: si ferma" '[ "${rc}" != 0 ] && grep -q "il tag v1.2.0 e. su 111111111111" "${T}/run.out" && ! called "release create"'
FAKE_LS_REMOTE="2222222222222222222222222222222222222222\trefs/tags/v1.2.0\n${SHA}\trefs/tags/v1.2.0^{}" pub v1.2.0; rc=$?
ok "tag annotato sullo stesso commit (push del tag): va" '[ "${rc}" = 0 ] && seq_ok true'
FAKE_RELEASES="555 true" pub v1.2.0; rc=$?
ok "bozza di un tentativo fallito: cancellata, poi da capo" '[ "${rc}" = 0 ] && called "api -X DELETE repos/o/r/releases/555" && [ "$(grep -n "DELETE" "${CALLS}" | cut -d: -f1)" -lt "$(grep -n "release create" "${CALLS}" | cut -d: -f1)" ]'
FAKE_RELEASES="556 false" pub v1.2.0; rc=$?
ok "release gia' pubblicata: si ferma, niente cancellato" '[ "${rc}" != 0 ] && ! called DELETE && ! called "release create"'
FAKE_GITHUB_SHA=ffffffffffffffffffffffffffffffffffffffff RF35H_BUILD_SHA="${SHA}" FAKE_LATEST=v1.3.0 pub v1.3.1; rc=$?
ok "publish_from: tag sul commit della build, non su quello del run" '[ "${rc}" = 0 ] && seq_ok true && called "release create v1.3.1 --repo o/r --draft --target ${SHA}"'
FAKE_WF_DIFF=1 FAKE_LATEST=v1.3.0 RF35H_FROM_RUN=555 pub v1.3.1; rc=$?
ok "workflow cambiati su main durante la build: si prova (a volte GitHub lo permette, v1.3.0)" '[ "${rc}" = 0 ] && seq_ok true'
FAKE_WF_DIFF=1 FAKE_CREATE_403=1 FAKE_LATEST=v1.3.0 RF35H_FROM_RUN=555 pub v1.3.1; rc=$?
ok "  ...e se gh risponde 403: si ferma col 403 e le due strade" '[ "${rc}" != 0 ] && grep -q "HTTP 403: Resource not accessible by integration" "${T}/run.out" && grep -q "git push origin ${SHA}:refs/tags/v1.3.1" "${T}/run.out" && grep -q "git checkout ${SHA:0:12} -- .github/workflows" "${T}/run.out" && grep -q "publish_from 555" "${T}/run.out" && ! called "release upload"'
FAKE_CREATE_403=1 FAKE_LATEST=v1.3.0 pub v1.3.1; rc=$?
ok "  ...un 403 coi workflow uguali a main: solo il messaggio di gh" '[ "${rc}" != 0 ] && grep -q "HTTP 403" "${T}/run.out" && ! grep -q "git checkout" "${T}/run.out"'
FAKE_WF_DIFF=1 FAKE_LS_REMOTE="${SHA}\trefs/tags/v1.3.1" FAKE_LATEST=v1.3.0 pub v1.3.1; rc=$?
ok "  ...con il tag gia' creato sul commit: pubblica" '[ "${rc}" = 0 ] && seq_ok true'
FAKE_CREATE_FAIL="Validation Failed" FAKE_LATEST=v1.3.0 pub v1.3.1; rc=$?
ok "gh release create fallito: si ferma con il messaggio di gh" '[ "${rc}" != 0 ] && grep -q "gh release create: HTTP 422: Validation Failed" "${T}/run.out" && ! called "release upload"'

echo "note della release: da quale release"
# un repository vero (merge-base, describe, log) con v1.0.0, v1.1.0-rc1 e
# v1.1.0, e un gh finto che risponde come gh api ... --jq: i tag delle release
# stabili, dalla piu' nuova (FAKE_STABLE; FAKE_GH_FAIL=yes: errore)
NR="${T}/notes-repo"; mkdir -p "${NR}/tools" "${T}/notesbin" "${T}/ndist"
cp "${O}/tools/ci-release-notes.sh" "${NR}/tools/"
cp "${REPO}/build-lakka-rf35h.sh" "${NR}/"
nc() { git -C "${NR}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$1"; [ -z "${2:-}" ] || git -C "${NR}" tag "$2"; }
git -C "${NR}" init -q && git -C "${NR}" add -A && nc "first" v1.0.0 && nc "lto" v1.1.0-rc1 && nc "fixes" v1.1.0 && nc "docs"
printf 'version=v1.2.0\ntar=x-v1.2.0.tar\n' > "${T}/ndist/update.txt"; : > "${T}/ndist/x-v1.2.0.img.gz"
cat > "${T}/notesbin/gh" <<'EOF'
#!/bin/bash
[ "${FAKE_GH_FAIL:-no}" = yes ] && exit 1
case "$*" in "api repos/o/r/releases?per_page=100 "*) printf '%b\n' "${FAKE_STABLE:-}" ;; *) exit 2 ;; esac
EOF
chmod +x "${T}/notesbin/gh"
NSHA="$(git -C "${NR}" rev-parse HEAD)"
notes() { ( export PATH="${T}/notesbin:${PATH}" GITHUB_REPOSITORY=o/r GITHUB_SHA="${NSHA}"
	bash "${NR}/tools/ci-release-notes.sh" "${T}/ndist" > "${T}/nnotes.md" 2>/dev/null ); }
GH_TOKEN=x FAKE_STABLE="v1.0.0" notes; rc=$?
ok "v1.1.0 ancora pre-release: i cambi dalla v1.0.0, tutti" '[ "${rc}" = 0 ] && grep -qx "Changes since v1.0.0:" "${T}/nnotes.md" && [ "$(grep -c "^- \(lto\|fixes\|docs\)$" "${T}/nnotes.md")" = 3 ]'
ok "  ...e il link alle note della v1.0.0" 'grep -qF "[v1.0.0 release notes](https://github.com/o/r/releases/tag/v1.0.0)" "${T}/nnotes.md"'
GH_TOKEN=x FAKE_STABLE="v1.1.0-rc1\nv1.1.0\nv1.0.0" notes; rc=$?
ok "v1.1.0 promossa, rc1 senza la spunta pre-release: dalla v1.1.0" '[ "${rc}" = 0 ] && grep -qx "Changes since v1.1.0:" "${T}/nnotes.md" && grep -qx -- "- docs" "${T}/nnotes.md" && ! grep -qx -- "- fixes" "${T}/nnotes.md"'
# job release rilanciato: il tag v1.2.0 c'e' gia', sul commit della build
git -C "${NR}" tag v1.2.0
GH_TOKEN=x FAKE_STABLE="v1.2.0\nv1.1.0" notes; rc=$?
ok "la release stessa (job rilanciato, tag gia' creato) non conta" '[ "${rc}" = 0 ] && grep -qx "Changes since v1.1.0:" "${T}/nnotes.md"'
git -C "${NR}" tag -d v1.2.0 >/dev/null
GH_TOKEN=x FAKE_GH_FAIL=yes notes; rc=$?
ok "gh in errore: l'ultimo tag senza trattino, senza link" '[ "${rc}" = 0 ] && grep -qx "Changes since v1.1.0:" "${T}/nnotes.md" && ! grep -q "release notes\](" "${T}/nnotes.md"'
( unset GH_TOKEN; FAKE_STABLE="v1.0.0" notes ); rc=$?
ok "senza GH_TOKEN (prove, a mano): l'ultimo tag senza trattino" '[ "${rc}" = 0 ] && grep -qx "Changes since v1.1.0:" "${T}/nnotes.md"'
ok "la nota per chi aggiorna dalla v1.0.0 o dalla rc1, con la versione giusta" 'grep -q "^\*\*Updating from v1.0.0 or v1.1.0-rc1\*\*" "${T}/nnotes.md" && grep -qF "*ready: v1.2.0, select to restart and install*" "${T}/nnotes.md"'
ok "senza size= in update.txt: niente riga dello spazio" '! grep -q "Free space" "${T}/nnotes.md"'
# lo spazio che System Update chiede (2 volte il .tar piu' 100 MB), "[skip ci]"
# tolto dai soggetti, e le novita' scritte a mano in cima
printf 'version=v1.2.0\ntar=x-v1.2.0.tar\nsize=1050673152\n' > "${T}/ndist/update.txt"
mkdir -p "${NR}/docs/release-notes"; printf '**What is new**\n\n- a thing\n' > "${NR}/docs/release-notes/v1.2.0.md"
nc "only docs [skip ci]"; NSHA="$(git -C "${NR}" rev-parse HEAD)"
( unset GH_TOKEN; notes ); rc=$?
ok "spazio: 1002 MB, ne servono 2104" '[ "${rc}" = 0 ] && grep -qF "**Free space**: the update is 1002 MB; System Update needs about 2104 MB" "${T}/nnotes.md"'
ok "  ...soggetti senza [skip ci]" 'grep -qx -- "- only docs" "${T}/nnotes.md" && ! grep -qF "[skip ci]" "${T}/nnotes.md"'
ok "  ...novita' della versione subito dopo il titolo" '[ "$(sed -n 3p "${T}/nnotes.md")" = "**What is new**" ] && [ "$(grep -c "^- a thing$" "${T}/nnotes.md")" = 1 ]'

# i core aggiornati dalla release precedente (cores/pins.txt)
mkdir -p "${NR}/cores"
pc() { git -C "${NR}" add cores/pins.txt && git -C "${NR}" -c user.name=t -c user.email=t@t commit -q -m "$1"; }
printf '# commento\nfceumm https://x/fceumm 1111111111111111111111111111111111111111 -\nmgba https://x/mgba 2222222222222222222222222222222222222222 -\n' > "${NR}/cores/pins.txt"; pc "pins: i commit di Lakka"
printf '# commento\nfceumm https://x/fceumm 1111111111111111111111111111111111111111 -\nmgba https://x/mgba 2222222222222222222222222222222222222222 -\nsnes9x https://x/snes9x 3333333333333333333333333333333333333333 -\n' > "${NR}/cores/pins.txt"; pc "pins: un core in piu', al commit di Lakka"
sed -i 's/^mgba .*/mgba https:\/\/x\/mgba 4444444444444444444444444444444444444444 -/' "${NR}/cores/pins.txt"; pc "cores: 1 core all'upstream"
NSHA="$(git -C "${NR}" rev-parse HEAD)"
( unset GH_TOKEN; notes ); rc=$?
ok "core aggiornati: dalla v1.1.0 (senza pins.txt), rispetto alla prima versione di ogni core" '[ "${rc}" = 0 ] && grep -qx "\*\*Cores updated\*\* to a newer upstream commit since v1.1.0 (1): mgba." "${T}/nnotes.md"'
git -C "${NR}" tag v1.2.0
sed -i 's/^snes9x .*/snes9x https:\/\/x\/snes9x 5555555555555555555555555555555555555555 -/; s/^fceumm .*/fceumm https:\/\/x\/fceumm 6666666666666666666666666666666666666666 -/' "${NR}/cores/pins.txt"; pc "cores: 2 core all'upstream"
NSHA="$(git -C "${NR}" rev-parse HEAD)"; printf 'version=v1.3.0\ntar=x-v1.3.0.tar\n' > "${T}/ndist/update.txt"
( unset GH_TOKEN; notes ); rc=$?
ok "  ...dalla v1.2.0 (con pins.txt): solo quelli cambiati da allora, nell'ordine del file" '[ "${rc}" = 0 ] && grep -qx "\*\*Cores updated\*\* to a newer upstream commit since v1.2.0 (2): fceumm, snes9x." "${T}/nnotes.md"'
git -C "${NR}" tag v1.3.0; nc "docs"; NSHA="$(git -C "${NR}" rev-parse HEAD)"; printf 'version=v1.3.1\ntar=x-v1.3.1.tar\n' > "${T}/ndist/update.txt"
( unset GH_TOKEN; notes ); rc=$?
ok "  ...nessun core cambiato: nessuna riga" '[ "${rc}" = 0 ] && ! grep -q "Cores updated" "${T}/nnotes.md"'

echo "ci-apt.sh (apt sul runner, con limite di tempo)"
FA="${T}/fakeapt"; rm -rf "${FA}"; mkdir -p "${FA}"
printf '#!/bin/sh\nexec "$@"\n' > "${FA}/sudo"
# apt-get finto: il comportamento della chiamata N da $FA/modo ("appeso",
# "errore" o "ok", una parola per chiamata; dopo l'ultima, l'ultima)
cat > "${FA}/apt-get" <<'EOF'
#!/bin/sh
n=$(( $(cat "${FA_DIR}/n" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${FA_DIR}/n"
echo "$*" >> "${FA_DIR}/chiamate"
m="$(tr ' ' '\n' < "${FA_DIR}/modo" | sed -n "${n}p")"
[ -n "${m}" ] || m="$(tr ' ' '\n' < "${FA_DIR}/modo" | grep . | tail -1)"
case "${m}" in appeso) sleep 30 ;; errore) exit 100 ;; esac
exit 0
EOF
chmod +x "${FA}/sudo" "${FA}/apt-get"
apt_run() { rm -f "${FA}/n" "${FA}/chiamate"; echo "$1" > "${FA}/modo"
	( export PATH="${FA}:${PATH}" FA_DIR="${FA}" CI_APT_TIMEOUT=1 CI_APT_SLEEP=0
	  bash "${O}/tools/ci-apt.sh" zstd squashfs-tools > "${FA}/out" 2>&1 ); }
apt_run "ok"; rc=$?
ok "ci-apt: update e install, una volta" '[ "${rc}" = 0 ] && [ "$(cat "${FA}/n")" = 2 ] && grep -q "install -y -qq zstd squashfs-tools" "${FA}/chiamate" && grep -q "DPkg::Lock::Timeout=60 update" "${FA}/chiamate"'
apt_run "appeso ok"; rc=$?
ok "ci-apt: update appeso, ucciso dal timeout, secondo tentativo riuscito" '[ "${rc}" = 0 ] && [ "$(cat "${FA}/n")" = 3 ] && grep -q "tentativo 1 di 3" "${FA}/out"'
apt_run "ok errore ok"; rc=$?
ok "ci-apt: install fallito, si riparte da update" '[ "${rc}" = 0 ] && [ "$(cat "${FA}/n")" = 4 ]'
apt_run "errore"; rc=$?
ok "ci-apt: tre tentativi falliti, esce 1 con ::error" '[ "${rc}" = 1 ] && [ "$(cat "${FA}/n")" = 3 ] && grep -q "^::error title=apt::zstd squashfs-tools non installati" "${FA}/out"'

echo "pins-merge (job cores)"
CD="${T}/coresdist"; rm -rf "${CD}"; mkdir -p "${CD}" "${REPO}/cores"
cat > "${CD}/built.txt" <<EOF
core=fceumm commit=aaaaaaa0000000000000000000000000000000000 site=https://github.com/libretro/libretro-fceumm lakka=e2cf2e5c sysroot=v1.2.0 date=20261005
core=mgba commit=bbbbbbb0000000000000000000000000000000000 site=https://github.com/mgba-emu/mgba lakka=e2cf2e5c sysroot=v1.2.0 date=20261005
EOF
: > "${CD}/failed.txt"
# pins-merge con git vero: un origin nudo, il checkout del run al commit da
# cui e' partito, e intanto un altro commit sul ramo. Il commit dei pin deve
# andare sopra quello, non al posto (prima: push di HEAD, rifiutato).
PG="${T}/pg"; rm -rf "${PG}"; mkdir -p "${PG}"
# senza la configurazione globale di chi lancia le prove (firma dei commit,
# push.negotiate): in CI non c'e'
gt() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }
gt init -q --bare "${PG}/origin.git"
gt clone -q "${PG}/origin.git" "${PG}/a" 2>/dev/null
mkdir -p "${PG}/a/tools" "${PG}/a/cores"; cp "${CB}" "${PG}/a/tools/ci-build.sh"
cat > "${PG}/a/cores/pins.txt" <<EOF
# commento
fceumm            https://github.com/libretro/libretro-fceumm          0000000111111111111111111111111111111111 -
mgba              https://github.com/mgba-emu/mgba                     bbbbbbb0000000000000000000000000000000000 -
snes9x            https://github.com/libretro/snes9x                   cccccccc111111111111111111111111111111111 -
EOF
echo uno > "${PG}/a/README"
gt -C "${PG}/a" add -A && gt -C "${PG}/a" commit -q -m base && gt -C "${PG}/a" push -q origin HEAD:main
gt clone -q "${PG}/origin.git" "${PG}/run"
gt clone -q "${PG}/origin.git" "${PG}/b" && echo due >> "${PG}/b/README" && gt -C "${PG}/b" commit -qam intanto && gt -C "${PG}/b" push -q origin HEAD:main
cat > "${T}/pins-new.txt" <<EOF
# commento
fceumm            https://github.com/libretro/libretro-fceumm          aaaaaaa0000000000000000000000000000000000 -
mgba              https://github.com/mgba-emu/mgba                     bbbbbbb0000000000000000000000000000000000 -
snes9x            https://github.com/libretro/snes9x                   dddddddd111111111111111111111111111111111 -
EOF
pm() { : > "${PG}/out.txt"; ( cd "${PG}/run" && unset GITHUB_ACTIONS && export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 && DEFAULT_BRANCH=main GITHUB_OUTPUT="${PG}/out.txt" PINS_RETRY_SLEEP=0 bash tools/ci-build.sh pins-merge "$@" ) > "${PG}/run.out" 2>&1; }
opins() { git -C "${PG}/origin.git" show main:cores/pins.txt; }
pm "${CD}" "${T}/pins-new.txt"; rc=$?
ok "pins-merge: fceumm al nuovo, snes9x (non compilato) resta, mgba uguale" '[ "${rc}" = 0 ] && opins | grep -q "^fceumm .* aaaaaaa0000000000000000000000000000000000 -" && opins | grep -q "^snes9x .* cccccccc111111111111111111111111111111111 -" && opins | grep -q "^# commento"'
ok "  ...sopra il commit arrivato intanto sul ramo, non al posto" '[ "$(git -C "${PG}/origin.git" log --format=%s -2 main | tr "\n" "|")" = "cores: 1 core all'"'"'upstream|intanto|" ] && [ "$(git -C "${PG}/origin.git" show main:README | tr "\n" " ")" = "uno due " ]'
ok "  ...da github-actions, changed=true, niente worktree rimasti" '[ "$(git -C "${PG}/origin.git" log -1 --format=%an main)" = "github-actions[bot]" ] && [ "$(sed -n "s/^changed=//p" "${PG}/out.txt")" = true ] && [ "$(git -C "${PG}/run" worktree list | wc -l)" = 1 ]'
h="$(git -C "${PG}/origin.git" rev-parse main)"
pm "${CD}" "${T}/pins-new.txt"; rc=$?
ok "pins-merge di nuovo: niente da cambiare, niente commit" '[ "${rc}" = 0 ] && [ "$(git -C "${PG}/origin.git" rev-parse main)" = "${h}" ] && [ "$(sed -n "s/^changed=//p" "${PG}/out.txt")" = false ]'
# il ramo si muove fra fetch e push: l'origin rifiuta il primo push
cat > "${PG}/origin.git/hooks/pre-receive" <<'EOF'
#!/bin/sh
f="$(pwd)/rifiuta"
[ -f "${f}" ] || exit 0
n="$(cat "${f}")"; [ "${n}" = sempre ] || rm -f "${f}"
echo "rifiutato per la prova" >&2; exit 1
EOF
chmod +x "${PG}/origin.git/hooks/pre-receive"
printf 'core=snes9x commit=dddddddd111111111111111111111111111111111 site=x lakka=x sysroot=x date=x\n' > "${T}/built-snes9x.txt"
mkdir -p "${T}/cd2" && cp "${T}/built-snes9x.txt" "${T}/cd2/built.txt"
echo una > "${PG}/origin.git/rifiuta"
pm "${T}/cd2" "${T}/pins-new.txt"; rc=$?
ok "push rifiutato una volta: riprova dalla punta e passa" '[ "${rc}" = 0 ] && grep -q "push rifiutato (tentativo 1 di 3)" "${PG}/run.out" && opins | grep -q "^snes9x .* dddddddd111111111111111111111111111111111 -"'
echo sempre > "${PG}/origin.git/rifiuta"
sed -i 's/aaaaaaa0000000000000000000000000000000000/eeeeeee0000000000000000000000000000000000/' "${T}/pins-new.txt"
pm "${CD}" "${T}/pins-new.txt"; rc=$?
ok "push sempre rifiutato: esce 1 dopo 3 tentativi, niente worktree rimasti" '[ "${rc}" = 1 ] && grep -q "tentativo 3 di 3" "${PG}/run.out" && grep -q "non riuscito dopo 3 tentativi" "${PG}/run.out" && [ "$(git -C "${PG}/run" worktree list | wc -l)" = 1 ]'
rm -f "${PG}/origin.git/rifiuta"

echo "cores (job cores): il .so deve venire dal commit del pin"
CW="${T}/cw"; rm -rf "${CW}"; mkdir -p "${CW}/lakka-rf35h" "${CW}/lakka-rf35h-build"
git -C "${CW}/lakka-rf35h-build" init -q && git -C "${CW}/lakka-rf35h-build" -c user.name=t -c user.email=t@t commit -q --allow-empty -m lakka
SF=1111111111111111111111111111111111111111; SG=2222222222222222222222222222222222222222; SM=3333333333333333333333333333333333333333
cat > "${REPO}/cores/pins.txt" <<EOF
fceumm    https://github.com/libretro/libretro-fceumm    ${SF} -
gambatte  https://github.com/libretro/gambatte-libretro  ${SG} -
mgba      https://github.com/mgba-emu/mgba               ${SM} -
EOF
# build-in-docker finto: il resoconto di --build-packages e i .so in target/cores.
# gambatte "compilato" dalla cartella di un commit vecchio (il caso del sysroot)
cat > "${CW}/lakka-rf35h/build-in-docker.sh" <<EOF
#!/bin/bash
t="${CW}/lakka-rf35h-build"
mkdir -p "\${t}/target/cores/fceumm" "\${t}/target/cores/gambatte"
cp "${T}/so.fceumm" "\${t}/target/cores/fceumm/fceumm_libretro.so"
cp "${T}/so.gambatte" "\${t}/target/cores/gambatte/gambatte_libretro.so"
{
	echo "fceumm ok: fceumm_libretro.so (install_pkg/fceumm-${SF})"
	echo "gambatte ok: gambatte_libretro.so (install_pkg/gambatte-9fe223d9c4b615c55840170c6e85e6e9fa4bd1d2)"
	echo "mgba fallito (uscita 2)    log: x"
} > "\${t}/build-rf35h-20261008-010000-pacchetti.txt"
printf '%s\n' "patching file src/a.c" "Reversed (or previously applied) patch detected!  Skipping patch." \
	"*********** FAILED COMMAND ***********" 'cat \${i} | patch -d "\${PKG_BUILD}" -p1' > "\${t}/build-rf35h-20261008-010000-mgba-fallito.log"
exit 1
EOF
chmod +x "${CW}/lakka-rf35h/build-in-docker.sh"
mkelf "${T}/so.fceumm" 2000; mkelf "${T}/so.gambatte" 1500
( export W="${CW}" RF35H_CONTAINER=x RF35H_SYSROOT_VERSION=ci-33-893a42f GITHUB_ACTIONS=true; bash "${CB}" cores "fceumm gambatte mgba" > "${T}/cores.out" 2>&1 ); rc=$?
ok "cores: esce 0 con almeno un riuscito" '[ "${rc}" = 0 ]'
ok "  ...fceumm riuscito, al commit del pin, con il sysroot" '[ "$(grep -c "^core=" "${CW}/cores/built.txt")" = 1 ] && grep -q "^core=fceumm commit=${SF} " "${CW}/cores/built.txt" && grep -q " sysroot=ci-33-893a42f " "${CW}/cores/built.txt" && ! ls "${CW}/cores/"*.so.gz >/dev/null 2>&1'
ok "  ...gambatte da un commit vecchio: fuori, fra i falliti" 'grep -q "^== gambatte: compilato da install_pkg/gambatte-9fe223d" "${CW}/cores/failed.txt" && ! grep -q "core=gambatte" "${CW}/cores/built.txt"'
ok "  ...mgba fallito, con la riga del resoconto" 'grep -q "^== mgba: mgba fallito" "${CW}/cores/failed.txt"'
ok "  ...e il perche' dal suo log (core_why): la patch gia' applicata, il comando" 'grep -q "^Reversed (or previously applied) patch detected" "${CW}/cores/failed.txt" && grep -qF "comando: cat \${i} | patch" "${CW}/cores/failed.txt"'
ok "  ...un'annotazione per fallito, col perche'" 'grep -q "^::warning title=Core mgba::== mgba: mgba fallito (uscita 2)" "${T}/cores.out" && grep -q "^::warning title=Core gambatte::== gambatte: compilato da install_pkg/gambatte-9fe223d" "${T}/cores.out" && ! grep -q "title=Core fceumm::" "${T}/cores.out"'
ok "  ...nella notice i riusciti col commit provato (core@sha)" 'grep -q "^::notice title=Core::riusciti: fceumm@1111111 ; falliti: " "${T}/cores.out"'

echo "build-lakka-rf35h.sh --build-packages: il log del fallito e' solo suo"
# scripts/clean e scripts/build finti: "lungo" compila con 600 righe che
# contengono "error:", "thr" fallisce col log di un thread, "corto" si ferma
# subito su una patch. Col log comune, la coda di "corto" erano le righe di
# "lungo" (cores.yml dell'8/10/2026).
PB="${T}/pb"; rm -rf "${PB}"; mkdir -p "${PB}/scripts" "${PB}/build.x/.threads/logs"
cat > "${PB}/scripts/build" <<EOF
#!/bin/bash
case "\$1" in
	lungo) for i in \$(seq 600); do echo "lungo riga \${i}: warning, error: niente"; done ;;
	thr)   echo "errore nel thread di thr" > "${PB}/build.x/.threads/logs/7.log"; echo "    ${PB}/build.x/.threads/logs/7.log"; exit 2 ;;
	corto) echo "Hunk #1 FAILED at 12."; echo "1 out of 1 hunk FAILED"; exit 1 ;;
	nopulito) exit 0 ;;
esac
EOF
printf '#!/bin/bash\n[ "$1" = nopulito ] && { echo "clean rotto"; exit 4; }\necho "CLEAN $1"\n' > "${PB}/scripts/clean"
chmod +x "${PB}/scripts/clean" "${PB}/scripts/build"
eval "$(sed -n '/^pkg_build_logged() {/,/^}/p' "${O}/build-lakka-rf35h.sh")"
PBL="${PB}/build-rf35h-20261008-120000.log"
( cd "${PB}" || exit 9; LOG="${PBL}"; BENV=(X=1); set -e
  for p in lungo thr corto nopulito; do r=0; pkg_build_logged "${p}" > /dev/null || r=$?; echo "${p} ${r}"; done ) > "${T}/pb.out" 2>&1
ok "pkg_build_logged: l'uscita di build o di clean, anche sotto set -e" '[ "$(tr "\n" " " < "${T}/pb.out")" = "lungo 0 thr 2 corto 1 nopulito 4 " ]'
ok "  ...corto: solo le sue righe, non la coda di lungo ne' il thread di thr" 'grep -q "^Hunk #1 FAILED" "${PBL%.log}-corto-fallito.log" && ! grep -q "lungo riga\|thr" "${PBL%.log}-corto-fallito.log"'
ok "  ...thr: il log del suo thread" '[ "$(cat "${PBL%.log}-thr-fallito.log")" = "errore nel thread di thr" ]'
ok "  ...nopulito: fallito con l'uscita di clean, nel suo log" 'grep -q "^clean rotto" "${PBL%.log}-nopulito-fallito.log" && grep -q "^scripts/clean nopulito: uscita 4" "${PBL%.log}-nopulito-fallito.log"'
ok "  ...niente fallito.log per chi compila, nessun log per pacchetto rimasto" '[ ! -e "${PBL%.log}-lungo-fallito.log" ] && [ -z "$(ls "${PB}" | grep -v "fallito.log$" | grep "^build-rf35h-20261008-120000-")" ]'
ok "  ...il log comune ha tutto, in ordine" '[ "$(grep -c "^lungo riga" "${PBL}")" = 600 ] && [ "$(grep -n "^CLEAN lungo\|^CLEAN thr\|^Hunk #1\|^clean rotto" "${PBL}" | cut -d: -f2 | tr "\n" "|")" = "CLEAN lungo|CLEAN thr|Hunk #1 FAILED at 12.|clean rotto|" ]'

echo "core_why: il perche' di un core fallito, dal suo log"
# Le forme viste nella corsa dell'8/10/2026, dove per meta' dei falliti
# l'issue mostrava solo i banner "FAILED COMMAND"
eval "$(sed -n '/^core_why() {/,/^}/p' "${CB}")"
WY="${T}/why"; mkdir -p "${WY}"
printf '%s\n' "Applying patch x-001.patch" "patching file Makefile" \
	"Reversed (or previously applied) patch detected!  Skipping patch." \
	"1 out of 1 hunk ignored -- saving rejects to file Makefile.rej" \
	"*********** FAILED COMMAND ***********" 'cat ${i} | patch -d "${PKG_BUILD}" -p1' "**************************************" \
	"*********** FAILED COMMAND ***********" '${SCRIPTS}/unpack "${PKG_NAME}" "${PARENT_PKG}"' "**************************************" > "${WY}/patch.log"
core_why "${WY}/patch.log" > "${WY}/patch.out"
ok "patch gia' upstream: le righe di patch e il comando piu' interno" 'grep -q "^Reversed (or previously applied)" "${WY}/patch.out" && grep -q "^1 out of 1 hunk ignored" "${WY}/patch.out" && grep -qxF "comando: cat \${i} | patch -d \"\${PKG_BUILD}\" -p1" "${WY}/patch.out" && ! grep -q "FAILED COMMAND\|unpack" "${WY}/patch.out"'
printf '%s\n' "Executing (target): make -C src/burner/libretro" \
	"/work/b/toolchain/bin/aarch64-libreelec-linux-gnu-gcc -c -O2 -Wno-error -Werror=format-security src/a.c -o a.o" \
	"make: *** src/burner/libretro: No such file or directory.  Stop." \
	$'\e[1;31mFAILURE: scripts/build fbneo during make_target (package.mk)\e[0m' "" \
	"*********** FAILED COMMAND ***********" "make -C src/burner/libretro -j4" "**************************************" > "${WY}/make.log"
core_why "${WY}/make.log" > "${WY}/make.out"
ok "make senza la cartella: la riga di make, il passo senza colori, il comando" 'grep -qxF "make: *** src/burner/libretro: No such file or directory.  Stop." "${WY}/make.out" && grep -qxF "passo: scripts/build fbneo during make_target (package.mk)" "${WY}/make.out" && grep -qxF "comando: make -C src/burner/libretro -j4" "${WY}/make.out"'
ok "  ...non la riga di comando del compilatore (-Wno-error, -Werror=)" '! grep -q "toolchain/bin" "${WY}/make.out"'
printf '%s\n' "src/a.c:12:3: error: format not a string literal and no format arguments [-Werror=format-security]" \
	'  147 |      LOG_ERROR("Error running SQLite create_query: %d: %s\n", rc,' "      |      ^~~~~~~~~" \
	"[30/74] Building C object common/source/error.c.o" "deps/zstd/lib/common/error_private.o" \
	"make[1]: *** [Makefile:10: a.o] Error 1" "*********** FAILED COMMAND ***********" "make" > "${WY}/gcc.log"
core_why "${WY}/gcc.log" > "${WY}/gcc.out"
ok "errore di gcc marcato [-Werror=...]: c'e' (prima si scartava)" 'grep -q "^src/a.c:12:3: error: format not a string literal" "${WY}/gcc.out" && grep -qxF "make[1]: *** [Makefile:10: a.o] Error 1" "${WY}/gcc.out"'
ok "  ...senza il codice citato da gcc ne' i file che si chiamano error" '! grep -q "SQLite\|\^~\|error\.c\.o\|error_private" "${WY}/gcc.out"'
{ for i in $(seq 9); do echo "riga ${i}"; done; echo "FAILURE: scripts/build y during makeinstall_target (package.mk)"
  echo "*********** FAILED COMMAND ***********"; echo 'mkdir -p ${INSTALL}/usr/lib/libretro'; } > "${WY}/none.log"
core_why "${WY}/none.log" > "${WY}/none.out"
ok "nessun errore riconoscibile: le ultime 6 righe prima del banner, passo e comando" '[ "$(grep -c "^riga" "${WY}/none.out")" = 6 ] && grep -qx "riga 4" "${WY}/none.out" && grep -qx "riga 9" "${WY}/none.out" && grep -q "^(nessuna riga d.errore" "${WY}/none.out" && grep -qxF "passo: scripts/build y during makeinstall_target (package.mk)" "${WY}/none.out" && grep -qxF "comando: mkdir -p \${INSTALL}/usr/lib/libretro" "${WY}/none.out"'
printf 'error: %0300d\n' 0 > "${WY}/long.log"
ok "righe tagliate a 180 caratteri" '[ "$(core_why "${WY}/long.log" | awk "{ print length }" | sort -n | tail -1)" = 180 ]'

echo "cores-matrix e merge-cores (job cores in parallelo)"
M="$(bash "${REPO}/tools/ci-build.sh" cores-matrix "fceumm mame a b c d e f g h i j k l flycast m")"
ok "cores-matrix: i pesanti da soli e per primi, gli altri a gruppi di 12" '[ "${M}" = "{\"include\":[{\"g\":\"01\",\"cores\":\"mame\"},{\"g\":\"02\",\"cores\":\"flycast\"},{\"g\":\"03\",\"cores\":\"fceumm a b c d e f g h i j k\"},{\"g\":\"04\",\"cores\":\"l m\"}]}" ]'
ok "  ...JSON valido, nessun core perso" 'printf "%s" "${M}" | python3 -c "import json,sys; d=json.load(sys.stdin); c=\" \".join(x[\"cores\"] for x in d[\"include\"]).split(); sys.exit(0 if sorted(c)==sorted(\"fceumm mame a b c d e f g h i j k l flycast m\".split()) else 1)"'
ok "cores-matrix senza core: elenco vuoto" '[ "$(bash "${REPO}/tools/ci-build.sh" cores-matrix "")" = "{\"include\":[]}" ]'
MP="${T}/parts"; rm -rf "${MP}"; mkdir -p "${MP}/cores-9-01" "${MP}/cores-9-02"
printf 'core=mame commit=a\n' > "${MP}/cores-9-01/built.txt"; : > "${MP}/cores-9-01/failed.txt"
printf 'core=fceumm commit=b\n' > "${MP}/cores-9-02/built.txt"
printf '== mgba: fallito\nerror: x\n' > "${MP}/cores-9-02/failed.txt"
bash "${REPO}/tools/ci-build.sh" merge-cores "${MP}" "${T}/merged" "mame fceumm mgba snes9x" > /dev/null; rc=$?
ok "merge-cores: riusciti e falliti dei job in una cartella" '[ "${rc}" = 0 ] && [ "$(grep -c "^core=" "${T}/merged/built.txt")" = 2 ] && grep -q "^core=mame " "${T}/merged/built.txt" && grep -q "^== mgba: fallito" "${T}/merged/failed.txt"'
ok "  ...il core del job morto senza risultato va fra i falliti" 'grep -q "^== snes9x: nessun risultato" "${T}/merged/failed.txt" && ! grep -q "^== mame:" "${T}/merged/failed.txt"'
# un artifact solo: download-artifact lo scompatta direttamente nella cartella
M1="${T}/parts1"; rm -rf "${M1}"; mkdir -p "${M1}"
printf 'core=fceumm commit=b\ncore=mgba commit=c\n' > "${M1}/built.txt"; : > "${M1}/failed.txt"
bash "${REPO}/tools/ci-build.sh" merge-cores "${M1}" "${T}/merged1" "fceumm mgba" > /dev/null; rc=$?
ok "merge-cores con un artifact solo (file direttamente nella cartella)" '[ "${rc}" = 0 ] && [ "$(grep -c "^core=" "${T}/merged1/built.txt")" = 2 ] && [ ! -s "${T}/merged1/failed.txt" ]'

echo "issue-merge (job cores): l'issue dei falliti fra una corsa e l'altra"
IM="${T}/im"; mkdir -p "${IM}"
printf '== easyrpg: easyrpg fallito (uscita 1) [run 1]\nHunk #1 FAILED at 1430.\n== hatari: hatari fallito (uscita 2) [run 1]\nmake: *** No rule to make target\n== mgba_fork: mgba_fork fallito (uscita 2) [run 1]\n' > "${IM}/old"
printf '== easyrpg: easyrpg fallito (uscita 2) [run 2]\nerror: x\n== dosbox: dosbox fallito (uscita 2) [run 2]\n' > "${IM}/failed"
bash "${CB}" issue-merge "${IM}/old" "${IM}/failed" "easyrpg mgba_fork dosbox fbneo" > "${IM}/out"; rc=$?
ok "issue-merge: provati ora coi motivi nuovi, i riusciti fuori, gli altri come erano" '[ "${rc}" = 0 ] && [ "$(grep "^==" "${IM}/out" | sed "s/^== //; s/:.*//" | tr "\n" " ")" = "hatari easyrpg dosbox " ] && grep -q "^make: \*\*\* No rule" "${IM}/out" && ! grep -q "1430" "${IM}/out" && grep -q "^error: x" "${IM}/out"'
: > "${IM}/vuoto"; : > "${IM}/nessuno"
bash "${CB}" issue-merge "${IM}/old" "${IM}/nessuno" "easyrpg hatari mgba_fork" > "${IM}/out2"
ok "  ...tutti provati e compilati: elenco vuoto (si chiude)" '[ ! -s "${IM}/out2" ]'
bash "${CB}" issue-merge "${IM}/vuoto" "${IM}/failed" "easyrpg dosbox" > "${IM}/out3"
ok "  ...senza issue aperta: i falliti di questa corsa" 'cmp -s "${IM}/out3" "${IM}/failed"'
bash "${CB}" issue-merge "${IM}/old" "${IM}/nessuno" "fceumm" > "${IM}/out4"
ok "  ...una corsa che non tocca i falliti non li toglie (prima chiudeva l'issue)" 'cmp -s "${IM}/out4" "${IM}/old"'

if [ "${skip}" = 0 ]; then echo "--- ${pass} ok, ${fail} falliti"; else echo "--- ${pass} ok, ${fail} falliti, ${skip} parti saltate"; fi
[ "${fail}" = 0 ]
