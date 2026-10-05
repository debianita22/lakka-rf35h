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
case "$1 ${2:-}" in
	"rev-parse --short=7") echo "${FAKE_SHA:0:7}" ;;
	"rev-parse --is-shallow-repository") echo false ;;
	"rev-parse --verify")
		case "${4:-}" in HEAD^{commit}|"${FAKE_SHA}"^{commit}) echo "${FAKE_SHA}" ;; *) exit 1 ;; esac ;;
	"fetch "*) ;;
	"merge-base --is-ancestor") [ "${FAKE_ON_MAIN:-yes}" = yes ] ;;
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
	"api -X DELETE "*|"release create "*|"release upload "*|"release edit "*) ;;
	*) echo "gh finto: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "${FB}/git" "${FB}/gh"
SHA=0123456789abcdef0123456789abcdef01234567
export CALLS="${T}/calls.log"
# ci-build.sh <comando> con gh e git finti; uscita in run.out, output in out.txt
fake() {
	: > "${CALLS}"; : > "${T}/out.txt"
	( export PATH="${FB}:${PATH}" GITHUB_REPOSITORY=o/r DEFAULT_BRANCH=main GITHUB_SHA="${SHA}" \
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

if [ "${skip}" = 0 ]; then echo "--- ${pass} ok, ${fail} falliti"; else echo "--- ${pass} ok, ${fail} falliti, ${skip} parti saltate"; fi
[ "${fail}" = 0 ]
