#!/bin/bash
# test-rf35h-cores.sh - prove di rf35h-cores (core aggiornati uno per uno)
# senza device e senza rete: curl e df finti, /storage/cores e l'elenco dei
# core dell'immagine in una cartella temporanea, con la busybox se c'e'.
#
#   ./tools/test-rf35h-cores.sh [percorso/rf35h-cores]
#
# Le verifiche sono stringhe che ok() esegue con eval.
# shellcheck disable=SC2034
set -u
U="${1:-$(cd "$(dirname "$0")/.." && pwd)/packages/rf35h-utils/scripts/rf35h-cores}"
[ -f "${U}" ] || { echo "non trovo ${U}" >&2; exit 1; }
SH="sh"; command -v busybox >/dev/null && SH="busybox sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }

mkdir -p "${T}/bin" "${T}/web/o/r/releases/download/cores" "${T}/run" "${T}/storage"
cat > "${T}/bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--connect-timeout|--max-time|--retry) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
echo "${url}" >> "${FAKE_LOG}"
[ -n "${FAKE_FAIL:-}" ] && exit "${FAKE_FAIL}"
path="${FAKE_WEB}/$(echo "${url}" | sed 's|^https://[^/]*/||')"
[ -f "${path}" ] || exit 22
cat "${path}" > "${out}"
EOF
cat > "${T}/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/mmcblk0p2 100000000 1 ${FAKE_FREE_KB:-50000000} 1% /storage"
EOF
chmod +x "${T}/bin/curl" "${T}/bin/df"
if [ "${SH}" = "busybox sh" ]; then
	mkdir -p "${T}/bb"
	for a in awk sed ls cut head tail cat mkdir mv rm sync sleep sha256sum flock tr od gunzip grep date; do
		busybox --list 2>/dev/null | grep -qx "${a}" && ln -s "$(command -v busybox)" "${T}/bb/${a}"
	done
	PATH="${T}/bb:${PATH}"
fi
export PATH="${T}/bin:${PATH}" FAKE_LOG="${T}/curl.log" FAKE_WEB="${T}/web"
export RF35H_STATE_DIR="${T}/storage/.config/rf35h" RF35H_CORES_DIR="${T}/storage/cores"
export RF35H_IMAGE_CORES="${T}/image-cores.txt" RF35H_UPDATE_REPO_FILE="${T}/update-repo"
export RF35H_NTP_SYNCED="${T}/run/synced" RF35H_CORES_LOCK="${T}/run/lock" RF35H_CLOCK_WAIT=0
touch "${T}/run/synced"; echo "o/r" > "${T}/update-repo"
SD="${RF35H_STATE_DIR}"; CD="${RF35H_CORES_DIR}"; META="${CD}/.rf35h"; W="${T}/web/o/r/releases/download/cores"
LK="e2cf2e5cc3bdbb274aac5e3b6849549f6995dca3"
A="aaaaaaa000000000000000000000000000000001"; B="bbbbbbb000000000000000000000000000000002"
C="ccccccc000000000000000000000000000000003"; D="ddddddd000000000000000000000000000000004"
cat > "${RF35H_IMAGE_CORES}" <<EOF
lakka=${LK}
fceumm https://github.com/libretro/libretro-fceumm ${A}
beetle_pce_fast https://github.com/libretro/beetle-pce-fast-libretro ${C}
mgba https://github.com/mgba-emu/mgba ${B}
EOF
# un .so finto ma ELF aarch64 (e_ident, ET_DYN, EM_AARCH64)
mkso() {
	{
		printf '\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\x00\xb7\x00\x01\x00\x00\x00'
		printf '%s' "$1"
	} > "$2"
}
# un asset nella release finta: core, so, commit, contenuto -> riga dell'indice
asset() {   # core so commit contenuto [lakka]
	f="${W}/$2_libretro-$(printf '%.7s' "$3").so.gz"
	mkso "$4" "${T}/tmp.so"; gzip -n -c "${T}/tmp.so" > "${f}"
	echo "core=$1 so=$2 commit=$3 site=https://github.com/x/$1 file=${f##*/} url=https://github.com/o/r/releases/download/cores/${f##*/} sha256=$(sha256sum "${f}" | cut -d' ' -f1) size=$(wc -c < "${f}") lakka=${5:-${LK}} sysroot=v1.2.0 date=20261005"
}
rc_cores() { ${SH} "${U}" "$@" > "${T}/out.txt" 2> "${T}/err.txt"; echo $?; }
st() { awk -v c="$1" '$1 == c { st = $3; for (i = 4; i <= NF; i++) st = st " " $i; print st }' "${SD}/cores.status"; }

echo "rf35h-cores: ${U}  (con ${SH})"

