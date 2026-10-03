#!/bin/bash
# test-rf35h-update.sh - prove di rf35h-update (aggiornamento di sistema) senza
# device e senza rete: curl e df finti, /storage, /etc/os-release, la batteria
# e le cartelle dei core in una cartella temporanea.
#
#   ./tools/test-rf35h-update.sh [percorso/rf35h-update]
#
# curl finto: serve i file di ${T}/web, il percorso e' quello dell'URL senza
# schema ne' host; ogni chiamata finisce in ${T}/curl.log. FAKE_FAIL=<codice>
# lo fa uscire con quel codice, FAKE_SLOW=1 scrive piano i .tar (per lo stop).
# Le verifiche sono stringhe che ok() esegue con eval: le variabili lette solo
# li' dentro shellcheck non le vede usate.
# shellcheck disable=SC2034
set -u
U="${1:-$(cd "$(dirname "$0")/.." && pwd)/packages/rf35h-utils/scripts/rf35h-update}"
[ -f "${U}" ] || { echo "non trovo ${U}" >&2; exit 1; }
SH="sh"; command -v busybox >/dev/null && SH="busybox sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }

mkdir -p "${T}/bin" "${T}/web/o/r/releases/latest/download" "${T}/web/o/r/releases/download/v1.1.0" \
         "${T}/web/o/r/releases/download/v1.2.0-rc1" "${T}/ps/battery" "${T}/run"
cat > "${T}/bin/curl" <<'EOF'
#!/bin/sh
out=""; resume=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		-C) resume="$2"; shift 2 ;;
		--connect-timeout|--max-time|--retry|--speed-limit|--speed-time) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
echo "${url} resume=${resume}" >> "${FAKE_LOG}"
[ -n "${FAKE_FAIL:-}" ] && exit "${FAKE_FAIL}"
path="${FAKE_WEB}/$(echo "${url}" | sed 's|^https://[^/]*/||')"
[ -f "${path}" ] || exit 22
if [ "${resume}" = "-" ] && [ -f "${out}" ]; then
	have=$(wc -c < "${out}")
	tail -c +$((have + 1)) "${path}" >> "${out}"
elif [ -n "${FAKE_SLOW:-}" ] && [ "${url%.tar}" != "${url}" ]; then
	: > "${out}"
	while :; do head -c 1024 "${path}" >> "${out}"; sleep 1; done
else
	cat "${path}" > "${out}"
fi
EOF
# df finto: lo spazio libero lo decide FAKE_FREE_KB
cat > "${T}/bin/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/mmcblk0p2 100000000 1 ${FAKE_FREE_KB:-50000000} 1% /storage"
EOF
chmod +x "${T}/bin/curl" "${T}/bin/df"

export PATH="${T}/bin:${PATH}" FAKE_LOG="${T}/curl.log" FAKE_WEB="${T}/web"
export RF35H_STATE_DIR="${T}/storage/.config/rf35h" RF35H_UPDATE_DIR="${T}/storage/.update"
export RF35H_OS_RELEASE="${T}/os-release" RF35H_UPDATE_REPO_FILE="${T}/update-repo"
export RF35H_PS_DIR="${T}/ps" RF35H_NTP_SYNCED="${T}/run/synced" RF35H_UPDATE_LOCK="${T}/run/lock"
export RF35H_LIBRETRO_DIR="${T}/libretro" RF35H_RA_SYSTEM_DIR="${T}/rasystem" RF35H_STORAGE="${T}/storage"
export RF35H_CLOCK_WAIT=0
touch "${T}/run/synced"
echo "o/r" > "${T}/update-repo"
echo 'VERSION="v1.0.0"' > "${T}/os-release"
echo Battery > "${T}/ps/battery/type"; echo 80 > "${T}/ps/battery/capacity"; echo Discharging > "${T}/ps/battery/status"

TAR="Lakka-RK3326.aarch64-Next-v1.1.0-rf35h.tar"
head -c 300000 /dev/urandom > "${T}/web/o/r/releases/download/v1.1.0/${TAR}"
SHA="$(sha256sum "${T}/web/o/r/releases/download/v1.1.0/${TAR}" | cut -d' ' -f1)"
info() {   # version tar sha size [url]
	printf 'version=%s\ntar=%s\nurl=%s\nsha256=%s\nsize=%s\n' "$1" "$2" \
		"${5:-https://github.com/o/r/releases/download/$1/$2}" "$3" "$4" \
		> "${T}/web/o/r/releases/latest/download/update.txt"
}
u() { ${SH} "${U}" "$@" 2>/dev/null; }
st() { cat "${RF35H_STATE_DIR}/update.status" 2>/dev/null; }
reset() { rm -rf "${T}/storage" "${T}/curl.log" "${T}/libretro" "${T}/rasystem"; unset FAKE_FAIL FAKE_SLOW FAKE_FREE_KB; }

