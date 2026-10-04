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
# init_boot fa la parte dell'init di LibreELEC all'avvio: le stesse ricerche in
# /storage/.update e la stessa pulizia (vedi sotto).
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
# Con la busybox anche gli strumenti sono i suoi (awk, sed, ls...), come
# sulla console, e non quelli GNU dell'host
if [ "${SH}" = "busybox sh" ]; then
	mkdir -p "${T}/bb"
	for a in awk sed ls cut head tail cat mkdir mv rm rmdir sync sleep sha256sum flock ln wc tr; do
		busybox --list 2>/dev/null | grep -qx "${a}" && ln -s "$(command -v busybox)" "${T}/bb/${a}"
	done
	PATH="${T}/bb:${PATH}"
fi

export PATH="${T}/bin:${PATH}" FAKE_LOG="${T}/curl.log" FAKE_WEB="${T}/web"
export RF35H_STATE_DIR="${T}/storage/.config/rf35h" RF35H_UPDATE_DIR="${T}/storage/.update"
export RF35H_OS_RELEASE="${T}/os-release" RF35H_UPDATE_REPO_FILE="${T}/update-repo"
export RF35H_PS_DIR="${T}/ps" RF35H_NTP_SYNCED="${T}/run/synced" RF35H_UPDATE_LOCK="${T}/run/lock"
export RF35H_LIBRETRO_DIR="${T}/libretro" RF35H_RA_SYSTEM_DIR="${T}/rasystem" RF35H_STORAGE="${T}/storage"
export RF35H_CLOCK_WAIT=0
touch "${T}/run/synced"
echo "o/r" > "${T}/update-repo"
echo Battery > "${T}/ps/battery/type"
UD="${RF35H_UPDATE_DIR}"; STG="${UD}/.rf35h-staged"; SD="${RF35H_STATE_DIR}"

TAR="Lakka-RK3326.aarch64-Next-v1.1.0-rf35h.tar"
WTAR="${T}/web/o/r/releases/download/v1.1.0/${TAR}"
head -c 300000 /dev/urandom > "${WTAR}"
SHA="$(sha256sum "${WTAR}" | cut -d' ' -f1)"
info() {   # version tar sha size [url]
	printf 'version=%s\ntar=%s\nurl=%s\nsha256=%s\nsize=%s\n' "$1" "$2" \
		"${5:-https://github.com/o/r/releases/download/$1/$2}" "$3" "$4" \
		> "${T}/web/o/r/releases/latest/download/update.txt"
}
u() { ${SH} "${U}" "$@" 2>/dev/null; }
st() { cat "${SD}/update.status" 2>/dev/null; }
installed() { echo "VERSION=\"$1\"" > "${T}/os-release"; }
battery() { echo "$1" > "${T}/ps/battery/capacity"; echo "$2" > "${T}/ps/battery/status"; }
reset() {
	rm -rf "${T}/storage" "${T}/curl.log" "${T}/libretro" "${T}/rasystem"
	unset FAKE_FAIL FAKE_SLOW FAKE_FREE_KB
	installed v1.0.0; battery 80 Discharging
}
# L'init all'avvio (packages/sysutils/busybox/scripts/init di Lakka,
# check_update e do_cleanup): installa KERNEL+SYSTEM o il primo *.tar, *.img.gz
# o *.img in cima a .update, poi cancella quel file, .tmp e ogni voce di
# .update che comincia con lettera o cifra. init_sees dice cosa installerebbe.
init_sees() {
	if [ -f "${UD}/KERNEL" ] && [ -f "${UD}/SYSTEM" ]; then echo "${UD}/KERNEL"; return; fi
	ls -1 "${UD}"/*.tar "${UD}"/*.img.gz "${UD}"/*.img 2>/dev/null | head -n 1
}
init_boot() {   # ok|fail: com'e' andata l'installazione, se ce n'e' una
	f="$(init_sees)"
	[ -n "${f}" ] || return 0
	[ "$1" = ok ] && installed "$(sed -n 's/.*-\(v[0-9][^-]*\)-rf35h\.tar$/\1/p' <<< "${f##*/}")"
	rm -rf "${UD}"/[0-9a-zA-Z]* "${UD}/.tmp"
}

