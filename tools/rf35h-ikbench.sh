#!/bin/sh
# rf35h-ikbench.sh - quanto veloce gira davvero IKEMEN GO sulla console:
# tick di gioco al secondo (60 = velocita' piena) e fps disegnati, con
# Framerate 60 o 30 e con i governor della CPU.
#
#   sh /storage/rf35h-ikbench.sh          (da ssh; ~7 minuti; RetroArch fermo)
#
# Metodo. Incontro KFM contro KFM, entrambi CPU, vita 100000 cosi' che nessuno
# vada KO: il round finisce sempre per tempo scaduto. Due corse per
# configurazione, con -time 5 e -time 20 (conteggi da 60 tick, fight.def):
# caricamento, presentazione e fine round sono identici e si elidono nella
# differenza, che e' il tempo reale di 900 tick di gioco. Le supermosse fermano
# il timer ma non il gioco: rumore di qualche per cento, non di piu'.
#
# Le corse precedenti con GALLIUM_HUD misuravano solo i fotogrammi disegnati:
# IKEMEN salta i disegni quando e' in ritardo, quindi gli fps da soli non dicono
# se il gioco va al rallentatore. I tick al secondo si'.
#
# Gioco a 320x240 (-width/-height cambiano la risoluzione di gioco, non la
# finestra) e in OpenGL ES: cosi' la GPU non entra nella misura. Sulla console,
# a 640x480 la GPU lavorava gia' ~23 ms per fotogramma (tetto ~40 fps); a
# 320x240 circa un terzo.
#
# Variabili per provare altro: IKBENCH_W/IKBENCH_H (risoluzione di gioco),
# IKBENCH_TMAX (secondi massimi per corsa, 300).
#
# Prima delle prove, 5 s di frequenza della CPU a riposo con RetroArch nel suo
# menu e 5 s senza RetroArch.
#
# Tocca e rimette com'era: Video.Framerate e Video.RenderMode in
# save/config.ini (copia di sicurezza accanto), governor e boost della CPU.
# RetroArch viene fermato e riavviato alla fine, anche se lo interrompi con
# Ctrl+C.
set -u
GAME="${IKEMEN_HOME:-/storage/roms/ikemen}"
CFG="${GAME}/save/config.ini"
LOGD="${RF35H_LOGDIR:-/storage/rf35h-logs}"
BIN="${IKEMEN_BIN:-/usr/bin/ikemen}"
POL="${RF35H_CPUFREQ_POLICY:-/sys/devices/system/cpu/cpufreq/policy0}"
BOOST="${RF35H_CPUFREQ_BOOST:-/sys/devices/system/cpu/cpufreq/boost}"
SYSTEMCTL="${RF35H_SYSTEMCTL:-systemctl}"
T1=5; T2=20; TMAX="${IKBENCH_TMAX:-300}"
GW="${IKBENCH_W:-320}"; GH="${IKBENCH_H:-240}"
OUT="${LOGD}/ikbench-$(date +%Y%m%d-%H%M%S).txt"
W="$(mktemp -d)"

[ -x "${BIN}" ] && [ -f "${CFG}" ] || { echo "manca ${BIN} o ${CFG}: avvia IKEMEN una volta da RetroArch" >&2; exit 1; }
pidof ikemen >/dev/null && { echo "IKEMEN sta gia' girando: chiudilo (o pkill -9 -x ikemen) e rilancia" >&2; exit 1; }
mkdir -p "${LOGD}"

gov0="$(cat "${POL}/scaling_governor" 2>/dev/null)"
boost0="$(cat "${BOOST}" 2>/dev/null)"
cp -f "${CFG}" "${CFG}.ikbench"
restore() {
	pkill -9 -x ikemen 2>/dev/null
	[ -f "${CFG}.ikbench" ] && mv -f "${CFG}.ikbench" "${CFG}"
	[ -n "${gov0}" ] && echo "${gov0}" > "${POL}/scaling_governor" 2>/dev/null
	[ -n "${boost0}" ] && echo "${boost0}" > "${BOOST}" 2>/dev/null
	rm -rf "${W}"
	${SYSTEMCTL} start retroarch
}
trap 'restore' EXIT
trap 'exit 130' INT TERM

