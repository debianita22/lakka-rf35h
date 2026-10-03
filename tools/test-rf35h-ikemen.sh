#!/bin/bash
# test-rf35h-ikemen.sh - prove del lanciatore di IKEMEN GO con comandi finti.
#
#   ./tools/test-rf35h-ikemen.sh [percorso/rf35h-ikemen]
#
# Non serve il device: un "ikemen" finto registra ambiente e cartella, e si
# comporta come gli dice il file "mode" (riuscito, OpenGL che non parte, cambio
# di renderer dal menu, crash, blocco); systemctl e' finto anche lui. Gira lo
# script con la busybox se c'e' (come sul device), altrimenti con sh.
set -u
L="${1:-$(cd "$(dirname "$0")/.." && pwd)/packages/ikemen-go/scripts/rf35h-ikemen}"
[ -f "${L}" ] || { echo "non trovo ${L}" >&2; exit 1; }
SH="sh"; command -v busybox >/dev/null && SH="busybox sh"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/share/data" "${T}/share/external/script" "${T}/share/chars/kfm" "${T}/share/stages" "${T}/bin" "${T}/out" "${T}/xdg"

echo "motore v1" > "${T}/share/data/action.zss"
echo "-- main v1" > "${T}/share/external/script/main.lua"
printf '# commento\nGUIDRF35H,retrogame_joypad,a:b0,platform:Linux,\n' > "${T}/share/external/gamecontrollerdb.txt"
echo "kfm" > "${T}/share/chars/kfm/kfm.def"; echo "select v1" > "${T}/share/data/select.def"; echo "stage" > "${T}/share/stages/kfm.def"
printf 'data/action.zss\nexternal/script/main.lua\nexternal/gamecontrollerdb.txt\n' > "${T}/share/engine.list"
printf 'chars/kfm/kfm.def\ndata/select.def\nstages/kfm.def\n' > "${T}/share/screenpack.list"
echo "eng-1" > "${T}/share/engine.version"; echo "sp-1" > "${T}/share/screenpack.version"
cp "$(dirname "${L}")/../config/rf35h-default-config.ini" "${T}/share/" 2>/dev/null || \
	printf '[Config]\nFirstRun = 0\n[Video]\nRenderMode = OpenGL ES 3.2\nEnableModelShadow = 0\n' > "${T}/share/rf35h-default-config.ini"

cat > "${T}/bin/ikemen" <<'EOF'
#!/bin/sh
{ echo "cwd=$(pwd)"; env | grep -E '^(SDL_|MESA_|PAN_|GOMEMLIMIT|IKEMEN_DISABLE_VULKAN)' | sort; } > "${T_OUT}/run.$(date +%s%N).env"
echo "$$" >> "${T_OUT}/runs"
case "$(cat "${T_OUT}/mode" 2>/dev/null)" in
	fail-gl)   [ -n "${MESA_GL_VERSION_OVERRIDE:-}" ] && { echo "opengl non va" >&2; exit 2; } ;;
	switch-gl) sed -i 's/^\([[:space:]]*RenderMode[[:space:]]*=[[:space:]]*\).*/\1OpenGL 3.3/' save/config.ini ;;
	crash)     exit 139 ;;
	hang)      sleep 30 ;;
	play3)     sleep 3 ;;
esac
exit 0
EOF
cat > "${T}/bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
	is-system-running) cat "${T_OUT}/sysstate" 2>/dev/null || echo running ;;
	*) echo "systemctl $*" >> "${T_OUT}/systemctl" ;;
esac
EOF
chmod +x "${T}/bin/ikemen" "${T}/bin/systemctl"
python3 -c "import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])" "${T}/xdg/wayland-1" 2>/dev/null || true

export T_OUT="${T}/out" IKEMEN_SHARE="${T}/share" IKEMEN_HOME="${T}/game" IKEMEN_BIN="${T}/bin/ikemen" \
	RF35H_STATE_DIR="${T}/state" RF35H_LOGDIR="${T}/logs" PATH="${T}/bin:${PATH}" \
	WAYLAND_DISPLAY=wayland-1 XDG_RUNTIME_DIR="${T}/xdg" IKEMEN_RA_CFG="${T}/ra.cfg" \
	IKEMEN_VK_LOADER=/bin/sh   # un loader Vulkan presente (come nell'immagine) non cambia niente