echo "rf35h-update: ${U}  (con ${SH})"

reset; info v1.0.0 "${TAR}" "${SHA}" 300000
u run; rc=$?
ok "gia' aggiornata: up to date, niente download" '[ ${rc} = 0 ] && [ "$(st)" = "up to date (v1.0.0)" ] && [ ! -e "${STG}/${TAR}" ] && [ "$(grep -c "\.tar" "${T}/curl.log")" = 0 ]'
u check; rc=$?
ok "check senza aggiornamenti: esce 1" '[ ${rc} = 1 ]'
ok "status: la riga del menu" '[ "$(u status)" = "up to date (v1.0.0)" ]'
rm -f "${SD}/update.status"
ok "status senza file: la versione installata" '[ "$(u status)" = "installed: v1.0.0" ]'
ok "update.txt dal repository di update-repo, latest" 'grep -q "^https://github.com/o/r/releases/latest/download/update.txt" "${T}/curl.log"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
u check; rc=$?
ok "check con una versione nuova: esce 0" '[ ${rc} = 0 ]'
mkdir -p "${UD}"; echo vecchio > "${UD}/Lakka-vecchio.tar"; echo x > "${UD}/altro.img.gz"
u run; rc=$?
ok "aggiornamento: scaricato, verificato, pronto" '[ ${rc} = 0 ] && cmp -s "${STG}/${TAR}" "${WTAR}" && [ "$(st)" = "ready: v1.1.0, select to restart and install" ]'
ok "  ...update.ready dice quale file (e la versione)" '[ "$(sed -n 1p "${SD}/update.ready")" = "${STG}/${TAR}" ] && [ "$(sed -n 2p "${SD}/update.ready")" = v1.1.0 ]'
ok "  ...un solo aggiornamento in .update (i vecchi tolti, niente .part)" '[ -z "$(ls "${UD}")" ] && [ "$(ls "${STG}")" = "${TAR}" ]'
ok "  ...da parte: l'init al riavvio non lo vede" '[ -z "$(init_sees)" ]'
: > "${T}/curl.log"; u run
ok "  ...rilanciato da pronto: niente rete, resta pronto" '[ ! -s "${T}/curl.log" ] && [ "$(st)" = "ready: v1.1.0, select to restart and install" ]'
init_boot ok; u boot
ok "  ...un riavvio senza install: non installato, resta pronto" '[ "$(u status)" = "ready: v1.1.0, select to restart and install" ] && [ -f "${STG}/${TAR}" ] && grep -q v1.0.0 "${T}/os-release"'
u cancel >/dev/null
ok "cancel: tolti il .tar e update.ready" '[ ! -e "${STG}/${TAR}" ] && [ ! -e "${SD}/update.ready" ] && [ "$(st)" = cancelled ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
mkdir -p "${STG}"; head -c 120000 "${WTAR}" > "${STG}/${TAR}.part"
u run
ok "ripresa: un .part a meta' riprende con -C -" 'grep -q "${TAR} resume=-" "${T}/curl.log" && cmp -s "${STG}/${TAR}" "${WTAR}"'
reset; info v1.1.0 "${TAR}" "${SHA}" 300000
mkdir -p "${STG}"; cp "${WTAR}" "${STG}/${TAR}"
u run
ok "scaricato ma update.ready mai scritto (spenta li'): riverificato, niente download" '! grep -q "\.tar " "${T}/curl.log" && [ "$(st)" = "ready: v1.1.0, select to restart and install" ] && cmp -s "${STG}/${TAR}" "${WTAR}"'