up() { cut -d' ' -f1 /proc/uptime; }
# frequenza della CPU, un campione al secondo per $1 secondi
idle() { i=0; l=""; while [ "${i}" -lt "$1" ]; do sleep 1; l="${l} $(( $(cat "${POL}/scaling_cur_freq" 2>/dev/null || echo 0) / 1000 ))"; i=$((i + 1)); done; echo "${l}"; }
idle_ra="$(idle 5)"
${SYSTEMCTL} stop retroarch
sleep 2
idle_no="$(idle 5)"
export XDG_RUNTIME_DIR=/var/run/0-runtime-dir WAYLAND_DISPLAY=wayland-1 SDL_VIDEODRIVER=wayland
export MESA_GLES_VERSION_OVERRIDE=3.2 SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS=1 IKEMEN_DISABLE_VULKAN=1
export GOMEMLIMIT="$(( $(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) * 6 / 10 / 1024 ))MiB"
export GALLIUM_HUD=fps
export GALLIUM_HUD_PERIOD=0.5
cd "${GAME}" || exit 1

set_fr() {
	sed -i '/^\[Video\]/,/^\[/ s/^\(Framerate[[:space:]]*=[[:space:]]*\)[0-9]*/\1'"$1"'/' "${CFG}"
	sed -n '/^\[Video\]/,/^\[/p' "${CFG}" | grep -q "^Framerate[[:space:]]*=[[:space:]]*$1" \
		|| { echo "Framerate non trovato in [Video] di ${CFG}: niente misura" >&2; exit 1; }
}
maxtemp() { m=0; for z in /sys/class/thermal/thermal_zone*/temp; do t="$(cat "${z}" 2>/dev/null)"; case "${t}" in ''|*[!0-9]*) continue ;; esac; [ "${t}" -gt "${m}" ] && m="${t}"; done; echo $((m / 1000)); }
# OpenGL ES per tutte le prove (e' quello che ha l'override qui sopra)
sed -i '/^\[Video\]/,/^\[/ s/^\(RenderMode[[:space:]]*=[[:space:]]*\).*/\1OpenGL ES 3.2/' "${CFG}"

# una corsa: stampa "secondi fps MHz" (MHz: media dei campioni al secondo),
# oppure "FAIL motivo". Le statistiche (-log) IKEMEN le scrive solo a incontro
# finito: se mancano, l'incontro non e' arrivato in fondo.
run() {
	d="${W}/hud-$1-$2"; mkdir -p "${d}"
	t0="$(up)"
	GALLIUM_HUD_DUMP_DIR="${d}" "${BIN}" -p1 kfm -p1.ai 8 -p1.life 100000 -p1.lifeMax 100000 \
		-p2 kfm -p2.ai 8 -p2.life 100000 -p2.lifeMax 100000 -s kfm -rounds 1 -time "$2" \
		-width "${GW}" -height "${GH}" -log "${W}/stats-$1-$2.txt" </dev/null >"${W}/log-$1-$2.txt" 2>&1 &
	p=$!
	# in parallelo: MHz della CPU ogni secondo e limite di tempo. La fine si
	# prende con wait, al centesimo (col solo ciclo da 1 s sarebbe stata
	# arrotondata al secondo, qualche per cento sulla differenza).
	k="${W}/khz-$1-$2"; : > "${k}"
	( n=0; while kill -0 "${p}"; do
		sleep 1; n=$((n + 1))
		cat "${POL}/scaling_cur_freq" >> "${k}"
		[ "${n}" -ge "${TMAX}" ] && { : > "${k}.timeout"; kill -9 "${p}"; }
	  done ) 2>/dev/null &
	m=$!
	wait "${p}"
	t1="$(up)"
	kill "${m}" 2>/dev/null; wait "${m}" 2>/dev/null
	[ -e "${k}.timeout" ] && { echo "FAIL oltre ${TMAX} s"; return; }
	[ -s "${W}/stats-$1-$2.txt" ] || { echo "FAIL incontro non finito"; return; }
	# fps: media dei campioni senza i primi e gli ultimi 4 (caricamento, uscita)
	f="$(awk '{ v[NR] = $NF } END { s = 0; n = 0; for (i = 5; i <= NR - 4; i++) { s += v[i]; n++ } if (n) printf "%.1f", s / n; else print "?" }' "${d}/fps" 2>/dev/null)"
	mhz="$(awk '{ s += $1; n++ } END { printf "%d", (n > 0) ? s / n / 1000 : 0 }' "${k}")"
	awk -v a="${t0}" -v b="${t1}" -v f="${f:-?}" -v z="${mhz}" 'BEGIN { printf "%.2f %s %d\n", b - a, f, z }'
}