G="${T}/game"; C="${G}/save/config.ini"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
lastenv() { ls -t "${T}"/out/run.*.env | head -1; }
state() { cat "${T}/state/ikemen-renderer" 2>/dev/null; }
mode() { echo "$1" > "${T}/out/mode"; }
run() { ${SH} "${L}" run 2>/dev/null; }

echo "lanciatore: ${L}  (con ${SH})"
mode ok; run; rc=$?
ok "primo avvio: rc 0" '[ ${rc} = 0 ]'
ok "primo avvio: motore e screenpack copiati" 'grep -q "motore v1" "${G}/data/action.zss" && [ -f "${G}/chars/kfm/kfm.def" ] && [ -f "${G}/stages/kfm.def" ]'
ok "primo avvio: config con OpenGL ES 3.2, stato opengles" 'grep -qE "^RenderMode[[:space:]]*= OpenGL ES 3.2" "${C}" && [ "$(state)" = opengles ]'
ok "GLES: override Mesa 3.2, Wayland, Vulkan spento anche in IKEMEN" 'grep -q "MESA_GLES_VERSION_OVERRIDE=3.2" "$(lastenv)" && grep -q "SDL_VIDEODRIVER=wayland" "$(lastenv)" && ! grep -qE "MESA_VK|PAN_I_WANT" "$(lastenv)" && grep -q "IKEMEN_DISABLE_VULKAN=1" "$(lastenv)"'
ok "cartella di lavoro, mappatura joypad senza commenti, GOMEMLIMIT" 'grep -q "cwd=${G}" "$(lastenv)" && grep -q "SDL_GAMECONTROLLERCONFIG=GUIDRF35H" "$(lastenv)" && grep -qE "GOMEMLIMIT=[0-9]+MiB" "$(lastenv)"'
ok "log con renderer e ambiente" 'grep -q "renderer opengles" "${T}/logs/ikemen.log" && grep -q "MESA_GLES_VERSION_OVERRIDE=3.2" "${T}/logs/ikemen.log"'

${SH} "${L}" renderer vulkan 2>"${T}/out/err"; rc=$?
ok "renderer vulkan rifiutato con il motivo, config e stato intatti" '[ ${rc} != 0 ] && grep -q "Vulkan 1.0" "${T}/out/err" && grep -qE "^RenderMode[[:space:]]*= OpenGL ES 3.2" "${C}" && [ "$(state)" = opengles ]'
${SH} "${L}" renderer opengl
ok "renderer opengl: config e stato" 'grep -qE "^RenderMode[[:space:]]*= OpenGL 3.3" "${C}" && [ "$(${SH} "${L}" renderer)" = opengl ]'
${SH} "${L}" renderer foo 2>/dev/null; rc=$?
ok "renderer sconosciuto rifiutato, stato intatto" '[ ${rc} != 0 ] && [ "$(state)" = opengl ]'

: > "${T}/out/runs"; mode ok; run
ok "OpenGL che va: un avvio, override GL 3.3" '[ $(wc -l < "${T}/out/runs") = 1 ] && grep -q MESA_GL_VERSION_OVERRIDE=3.3 "$(lastenv)"'

: > "${T}/out/runs"; mode fail-gl; run; rc=$?
ok "OpenGL che non parte: secondo avvio in GLES, rc 0" '[ $(wc -l < "${T}/out/runs") = 2 ] && [ ${rc} = 0 ] && grep -q MESA_GLES_VERSION_OVERRIDE "$(lastenv)"'
ok "  ...config e stato tornati a opengles, nota scritta" 'grep -qE "^RenderMode[[:space:]]*= OpenGL ES 3.2" "${C}" && [ "$(state)" = opengles ] && grep -qs "codice 2" "${T}"/logs/ikemen-fallback-*.txt'

mode switch-gl; run
ok "renderer cambiato dal menu di IKEMEN: lo stato lo segue" '[ "$(state)" = opengl ]'