reset; info v1.1.0 "${TAR}" "$(printf '%064d' 0)" 300000
u run; rc=$?
ok "sha256 sbagliato: errore, file tolto, niente pronto" '[ ${rc} != 0 ] && [ "$(st)" = "error: checksum mismatch, deleted: try again" ] && [ -z "$(ls "${UD}")" ] && [ -z "$(ls "${STG}")" ] && [ ! -e "${SD}/update.ready" ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 299999
u run; rc=$?
ok "dimensione sbagliata: errore, file tolto" '[ ${rc} != 0 ] && grep -q "^error: wrong size" "${SD}/update.status" && [ -z "$(ls "${UD}")" ] && [ -z "$(ls "${STG}")" ]'

for bad in "../../etc/x.tar" "x.img" ".hidden.tar" "a b.tar"; do
	reset; info v1.1.0 "${bad}" "${SHA}" 300000
	u run; rc=$?
	ok "update.txt rifiutato: tar='${bad}'" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${SD}/update.status"'
done
reset; info v1.1.0 "${TAR}" "${SHA}" 300000 "http://example.com/${TAR}"
u run; rc=$?
ok "update.txt rifiutato: url non https" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${SD}/update.status"'
reset; info 'v1.1.0;rm' "${TAR}" "${SHA}" 300000
u run; rc=$?
ok "update.txt rifiutato: version con caratteri strani" '[ ${rc} != 0 ] && grep -q "^error: invalid update.txt" "${SD}/update.status"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000
battery 20 Discharging
u run; rc=$?
ok "batteria al 20% e scollegata: rifiuta, niente download" '[ ${rc} != 0 ] && [ "$(st)" = "error: battery at 20%: charge it or plug it in" ] && ! grep -q "\.tar" "${T}/curl.log"'
battery 20 Charging; u run
ok "  ...al 20% ma in carica: procede" '[ "$(st)" = "ready: v1.1.0, select to restart and install" ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FREE_KB=500
u run; rc=$?
ok "spazio insufficiente: errore con i MB che servono" '[ ${rc} != 0 ] && grep -q "^error: not enough space in /storage: [0-9]* MB needed" "${SD}/update.status"'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FAIL=6
u run
ok "senza rete: no network" '[ "$(st)" = "error: no network" ]'
reset; info v1.1.0 "${TAR}" "${SHA}" 300000; export FAKE_FAIL=60
u run
ok "certificato rifiutato: rimanda all'ora di rete" 'grep -q "^error: secure connection failed: is the clock right" "${SD}/update.status"'

reset; mkdir -p "${SD}"; echo "TAG=v1.2.0-rc1" > "${SD}/update.conf"
u check
ok "update.conf TAG: quella release, non latest" 'grep -q "^https://github.com/o/r/releases/download/v1.2.0-rc1/update.txt" "${T}/curl.log"'
echo "REPO=altro/fork" > "${SD}/update.conf"; : > "${T}/curl.log"; u check
ok "update.conf REPO: un altro repository" 'grep -q "^https://github.com/altro/fork/releases/latest/download/update.txt" "${T}/curl.log"'