{
echo "=== rf35h-ikbench $(date)"
echo "KFM contro KFM (CPU 8), gioco ${GW}x${GH}, OpenGL ES; tick/s dalla differenza fra -time ${T2} e -time ${T1}"
echo "cpu: $(cat "${POL}/scaling_available_frequencies" 2>/dev/null) kHz; boost disponibile: $(cat "${POL}/scaling_boost_frequencies" 2>/dev/null || echo no)"
echo "cpu a riposo (${gov0}), MHz ogni secondo: con RetroArch nel menu${idle_ra}; senza RetroArch${idle_no}"
printf '%-10s %8s %9s %6s %9s %6s\n' config "tick/s" velocita fps "MHz cpu" "max C"
} | tee "${OUT}"

for c in base fr30 fr30perf fr30boost; do
	case "${c}" in
		base)      fr=60; gov=ondemand;    bst=0 ;;
		fr30)      fr=30; gov=ondemand;    bst=0 ;;
		fr30perf)  fr=30; gov=performance; bst=0 ;;
		fr30boost) fr=30; gov=performance; bst=1
		           [ -w "${BOOST}" ] || { echo "fr30boost: boost non scrivibile, salto" | tee -a "${OUT}"; continue; } ;;
	esac
	set_fr "${fr}"
	echo "${gov}" > "${POL}/scaling_governor" 2>/dev/null
	[ -w "${BOOST}" ] && echo "${bst}" > "${BOOST}" 2>/dev/null
	sleep 2
	r1="$(run "${c}" "${T1}")"
	case "${r1}" in FAIL*) r2="" ;; *) r2="$(run "${c}" "${T2}")" ;; esac
	temp="$(maxtemp)"
	# una corsa fallita: le successive non sarebbero confrontabili, ci si ferma
	case "${r1}" in FAIL*) why="${r1#FAIL }" ;; *) why="${r2#FAIL }" ;; esac
	case "${r1}|${r2}" in
	FAIL*|*"|FAIL"*)
		printf '%-10s FALLITO: %s; prove interrotte\n' "${c}" "${why}" | tee -a "${OUT}"
		for f in "${W}/log-${c}-${T1}.txt" "${W}/log-${c}-${T2}.txt"; do
			[ -f "${f}" ] && { echo "    ${f##*/}:"; tail -n 5 "${f}" | sed 's/^/    /'; }
		done >> "${OUT}"
		break ;;
	esac
	# campi: secondi, fps, MHz della corsa breve e poi di quella lunga
	echo "${r1} ${r2}" | awk -v c="${c}" -v tk="$(( (T2 - T1) * 60 ))" -v temp="${temp}" '
		{ dt = $4 - $1; tps = (dt > 0) ? tk / dt : 0
		  printf "%-10s %8.1f %8.0f%% %6s %9s %6s\n", c, tps, 100 * tps / 60, $5, $6, temp }' | tee -a "${OUT}"
	# fine round per tempo scaduto (nessun KO): la durata del round nelle statistiche
	grep -a -E '"(matchTime|winKO|winTime)"' "${W}/stats-${c}-${T2}.txt" 2>/dev/null | tr -s ' ' | tr '\n' ' ' | sed 's/^/    /' >> "${OUT}"
	echo >> "${OUT}"
done

echo "(salvato in ${OUT}; config.ini, governor e boost rimessi com'erano)" | tee -a "${OUT}"