: > "${T}/out/runs"; mode crash
IKEMEN_FAIL_WINDOW=0 ${SH} "${L}" run 2>/dev/null; rc=$?
ok "crash oltre la finestra: niente ripiego, codice riportato" '[ ${rc} = 139 ] && [ $(wc -l < "${T}/out/runs") = 1 ] && [ "$(state)" = opengl ]'

n0=$(ls "${T}"/logs/ikemen-fallback-* 2>/dev/null | wc -l); : > "${T}/out/runs"; mode hang
${SH} "${L}" run 2>/dev/null & lp=$!; sleep 2; cp="$(tail -1 "${T}/out/runs")"; kill -TERM "${lp}"; wait "${lp}" 2>/dev/null; sleep 1
ok "stop (TERM) nei primi secondi: IKEMEN chiuso, nessun ripiego" '! kill -0 "${cp}" 2>/dev/null && [ $(wc -l < "${T}/out/runs") = 1 ] && [ "$(state)" = opengl ] && [ $(ls "${T}"/logs/ikemen-fallback-* | wc -l) = ${n0} ]'

# Vulkan lasciato da una versione precedente, nel config e nello stato
sed -i 's/^\([[:space:]]*RenderMode[[:space:]]*=[[:space:]]*\).*/\1Vulkan 1.3/' "${C}"; echo vulkan > "${T}/state/ikemen-renderer"
ok "stato 'vulkan' vecchio: renderer stampa quello del config" '[ "$(${SH} "${L}" renderer)" = opengles ]'
: > "${T}/out/runs"; mode ok; run
ok "RenderMode Vulkan vecchio: un avvio in GLES, config e stato riscritti" '[ $(wc -l < "${T}/out/runs") = 1 ] && grep -q MESA_GLES_VERSION_OVERRIDE "$(lastenv)" && grep -qE "^RenderMode[[:space:]]*= OpenGL ES 3.2" "${C}" && [ "$(state)" = opengles ]'

mode ok; sed -i 's/^\([[:space:]]*RenderMode[[:space:]]*=[[:space:]]*\).*/\1OpenGL ES 3.1/' "${C}"; sed -i 's/^\(EnableModelShadow.*=[[:space:]]*\).*/\11/' "${C}"; run
ok "RenderMode sconosciuto -> OpenGL ES 3.2; ombre riportate a 0" 'grep -qE "^RenderMode[[:space:]]*= OpenGL ES 3.2" "${C}" && grep -qE "^EnableModelShadow[[:space:]]*= 0" "${C}"'

echo "select UTENTE" > "${G}/data/select.def"; rm -f "${G}/stages/kfm.def"
echo "motore v2" > "${T}/share/data/action.zss"; echo "eng-2" > "${T}/share/engine.version"; run
ok "motore nuovo: sovrascritto; select.def dell'utente intatto" 'grep -q "motore v2" "${G}/data/action.zss" && grep -q UTENTE "${G}/data/select.def"'
ok "  ...uno stage cancellato non ricompare" '[ ! -e "${G}/stages/kfm.def" ]'
echo "sp-2" > "${T}/share/screenpack.version"; run
ok "screenpack nuovo: torna solo cio' che manca" '[ -f "${G}/stages/kfm.def" ] && grep -q UTENTE "${G}/data/select.def"'

rm -rf "${G}" "${T}/state"; ${SH} "${L}" renderer opengl; ${SH} "${L}" prepare 2>/dev/null
ok "renderer scelto prima del primo avvio: finisce nel config" 'grep -qE "^RenderMode[[:space:]]*= OpenGL 3.3" "${C}"'

: > "${T}/out/systemctl"; ${SH} "${L}" back
ok "back: RetroArch riparte" 'grep -q "start retroarch.service" "${T}/out/systemctl"'
echo stopping > "${T}/out/sysstate"; : > "${T}/out/systemctl"; ${SH} "${L}" back; rm -f "${T}/out/sysstate"
ok "back allo spegnimento: nessun avvio" '[ ! -s "${T}/out/systemctl" ]'