echo "-- indice e stato"
{
	asset fceumm fceumm "${D}" "fceumm-new"            # aggiornamento disponibile
	asset mgba mgba "${B}" "mgba-same"                 # stesso commit dell'immagine
	asset beetle_pce_fast mednafen_pce_fast "${D}" "pce-other-lakka" "0000000000000000000000000000000000000000"   # altro Lakka
	asset snes9x snes9x "${A}" "snes9x"                # non nell'immagine
	echo "core=bad so=../x commit=zz file=x url=http://x sha256=1 size=1 lakka=${LK}"
} > "${W}/index.txt"
rc="$(rc_cores refresh)"
ok "refresh: indice scaricato, righe cattive scartate" '[ "${rc}" = 0 ] && [ "$(grep -c "^core=" "${SD}/cores.index")" = 4 ] && ! grep -q "core=bad" "${SD}/cores.index"'
ok "stato: fceumm available, mgba image, beetle needs system update, snes9x (non nell'immagine) available" '[ "$(st fceumm)" = "available ddddddd" ] && [ "$(st mgba)" = "image bbbbbbb" ] && [ "$(st beetle_pce_fast)" = "needs system update" ] && [ "$(st snes9x)" = "available aaaaaaa" ]'
ok "list: una riga per core, 4" '[ "$(${SH} "${U}" list | wc -l)" = 4 ]'
ok "status <core>: solo lo stato" '[ "$(${SH} "${U}" status fceumm)" = "available ddddddd" ]'

echo "-- update"
rc="$(rc_cores update fceumm)"
ok "update fceumm: installato in /storage/cores con .ver" '[ "${rc}" = 0 ] && [ -f "${CD}/fceumm_libretro.so" ] && grep -q "fceumm-new" "${CD}/fceumm_libretro.so" && [ "$(sed -n "s/^commit=//p" "${META}/fceumm.ver")" = "${D}" ] && grep -q "^lakka=${LK}" "${META}/fceumm.ver"'
ok "  ...stato updated, niente file a meta'" '[ "$(st fceumm)" = "updated ddddddd" ] && [ -z "$(ls "${META}"/*.part "${CD}"/*.new 2>/dev/null)" ]'
rc="$(rc_cores update fceumm)"
ok "update di nuovo: gia' a quella versione, nessun download" '[ "${rc}" = 0 ] && [ "$(grep -c "fceumm_libretro-ddddddd" "${FAKE_LOG}")" = 1 ]'
rc="$(rc_cores update mgba)"
ok "update mgba: l'immagine ha gia' quel commit, niente da fare" '[ "${rc}" = 0 ] && [ ! -f "${CD}/mgba_libretro.so" ] && [ "$(st mgba)" = "image bbbbbbb" ]'
rc="$(rc_cores update beetle_pce_fast)"
ok "update di un core per un altro Lakka: rifiutato" '[ "${rc}" = 1 ] && [ ! -f "${CD}/mednafen_pce_fast_libretro.so" ] && [ "$(st beetle_pce_fast)" = "needs system update" ]'
rc="$(rc_cores update "x;rm")"
ok "nome non valido: rifiutato" '[ "${rc}" = 1 ]'
rc="$(rc_cores update nonexistent)"
ok "core non nell'indice: error nello stato" '[ "${rc}" = 1 ] && [ "$(st nonexistent)" = "error: not in the index" ]'

echo "-- verifiche sul file"
{ asset fceumm fceumm "${C}" "fceumm-c"; asset mgba mgba "${D}" "mgba-d"; asset snes9x snes9x "${A}" "snes9x"; } > "${W}/index.txt"
sed -i "s/^\(core=fceumm .*sha256=\)[0-9a-f]*/\1$(printf '0%.0s' $(seq 64))/" "${W}/index.txt"
rc="$(rc_cores update-all)"
ok "sha256 sbagliato: errore, il core di prima resta" '[ "${rc}" = 1 ] && [ "$(st fceumm)" = "error: checksum mismatch, try again" ] && grep -q "fceumm-new" "${CD}/fceumm_libretro.so"'
ok "  ...mgba intanto aggiornato (update-all prosegue)" '[ "$(st mgba)" = "updated ddddddd" ] && [ -f "${CD}/mgba_libretro.so" ]'
{ asset fceumm fceumm "${C}" "fceumm-c"; asset mgba mgba "${D}" "mgba-d"; } > "${W}/index.txt"
printf 'not a core' | gzip -n -c > "${W}/fceumm_libretro-ccccccc.so.gz"
sed -i "s/^\(core=fceumm .*sha256=\)[0-9a-f]*\( size=\)[0-9]*/\1$(sha256sum "${W}/fceumm_libretro-ccccccc.so.gz" | cut -d' ' -f1)\2$(wc -c < "${W}/fceumm_libretro-ccccccc.so.gz")/" "${W}/index.txt"
${SH} "${U}" refresh >/dev/null 2>&1; rc="$(rc_cores update fceumm)"
ok "non un ELF: errore, il core di prima resta" '[ "${rc}" = 1 ] && [ "$(st fceumm)" = "error: corrupt core file" ] && grep -q "fceumm-new" "${CD}/fceumm_libretro.so"'
asset fceumm fceumm "${C}" "fceumm-c" > /dev/null
{ asset fceumm fceumm "${C}" "fceumm-c"; asset mgba mgba "${D}" "mgba-d"; } > "${W}/index.txt"
${SH} "${U}" refresh >/dev/null 2>&1
rc="$(FAKE_FREE_KB=10 rc_cores update fceumm)"
ok "spazio insufficiente: errore" '[ "${rc}" = 1 ] && [ "$(st fceumm)" = "error: not enough space in /storage" ]'
rc="$(FAKE_FAIL=7 rc_cores update fceumm)"
ok "rete assente: error no network" '[ "${rc}" = 1 ] && [ "$(st fceumm)" = "error: no network" ]'
rc="$(rc_cores update fceumm)"
ok "poi va: aggiornato a ccccccc, la versione di prima in .prev" '[ "${rc}" = 0 ] && grep -q "fceumm-c" "${CD}/fceumm_libretro.so" && grep -q "fceumm-new" "${META}/fceumm.so.prev" && [ "$(sed -n "s/^commit=//p" "${META}/fceumm.ver.prev")" = "${D}" ]'