echo "rf35h-update: ${U}  (con ${SH})"

reset; info v1.0.0 "${TAR}" "${SHA}" 300000
u run; rc=$?
ok "gia' aggiornata: up to date, niente download" '[ ${rc} = 0 ] && [ "$(st)" = "up to date (v1.0.0)" ] && [ ! -e "${RF35H_UPDATE_DIR}/${TAR}" ] && [ "$(grep -c "\.tar" "${T}/curl.log")" = 0 ]'
u check; rc=$?
ok "check senza aggiornamenti: esce 1" '[ ${rc} = 1 ]'
ok "status: la riga del menu" '[ "$(u status)" = "up to date (v1.0.0)" ]'
rm -f "${RF35H_STATE_DIR}/update.status"
ok "status senza file: la versione installata" '[ "$(u status)" = "installed: v1.0.0" ]'
ok "update.txt dal repository di update-repo, latest" 'grep -q "^https://github.com/o/r/releases/latest/download/update.txt" "${T}/curl.log"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
u check; rc=$?
ok "check con una versione nuova: esce 0" '[ ${rc} = 0 ]'
mkdir -p "${RF35H_UPDATE_DIR}"; echo vecchio > "${RF35H_UPDATE_DIR}/Lakka-vecchio.tar"; echo x > "${RF35H_UPDATE_DIR}/altro.img.gz"
u run; rc=$?
ok "aggiornamento: scaricato, verificato, pronto" '[ ${rc} = 0 ] && cmp -s "${RF35H_UPDATE_DIR}/${TAR}" "${T}/web/o/r/releases/download/v1.1.0/${TAR}" && [ "$(st)" = "ready: v1.1.0, select to restart and install" ]'
ok "  ...update.ready dice quale file" '[ "$(cat "${RF35H_STATE_DIR}/update.ready")" = "${RF35H_UPDATE_DIR}/${TAR}" ]'
ok "  ...un solo aggiornamento in .update (i vecchi tolti, niente .part)" '[ "$(ls "${RF35H_UPDATE_DIR}")" = "${TAR}" ]'
: > "${T}/curl.log"; u run
ok "  ...rilanciato da pronto: niente rete, resta pronto" '[ ! -s "${T}/curl.log" ] && [ "$(st)" = "ready: v1.1.0, select to restart and install" ]'
u cancel >/dev/null
ok "cancel: tolti il .tar e update.ready" '[ ! -e "${RF35H_UPDATE_DIR}/${TAR}" ] && [ ! -e "${RF35H_STATE_DIR}/update.ready" ] && [ "$(st)" = cancelled ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
mkdir -p "${RF35H_UPDATE_DIR}"; head -c 120000 "${T}/web/o/r/releases/download/v1.1.0/${TAR}" > "${RF35H_UPDATE_DIR}/${TAR}.part"
u run
ok "ripresa: un .part a meta' riprende con -C -" 'grep -q "${TAR} resume=-" "${T}/curl.log" && cmp -s "${RF35H_UPDATE_DIR}/${TAR}" "${T}/web/o/r/releases/download/v1.1.0/${TAR}"'

reset; info v1.1.0 "${TAR}" "$(printf '%064d' 0)" 300000
u run; rc=$?
ok "sha256 sbagliato: errore, file tolto, niente pronto" '[ ${rc} != 0 ] && [ "$(st)" = "error: checksum mismatch, deleted: try again" ] && [ -z "$(ls "${RF35H_UPDATE_DIR}")" ] && [ ! -e "${RF35H_STATE_DIR}/update.ready" ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 299999
u run; rc=$?
ok "dimensione sbagliata: errore, file tolto" '[ ${rc} != 0 ] && grep -q "^error: wrong size" "${RF35H_STATE_DIR}/update.status" && [ -z "$(ls "${RF35H_UPDATE_DIR}")" ]'

for bad in "../../etc/x.tar" "x.img" ".hidden.tar" "a b.tar"; do
	reset; info v1.1.0 "${bad}" "${SHA}" 300000
	u run; rc=$?
	ok "update.txt rifiutato: tar='${bad}'" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${RF35H_STATE_DIR}/update.status"'