printf '[Config]\r\nFirstRun = 0\r\n[Video]\r\nRenderMode = Vulkan 1.3\r\n' > "${C}"; ${SH} "${L}" renderer opengles
ok "config con CRLF: valore cambiato, CR conservato" 'grep -q "^RenderMode = OpenGL ES 3.2"$'"'"'\r'"'"'"$" "${C}" && [ "$(${SH} "${L}" renderer)" = opengles ]'
printf '[Video]\nGameWidth = 640\n[Sound]\nX = 1\n' > "${C}"; ${SH} "${L}" renderer opengl
ok "chiave mancante aggiunta nella sezione giusta" '[ "$(sed -n 3p "${C}")" = "RenderMode = OpenGL 3.3" ]'

mode ok; WAYLAND_DISPLAY=wayland-9 ${SH} "${L}" run 2>/dev/null
ok "senza socket Wayland: kmsdrm" 'grep -q SDL_VIDEODRIVER=kmsdrm "$(lastenv)"'
IKEMEN_BIN=/nonexistent ${SH} "${L}" run 2>"${T}/out/err"; rc=$?
ok "IKEMEN assente: errore chiaro" '[ ${rc} != 0 ] && grep -q "installato" "${T}/out/err"'

# tempo di gioco per "Core senza contenuto": il .lrtl del core lanciatore
# RetroArch salva i percorsi sotto la HOME come "~/..." e, se una chiave e'
# ripetuta, usa la prima: il lanciatore deve leggerla allo stesso modo
printf 'playlist_directory = "~/pl"\nruntime_log_directory = "default"\nplaylist_directory = "/altrove"\n' > "${T}/ra.cfg"
mkdir -p "${T}/pl/logs/IKEMEN GO"
printf '{\n  "version": "1.0",\n  "runtime": "0:59:58",\n  "last_played": "2026-09-25 17:00:00",\n  "play_count": "3",\n  "state_slot": "0"\n}\n' > "${T}/pl/logs/IKEMEN GO/IKEMEN GO.lrtl"
mode play3; HOME="${T}" ${SH} "${L}" run 2>/dev/null
ok "tempo di gioco: la partita vera si somma al .lrtl di RetroArch (~ e prima chiave)" 'grep -qE "\"runtime\": \"1:00:0[1-3]\"," "${T}/pl/logs/IKEMEN GO/IKEMEN GO.lrtl" && grep -q "\"play_count\": \"3\"" "${T}/pl/logs/IKEMEN GO/IKEMEN GO.lrtl"'
rm -rf "${T}/pl/logs"; mode play3; HOME="${T}" ${SH} "${L}" run 2>/dev/null
ok "  ...senza .lrtl (log spenti) non crea niente" '[ ! -e "${T}/pl/logs" ]'

# "start": quello che chiama il core lanciatore di RetroArch
: > "${T}/out/systemctl"; ${SH} "${L}" start opengl 2>/dev/null; rc=$?
ok "start opengl: renderer applicato, servizio avviato senza bloccare" '[ ${rc} = 0 ] && [ "$(state)" = opengl ] && grep -qE "^RenderMode[[:space:]]*= OpenGL 3.3" "${C}" && grep -qx "systemctl --no-block start rf35h-ikemen.service" "${T}/out/systemctl"'
: > "${T}/out/systemctl"; ${SH} "${L}" start 2>/dev/null
ok "start senza renderer: niente cambi, servizio avviato" '[ "$(state)" = opengl ] && grep -q "start rf35h-ikemen.service" "${T}/out/systemctl"'
: > "${T}/out/systemctl"; ${SH} "${L}" start vulkan 2>"${T}/out/err"
ok "start vulkan: rifiutato, resta opengl, servizio avviato" '[ "$(state)" = opengl ] && grep -qE "^RenderMode[[:space:]]*= OpenGL 3.3" "${C}" && grep -q "non applicato" "${T}/out/err" && grep -q "start rf35h-ikemen.service" "${T}/out/systemctl"'
: > "${T}/out/systemctl"; ${SH} "${L}" start foo 2>"${T}/out/err"
ok "start con renderer sconosciuto: ignorato, servizio avviato" '[ "$(state)" = opengl ] && grep -q "non applicato" "${T}/out/err" && grep -q "start rf35h-ikemen.service" "${T}/out/systemctl"'
${SH} "${L}" renderer opengles

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
