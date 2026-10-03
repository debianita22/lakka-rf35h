#!/bin/bash
# test-rf35h-ra-guard.sh - prove di rf35h-ra-guard (ripiego da Vulkan a gl per
# RetroArch) senza device: retroarch.cfg, /run e /storage/rf35h-logs finti,
# SERVICE_RESULT come lo passa systemd agli ExecStopPost.
#
#   ./tools/test-rf35h-ra-guard.sh [percorso/rf35h-ra-guard]
# Le verifiche sono stringhe che ok() esegue con eval: le variabili lette solo
# li' dentro (rc, n0, cp...) shellcheck non le vede usate.
# shellcheck disable=SC2034
set -u
G="${1:-$(cd "$(dirname "$0")/.." && pwd)/packages/rf35h-utils/scripts/rf35h-ra-guard}"
[ -f "${G}" ] || { echo "non trovo ${G}" >&2; exit 1; }
SH="sh"; command -v busybox >/dev/null && SH="busybox sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/run" "${T}/logs"
export RA_CFG="${T}/retroarch.cfg" RF35H_RUN="${T}/run" RF35H_LOGDIR="${T}/logs"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
g() { ${SH} "${G}" "$@" 2>/dev/null; }
fails() { g pre; SERVICE_RESULT=exit-code g post; }

echo "guardia: ${G}  (con ${SH})"
printf 'menu_driver = "xmb"\nvideo_driver = "gl"\n' > "${RA_CFG}"
g pre
ok "pre annota l'avvio" '[ -s "${T}/run/ra-start" ]'
SERVICE_RESULT=exit-code g post
ok "gl + crash: nessun intervento" 'grep -q "^video_driver = \"gl\"" "${RA_CFG}" && [ ! -e "${T}/run/ra-vkfail" ]'

sed -i 's/"gl"/"vulkan"/' "${RA_CFG}"; fails
ok "vulkan, 1a morte rapida: conta 1, cfg intatto" '[ "$(cat "${T}/run/ra-vkfail")" = 1 ] && grep -q "\"vulkan\"" "${RA_CFG}"'
g pre; SERVICE_RESULT=signal EXIT_CODE=killed EXIT_STATUS=SEGV g post
ok "vulkan, 2a morte rapida: torna gl, nota scritta" 'grep -q "^video_driver = \"gl\"" "${RA_CFG}" && grep -q "menu_driver = \"xmb\"" "${RA_CFG}" && ls "${T}"/logs/vulkan-fallback-*.txt >/dev/null 2>&1 && [ ! -e "${T}/run/ra-vkfail" ]'

sed -i 's/"gl"/"vulkan"/' "${RA_CFG}"; fails; g pre; SERVICE_RESULT=success g post
ok "uscita normale azzera il conto" '[ ! -e "${T}/run/ra-vkfail" ] && grep -q "\"vulkan\"" "${RA_CFG}"'

echo $(( $(date +%s) - 100 )) > "${T}/run/ra-start"; SERVICE_RESULT=exit-code g post
ok "morte dopo la finestra: niente conto" '[ ! -e "${T}/run/ra-vkfail" ] && grep -q "\"vulkan\"" "${RA_CFG}"'

printf 'video_driver="vulkan"\n' > "${RA_CFG}"; fails; fails
ok "formato senza spazi riconosciuto e riscritto" 'grep -q "^video_driver=\"gl\"" "${RA_CFG}"'

# RetroArch usa la PRIMA occorrenza di una chiave: se il file ne ha due
# (modifica a mano), la guardia deve leggere la stessa
printf 'video_driver = "vulkan"\nvideo_driver = "gl"\n' > "${RA_CFG}"; rm -f "${T}/run/ra-vkfail"; fails; fails
ok "chiave ripetuta: vale la prima (vulkan), e dopo 2 morti tutte a gl" '[ "$(grep -c "^video_driver = \"gl\"" "${RA_CFG}")" = 2 ]'

rm -f "${RA_CFG}"; SERVICE_RESULT=exit-code g post; rc=$?
ok "cfg assente: esce 0 senza toccare nulla" '[ ${rc} = 0 ] && [ ! -e "${RA_CFG}" ]'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