echo "-- rollback, reset, custom"
rc="$(rc_cores rollback fceumm)"
ok "rollback: torna ddddddd" '[ "${rc}" = 0 ] && grep -q "fceumm-new" "${CD}/fceumm_libretro.so" && [ "$(st fceumm)" = "available ccccccc" ]'
rc="$(rc_cores reset fceumm)"
ok "reset fceumm: via l'override, stato image" '[ "${rc}" = 0 ] && [ ! -f "${CD}/fceumm_libretro.so" ] && [ ! -f "${META}/fceumm.ver" ] && [ "$(st fceumm)" = "available ccccccc" ]'
echo custom > "${CD}/mgba_libretro.so"; rm -f "${META}/mgba.ver"
${SH} "${U}" refresh >/dev/null 2>&1; rc="$(rc_cores update mgba)"
ok "un .so non nostro in /storage/cores: custom, non toccato" '[ "${rc}" = 1 ] && [ "$(st mgba)" = "custom" ] && [ "$(cat "${CD}/mgba_libretro.so")" = custom ]'
rm -f "${CD}/mgba_libretro.so"

echo "-- boot"
${SH} "${U}" update fceumm mgba >/dev/null 2>&1
ok "due override installati" '[ -f "${META}/fceumm.ver" ] && [ -f "${META}/mgba.ver" ]'
# l'immagine ora ha fceumm a C (stesso dell'override) e un altro Lakka
cat > "${RF35H_IMAGE_CORES}" <<EOF
lakka=1111111111111111111111111111111111111111
fceumm https://github.com/libretro/libretro-fceumm ${C}
mgba https://github.com/mgba-emu/mgba ${B}
EOF
touch "${META}/x.so.gz.part" "${CD}/y_libretro.so.new"
rc="$(rc_cores boot)"
ok "boot dopo un aggiornamento di sistema: override dell'altro Lakka via, file a meta' via" '[ "${rc}" = 0 ] && [ ! -f "${CD}/fceumm_libretro.so" ] && [ ! -f "${CD}/mgba_libretro.so" ] && [ ! -f "${META}/x.so.gz.part" ] && [ ! -f "${CD}/y_libretro.so.new" ]'
cat > "${RF35H_IMAGE_CORES}" <<EOF
lakka=${LK}
fceumm https://github.com/libretro/libretro-fceumm ${C}
mgba https://github.com/mgba-emu/mgba ${B}
EOF
${SH} "${U}" refresh >/dev/null 2>&1; ${SH} "${U}" update fceumm mgba >/dev/null 2>&1
rc="$(rc_cores boot)"
ok "boot, stesso Lakka: l'override di fceumm (= commit dell'immagine) via, mgba resta" '[ "${rc}" = 0 ] && [ ! -f "${CD}/fceumm_libretro.so" ] && [ -f "${CD}/mgba_libretro.so" ] && [ "$(st fceumm)" = "image ccccccc" ] && [ "$(st mgba)" = "updated ddddddd" ]'

echo "-- coda del menu (run)"
${SH} "${U}" reset all >/dev/null 2>&1
printf 'refresh\nmgba\n' > "${SD}/cores.queue"
rc="$(rc_cores run)"
ok "run: refresh e update dalla coda, coda svuotata" '[ "${rc}" = 0 ] && [ -f "${CD}/mgba_libretro.so" ] && [ ! -f "${CD}/fceumm_libretro.so" ] && [ ! -f "${SD}/cores.queue" ]'
echo all > "${SD}/cores.queue"; ${SH} "${U}" reset all >/dev/null 2>&1
rc="$(rc_cores run)"
ok "run con all: tutti gli available (mgba; fceumm e' gia' quello dell'immagine)" '[ "${rc}" = 0 ] && [ -f "${CD}/mgba_libretro.so" ] && [ ! -f "${CD}/fceumm_libretro.so" ] && [ "$(st mgba)" = "updated ddddddd" ]'
rc="$(rc_cores run)"
ok "run senza coda: solo lo stato, esce 0" '[ "${rc}" = 0 ]'
rc="$(FAKE_FAIL=7 rc_cores refresh)"
ok "refresh senza rete: esce 2, stato di prima tenuto" '[ "${rc}" = 2 ] && [ "$(st mgba)" = "updated ddddddd" ] && grep -q "no network" "${SD}/cores.error"'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