done
reset; info v1.1.0 "${TAR}" "${SHA}" 300000 "http://example.com/${TAR}"
u run; rc=$?
ok "update.txt rifiutato: url non https" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${RF35H_STATE_DIR}/update.status"'
reset; info 'v1.1.0;rm' "${TAR}" "${SHA}" 300000
u run; rc=$?
ok "update.txt rifiutato: version con caratteri strani" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${RF35H_STATE_DIR}/update.status"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
echo 20 > "${T}/ps/battery/capacity"
u run; rc=$?
ok "batteria al 20% e scollegata: rifiuta, niente download" '[ ${rc} != 0 ] && [ "$(st)" = "error: battery at 20%: charge it or plug it in" ] && ! grep -q "\.tar" "${T}/curl.log"'
echo Charging > "${T}/ps/battery/status"; u run
ok "  ...al 20% ma in carica: procede" '[ "$(st)" = "ready: v1.1.0, select to restart and install" ]'
echo 80 > "${T}/ps/battery/capacity"; echo Discharging > "${T}/ps/battery/status"

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FREE_KB=500
u run; rc=$?
ok "spazio insufficiente: errore con i MB che servono" '[ ${rc} != 0 ] && grep -q "^error: not enough space in /storage: [0-9]* MB needed" "${RF35H_STATE_DIR}/update.status"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FAIL=6
u run
ok "senza rete: no network" '[ "$(st)" = "error: no network" ]'
reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FAIL=60
u run
ok "certificato rifiutato: rimanda all'ora di rete" 'grep -q "^error: secure connection failed: is the clock right" "${RF35H_STATE_DIR}/update.status"'

reset; mkdir -p "${RF35H_STATE_DIR}"; echo "TAG=v1.2.0-rc1" > "${RF35H_STATE_DIR}/update.conf"
u check
ok "update.conf TAG: quella release, non latest" 'grep -q "^https://github.com/o/r/releases/download/v1.2.0-rc1/update.txt" "${T}/curl.log"'
echo "REPO=altro/fork" > "${RF35H_STATE_DIR}/update.conf"; : > "${T}/curl.log"; u check
ok "update.conf REPO: un altro repository" 'grep -q "^https://github.com/altro/fork/releases/latest/download/update.txt" "${T}/curl.log"'

# re3 (GTA III) da una build personale: copiato in /storage prima di finire
reset; info v1.1.0 "${TAR}" "${SHA}" 300000
mkdir -p "${T}/libretro" "${T}/rasystem/re3/gamefiles"
echo core > "${T}/libretro/re3_libretro.so"; echo info > "${T}/libretro/re3_libretro.info"; echo g > "${T}/rasystem/re3/gamefiles/x"
u run
ok "re3 nell'immagine: copiato in storage/cores e storage/system" '[ -f "${T}/storage/cores/re3_libretro.so" ] && [ -f "${T}/storage/cores/re3_libretro.info" ] && [ -f "${T}/storage/system/re3/gamefiles/x" ] && [ "$(cat "${RF35H_STATE_DIR}/re3-preserved")" = system ]'
rm -f "${RF35H_UPDATE_DIR}/${TAR}"; rm -rf "${T}/libretro"
u boot
ok "boot dopo l'aggiornamento (re3 non piu' nell'immagine): copie tenute" '[ -f "${T}/storage/cores/re3_libretro.so" ] && [ -e "${RF35H_STATE_DIR}/re3-preserved" ]'
ok "  ...e lo stato pronto, col .tar consumato dall'init, tolto" '[ ! -e "${RF35H_STATE_DIR}/update.ready" ] && [ ! -e "${RF35H_STATE_DIR}/update.status" ]'
mkdir -p "${T}/libretro"; echo core2 > "${T}/libretro/re3_libretro.so"
u boot
ok "boot con re3 di nuovo nell'immagine: copie e marcatore tolti" '[ ! -e "${T}/storage/cores/re3_libretro.so" ] && [ ! -e "${T}/storage/system/re3" ] && [ ! -e "${RF35H_STATE_DIR}/re3-preserved" ]'
reset; mkdir -p "${T}/storage/cores" "${RF35H_STATE_DIR}"; echo mio > "${T}/storage/cores/re3_libretro.so"
mkdir -p "${T}/libretro"; echo core > "${T}/libretro/re3_libretro.so"
u boot
ok "boot: un re3 messo a mano (senza marcatore) non si tocca" '[ "$(cat "${T}/storage/cores/re3_libretro.so")" = mio ]'

# stop dal menu (systemctl stop = SIGTERM) durante il download
reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_SLOW=1
${SH} "${U}" run 2>/dev/null & pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; case "$(st)" in downloading*) break ;; esac; done
# systemctl stop manda SIGTERM a tutta la unit (KillMode=control-group): script e curl
kill -TERM "${pid}"; pkill -TERM -f "${T}/bin/curl" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "${pid}" 2>/dev/null || break; sleep 1; done
kill -9 "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
ok "stop durante il download: stato 'stopped', .part tenuto per riprendere" '[ "$(st)" = "stopped: select to resume the download" ] && [ -s "${RF35H_UPDATE_DIR}/${TAR}.part" ]'
unset FAKE_SLOW
u boot
ok "boot con un download fermato: lo stato resta (riprende al giro dopo)" '[ "$(st)" = "stopped: select to resume the download" ]'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