# re3 (GTA III) da una build personale: copiato in /storage prima di finire
reset; info v1.1.0 "${TAR}" "${SHA}" 300000
mkdir -p "${T}/libretro" "${T}/rasystem/re3/gamefiles"
echo core > "${T}/libretro/re3_libretro.so"; echo info > "${T}/libretro/re3_libretro.info"; echo g > "${T}/rasystem/re3/gamefiles/x"
u run
ok "re3 nell'immagine: copiato in storage/cores e storage/system" '[ -f "${T}/storage/cores/re3_libretro.so" ] && [ -f "${T}/storage/cores/re3_libretro.info" ] && [ -f "${T}/storage/system/re3/gamefiles/x" ] && [ "$(cat "${SD}/re3-preserved")" = system ]'
u install >/dev/null; init_boot ok; rm -rf "${T}/libretro"
u boot
ok "boot dopo l'aggiornamento (re3 non piu' nell'immagine): copie tenute" '[ -f "${T}/storage/cores/re3_libretro.so" ] && [ -e "${SD}/re3-preserved" ]'
ok "  ...e lo stato pronto, col .tar consumato dall'init, tolto" '[ ! -e "${SD}/update.ready" ] && [ ! -e "${SD}/update.status" ] && [ "$(u status)" = "installed: v1.1.0" ]'
mkdir -p "${T}/libretro"; echo core2 > "${T}/libretro/re3_libretro.so"
u boot
ok "boot con re3 di nuovo nell'immagine: copie e marcatore tolti" '[ ! -e "${T}/storage/cores/re3_libretro.so" ] && [ ! -e "${T}/storage/system/re3" ] && [ ! -e "${SD}/re3-preserved" ]'
reset; mkdir -p "${T}/storage/cores" "${SD}"; echo mio > "${T}/storage/cores/re3_libretro.so"
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
ok "stop durante il download: stato 'stopped', .part tenuto per riprendere" '[ "$(st)" = "stopped: select to resume the download" ] && [ -s "${STG}/${TAR}.part" ]'
unset FAKE_SLOW
# il "sleep 1" del curl finto ucciso ha ereditato il lock (sulla console
# systemctl stop uccide tutto il cgroup): si aspetta che lo lasci
for _ in 1 2 3 4 5; do flock -n "${RF35H_UPDATE_LOCK}" true 2>/dev/null && break; sleep 1; done
u boot
ok "boot con un download fermato: lo stato resta (riprende al giro dopo)" '[ "$(st)" = "stopped: select to resume the download" ]'

echo "-- install: la batteria al momento del riavvio"
reset; info v1.1.0 "${TAR}" "${SHA}" 300000; u run
out="$(u install)"; rc=$?
ok "install all'80%: esce 0, niente su stdout" '[ ${rc} = 0 ] && [ -z "${out}" ]'
ok "  ...il .tar in .update, dove l'init lo prende" '[ "$(init_sees)" = "${UD}/${TAR}" ] && cmp -s "${UD}/${TAR}" "${WTAR}" && [ -z "$(ls "${STG}" 2>/dev/null)" ]'
ok "  ...update.ready lo segue, il menu resta su pronto" '[ "$(sed -n 1p "${SD}/update.ready")" = "${UD}/${TAR}" ] && [ "$(u status)" = "ready: v1.1.0, select to restart and install" ]'
ok "  ...update.install: versione e file" '[ "$(cat "${SD}/update.install")" = "$(printf "v1.1.0\n%s" "${UD}/${TAR}")" ]'
out="$(u install)"; rc=$?
ok "  ...install di nuovo (senza riavvio): ancora 0" '[ ${rc} = 0 ] && [ "$(init_sees)" = "${UD}/${TAR}" ]'
init_boot ok; u boot
ok "  ...riavvio, l'init lo installa: installed v1.1.0, stato pulito" '[ "$(u status)" = "installed: v1.1.0" ] && [ ! -e "${SD}/update.ready" ] && [ ! -e "${SD}/update.install" ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; u run
battery 20 Discharging
out="$(u install)"; rc=$?
ok "install al 20% scollegata: esce 1, il motivo in una riga" '[ ${rc} = 1 ] && [ "${out}" = "battery at 20%: connect the charger" ]'
ok "  ...il .tar resta da parte: un riavvio non lo installa" '[ -z "$(init_sees)" ] && [ -f "${STG}/${TAR}" ] && [ ! -e "${SD}/update.install" ] && [ "$(u status)" = "ready: v1.1.0, select to restart and install" ]'
battery 20 Charging
out="$(u install)"; rc=$?
ok "install al 20% ma in carica: esce 0" '[ ${rc} = 0 ] && [ "$(init_sees)" = "${UD}/${TAR}" ]'
battery 100 Full; u cancel >/dev/null
ok "cancel dopo install: tolti .tar, update.ready e update.install" '[ -z "$(init_sees)" ] && [ ! -e "${SD}/update.ready" ] && [ ! -e "${SD}/update.install" ] && [ "$(st)" = cancelled ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; u run; export FAKE_FREE_KB=1000
out="$(u install)"; rc=$?
ok "install senza spazio per estrarlo: esce 1, resta da parte" '[ ${rc} = 1 ] && [ "${out}" = "not enough space in /storage: 100 MB needed" ] && [ -z "$(init_sees)" ]'
reset
out="$(u install)"; rc=$?
ok "install senza niente di pronto: esce 1, una riga" '[ ${rc} = 1 ] && [ -n "${out}" ] && [ "$(printf "%s\n" "${out}" | wc -l)" = 1 ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; u run; u install >/dev/null
init_boot fail; u boot
ok "installazione fallita (l'init cancella il .tar, gira la vecchia): detta nel menu" '[ "$(u status)" = "error: install of v1.1.0 failed: select to try again" ] && [ ! -e "${SD}/update.ready" ] && [ ! -e "${SD}/update.install" ]'
u boot
ok "  ...e resta detta al riavvio dopo" '[ "$(u status)" = "error: install of v1.1.0 failed: select to try again" ]'
: > "${T}/curl.log"; u run
ok "  ...select: si riscarica" 'grep -q "${TAR} " "${T}/curl.log" && [ "$(st)" = "ready: v1.1.0, select to restart and install" ]'

reset; info v1.1.0 "${TAR}" "${SHA}" 300000; u run
mkdir -p "${SD}"; printf 'v1.1.0\n%s\n' "${UD}/${TAR}" > "${SD}/update.install"; printf '%s\nv1.1.0\n' "${UD}/${TAR}" > "${SD}/update.ready"
init_boot ok; u boot
ok "spenta dentro install, prima di spostarlo: resta pronto, nessun errore" '[ "$(u status)" = "ready: v1.1.0, select to restart and install" ] && [ "$(sed -n 1p "${SD}/update.ready")" = "${STG}/${TAR}" ] && [ ! -e "${SD}/update.install" ]'
reset; mkdir -p "${SD}"; printf 'v1.0.0\n%s\n' "${UD}/Lakka-vecchio.tar" > "${SD}/update.install"
u boot
ok "update.install di un giro vecchio: ignorato, nessun errore" '[ "$(u status)" = "installed: v1.0.0" ] && [ ! -e "${SD}/update.install" ]'

echo "-- solo in avanti"
reset; info v1.1.0 "${TAR}" "${SHA}" 300000; installed v1.2.0
u run; rc=$?
ok "installata v1.2.0, ultima release v1.1.0: niente, niente download" '[ ${rc} = 0 ] && [ "$(st)" = "up to date (v1.2.0)" ] && ! grep -q "\.tar" "${T}/curl.log" && [ ! -e "${SD}/update.ready" ]'
u check >/dev/null; rc=$?
ok "  ...check esce 1" '[ ${rc} = 1 ]'
installed v1.1.0-rc1; u check >/dev/null; rc=$?
ok "installata v1.1.0-rc1, ultima v1.1.0: proposta (la pre-release viene prima)" '[ ${rc} = 0 ]'
installed v1.0.9; u check >/dev/null; rc=$?
ok "installata v1.0.9, ultima v1.1.0: proposta" '[ ${rc} = 0 ]'
installed v1.10.0; u check >/dev/null; rc=$?
ok "installata v1.10.0, ultima v1.1.0: no (numeri, non lettere)" '[ ${rc} = 1 ]'
installed devel-20261004120000-e2cf2e5; u check >/dev/null; rc=$?
ok "build personale (VERSION devel-...): l'ultima release, come prima" '[ ${rc} = 0 ]'
installed v1.0.0; info v1.1.0-rc2 "${TAR}" "${SHA}" 300000; u check >/dev/null; rc=$?
ok "installata v1.0.0, ultima v1.1.0-rc2: proposta" '[ ${rc} = 0 ]'
installed v1.1.0; u check >/dev/null; rc=$?
ok "installata v1.1.0, ultima v1.1.0-rc2: no" '[ ${rc} = 1 ]'
installed v1.0.0; info prova1 "${TAR}" "${SHA}" 300000; u check >/dev/null; rc=$?
ok "ultima release senza vX.Y.Z (prova1): no" '[ ${rc} = 1 ] && [ "$(st)" = "up to date (v1.0.0)" ]'

reset; installed v1.2.0; mkdir -p "${SD}"; echo "TAG=v1.1.0" > "${SD}/update.conf"
printf 'version=v1.1.0\ntar=%s\nurl=https://github.com/o/r/releases/download/v1.1.0/%s\nsha256=%s\nsize=300000\n' \
	"${TAR}" "${TAR}" "${SHA}" > "${T}/web/o/r/releases/download/v1.1.0/update.txt"
u run
ok "TAG=v1.1.0 in update.conf, installata v1.2.0: la vecchia, chiesta, si scarica" '[ "$(st)" = "ready: v1.1.0, select to restart and install" ] && cmp -s "${STG}/${TAR}" "${WTAR}"'
reset; installed v1.2.0; mkdir -p "${SD}"
echo "URL=https://github.com/o/r/releases/download/v1.1.0/update.txt" > "${SD}/update.conf"
u check >/dev/null; rc=$?
ok "URL= in update.conf: anche piu' vecchia" '[ ${rc} = 0 ]'

echo "-- dalla v1.0.0: .tar gia' in .update con update.ready"
v100() {   # quello che lascia la v1.0.0 dopo "run": update.ready di una riga
	reset; info v1.1.0 "${TAR}" "${SHA}" 300000
	mkdir -p "${UD}" "${SD}"; cp "${WTAR}" "${UD}/${TAR}"
	printf '%s\n' "${UD}/${TAR}" > "${SD}/update.ready"
	printf 'version=v1.1.0\ntar=%s\n' "${TAR}" > "${SD}/update.info"
	echo "ready: v1.1.0, select to restart and install" > "${SD}/update.status"
}
v100; : > "${T}/curl.log"; u run
ok "v1.0.0: run resta pronto, niente rete" '[ ! -s "${T}/curl.log" ] && [ "$(u status)" = "ready: v1.1.0, select to restart and install" ]'
out="$(u install)"; rc=$?
ok "v1.0.0: install esce 0, il .tar resta in .update" '[ ${rc} = 0 ] && [ "$(init_sees)" = "${UD}/${TAR}" ] && [ "$(head -1 "${SD}/update.install")" = v1.1.0 ]'
init_boot ok; u boot
ok "  ...riavvio: installata, stato pulito" '[ "$(u status)" = "installed: v1.1.0" ] && [ ! -e "${SD}/update.ready" ]'
v100; battery 15 Discharging
out="$(u install)"; rc=$?
ok "v1.0.0 con la batteria al 15%: esce 1 e il .tar va da parte" '[ ${rc} = 1 ] && [ "${out}" = "battery at 15%: connect the charger" ] && [ -z "$(init_sees)" ] && [ "$(sed -n 1p "${SD}/update.ready")" = "${STG}/${TAR}" ]'
battery 15 Charging; out="$(u install)"; rc=$?
ok "  ...in carica: di nuovo in .update" '[ ${rc} = 0 ] && [ "$(init_sees)" = "${UD}/${TAR}" ]'
v100; init_boot ok; u boot
ok "v1.0.0 riavviata senza install (il suo menu): installata, stato tolto come prima" '[ "$(u status)" = "installed: v1.1.0" ] && [ ! -e "${SD}/update.ready" ]'
v100; init_boot fail; u boot
ok "  ...fallita senza install: come prima, niente errore (nessuno l'ha chiesto)" '[ "$(u status)" = "installed: v1.0.0" ]'
v100; u cancel >/dev/null
ok "v1.0.0: cancel toglie il .tar" '[ -z "$(init_sees)" ] && [ ! -e "${SD}/update.ready" ]'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
