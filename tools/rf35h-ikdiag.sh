#!/bin/sh
# rf35h-ikdiag.sh - misure sulla console MENTRE IKEMEN GO gira, per capire
# se e' lento per la CPU, per la GPU, per la memoria o per il vsync.
#
#   sh /storage/rf35h-ikdiag.sh [secondi]        (default 10, da ssh)
#
# Va lanciato con un incontro in corso. Stampa e salva anche in
# /storage/rf35h-logs/ikdiag-<data>.txt. Non cambia niente, tranne accendere il
# conteggio del tempo GPU di panfrost (sysfs "profiling", torna spento al
# riavvio): e' quello che fa comparire drm-engine-* nel fdinfo del processo.
#
# Se IKEMEN e' stato avviato con GALLIUM_HUD=fps e
# GALLIUM_HUD_DUMP_DIR=/storage/rf35h-logs/hud (cartella esistente), legge gli
# fps veri dal dump di Mesa; con GODEBUG=gctrace=1 le ultime righe del garbage
# collector di Go, che IKEMEN scrive in ikemen.log.
set -u
S="${1:-10}"
case "${S}" in ''|*[!0-9]*|0) echo "uso: $0 [secondi]" >&2; exit 2 ;; esac
GAME="${IKEMEN_HOME:-/storage/roms/ikemen}"
LOGD="${RF35H_LOGDIR:-/storage/rf35h-logs}"
CPUF=/sys/devices/system/cpu/cpufreq/policy0
export SWAYSOCK="${SWAYSOCK:-/var/run/0-runtime-dir/sway-ipc.0.sock}"

P="$(pidof ikemen | cut -d' ' -f1)"
[ -n "${P}" ] || { echo "IKEMEN non sta girando: avvialo, entra in un incontro e rilancia" >&2; exit 1; }
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
mkdir -p "${LOGD}"
OUT="${LOGD}/ikdiag-$(date +%Y%m%d-%H%M%S).txt"

rd() { cat "$1" 2>/dev/null || echo "?"; }
# numero intero, 0 se il file manca (per l'aritmetica della shell)
rn() { v="$(cat "$1" 2>/dev/null | head -n 1)"; case "${v}" in ''|*[!0-9]*) echo 0 ;; *) echo "${v}" ;; esac; }
# CPU per thread (utime+stime, tick da 1/100 s): campi 14 e 15 di stat, 12 e 13
# dopo aver tolto "pid (comm) "
thr() { for t in /proc/"${P}"/task/*; do awk -v t="${t##*/}" '{ sub(/^.*\) /, ""); print t, $12 + $13 }' "${t}/stat" 2>/dev/null; done; }
# per core: occupato = user+nice+system+irq+softirq+steal, totale = + idle + iowait
cores() { awk '/^cpu[0-9]/ { b = $2+$3+$4+$7+$8+$9; print $1, b, b+$5+$6 }' /proc/stat; }
# tempo GPU del processo (ns), una volta per client DRM anche se ha piu' fd
gpu() { awk 'FNR == 1 { id = "" } /^drm-client-id:/ { id = $2 }
	/^drm-engine-(fragment|vertex-tiler):/ { k = id SUBSEP $1; if (!(k in seen)) { seen[k] = 1; s[$1] += $2 } }
	END { for (k in s) print k, s[k] }' /proc/"${P}"/fdinfo/* 2>/dev/null; }
swp() { awk '/^pswp(in|out) / { print $1, $2 }' /proc/vmstat; }

{
echo "=== rf35h-ikdiag $(date)  finestra ${S} s"
echo "ikemen pid ${P}, uptime $(cut -d' ' -f1 /proc/uptime) s, $(grep -c '^processor' /proc/cpuinfo) core"
# Un processo fermo (stato T) misura zero su tutto: e' successo lanciandolo in
# background da una shell interattiva, dove IKEMEN legge lo stdin (la sua
# console di debug) e riceve SIGTTIN. Va avviato con </dev/null.
st="$(awk '{ sub(/^.*\) /, ""); print $1 }' /proc/"${P}"/stat 2>/dev/null)"
case "${st}" in
	T|t) echo "ATTENZIONE: ikemen e' FERMO (stato ${st}): le misure sotto valgono zero."
	     echo "  Va avviato con </dev/null; per toglierlo: pkill -9 -x ikemen" ;;
esac
grep -E '^(VmRSS|VmHWM|Threads)' /proc/"${P}"/status | tr '\n' ' '; echo
free -m | sed -n '1,3p'

echo "--- save/config.ini [Video]"
sed -n '/^\[Video\]/,/^\[/p' "${GAME}/save/config.ini" 2>/dev/null \
	| grep -E '^(RenderMode|GameWidth|GameHeight|WindowWidth|WindowHeight|Fullscreen|Borderless|VSync|Framerate|MSAA|KeepAspect|ExternalShaders)[[:space:]]*='
echo "--- renderer (ikemen.log) e ambiente del processo"
grep -E 'Using OpenGL|Mali|Panfrost|llvmpipe|softpipe|panic|rror' "${LOGD}/ikemen.log" 2>/dev/null | head -n 8
tr '\0' '\n' < /proc/"${P}"/environ 2>/dev/null \
	| grep -E '^(SDL_VIDEODRIVER|MESA_[A-Z_]*|PAN_[A-Z_]*|GOMEMLIMIT|GALLIUM_HUD[A-Z_]*|GODEBUG)=' || true
echo "--- schermo (sway)"
swaymsg -p -t get_outputs 2>/dev/null | grep -E 'Output|Current mode|Scale factor|Adaptive' || echo "(swaymsg non risponde)"

echo "--- clock e temperature, prima"
echo "cpu $(rd ${CPUF}/scaling_governor) $(( $(rn ${CPUF}/scaling_cur_freq) / 1000 )) MHz, max $(( $(rn ${CPUF}/scaling_max_freq) / 1000 )) MHz, boost $(rd /sys/devices/system/cpu/cpufreq/boost)"
for d in /sys/class/devfreq/*; do
	[ -e "${d}/cur_freq" ] && echo "${d##*/} $(rd "${d}/governor") $(( $(rn "${d}/cur_freq") / 1000000 )) MHz, max $(( $(rn "${d}/max_freq") / 1000000 )) MHz"
done
temps() { for z in /sys/class/thermal/thermal_zone*; do [ -e "${z}/temp" ] && printf '%s %s C  ' "$(rd "${z}/type")" "$(( $(rn "${z}/temp") / 1000 ))"; done; echo; }
temps

for f in /sys/bus/platform/devices/*.gpu/profiling; do [ -w "${f}" ] && echo 1 > "${f}"; done
sleep 1

# La finestra vera si misura con /proc/uptime: il ciclo sotto dura piu' di
# S secondi (ogni giro lancia qualche processo, e su un A35 carico costa), e
# dividendo per S le percentuali per thread e per la GPU uscivano gonfiate di
# circa il 10% (sulla console: 110% per un solo thread, impossibile).
thr > "${T}/t0"; cores > "${T}/c0"; gpu > "${T}/g0"; swp > "${T}/s0"
u0="$(cut -d' ' -f1 /proc/uptime)"
smp=""
i=0
while [ "${i}" -lt "${S}" ]; do
	sleep 1
	g=0; for d in /sys/class/devfreq/*.gpu; do g="$(rn "${d}/cur_freq")"; done
	smp="${smp} $(( $(rn ${CPUF}/scaling_cur_freq) / 1000 ))/$(( g / 1000000 ))/$(( $(rn /sys/class/devfreq/dmc/cur_freq) / 1000000 ))"
	i=$((i + 1))
done
thr > "${T}/t1"; cores > "${T}/c1"; gpu > "${T}/g1"; swp > "${T}/s1"
u1="$(cut -d' ' -f1 /proc/uptime)"
R="$(awk -v a="${u0}" -v b="${u1}" 'BEGIN { d = b - a; printf "%.2f", (d > 0) ? d : 1 }')"

echo "--- nei ${S} s (misurati: ${R} s)"
echo "MHz cpu/gpu/ddr ogni secondo:${smp}"
echo "thread di ikemen, % di un core (il principale e' il ciclo di gioco):"
awk -v s="${R}" -v p="${P}" 'NR == FNR { a[$1] = $2; next }
	{ d = $2 - a[$1]; if (d > 0) printf "  %s %.0f%%%s\n", $1, d / s, ($1 == p ? " (principale)" : "") }' \
	"${T}/t0" "${T}/t1" | sort -k2 -n -r | awk '{ print; if (++n == 6) exit }'
awk -v s="${R}" 'NR == FNR { a[$1] = $2; next } { t += $2 - a[$1] } END { printf "  processo intero: %.0f%% di un core\n", t / s }' "${T}/t0" "${T}/t1"
printf 'core occupati:'
awk 'NR == FNR { b[$1] = $2; t[$1] = $3; next }
	{ dt = $3 - t[$1]; printf " %s %.0f%%", $1, (dt > 0 ? 100 * ($2 - b[$1]) / dt : 0) } END { print "" }' "${T}/c0" "${T}/c1"
# (le parentesi attorno al ?: servono: in un printf di awk un ">" nudo e' una
# redirezione, e scriveva in un file chiamato "0" nella cartella corrente)
if [ -s "${T}/g1" ]; then
	printf 'GPU occupata:'
	awk -v s="${R}" 'NR == FNR { a[$1] = $2; next }
		{ k = $1; n = k; sub(/^drm-engine-/, "", n); sub(/:$/, "", n); printf " %s %.0f%%", n, ($2 - a[k]) / (s * 1e7) } END { print "" }' "${T}/g0" "${T}/g1"
else
	echo "GPU occupata: (niente drm-engine nel fdinfo: profiling di panfrost assente)"
fi
awk 'NR == FNR { a[$1] = $2; next } { printf "%s +%d  ", $1, $2 - a[$1] } END { print "(pagine da/verso zram)" }' "${T}/s0" "${T}/s1"
grep -E '^Swap(Total|Free)' /proc/meminfo | tr -s ' ' | tr '\n' ' '; echo
temps

echo "--- fps veri (dump di GALLIUM_HUD)"
F="${LOGD}/hud/fps"
if [ -s "${F}" ]; then
	tail -n "$((S * 2))" "${F}" | awk '{ v = $NF; n++; s += v; if (n == 1 || v < mn) mn = v; if (v > mx) mx = v }
		END { printf "ultimi %d campioni: media %.1f, min %.1f, max %.1f\n", n, s / n, mn, mx }'
else
	echo "(nessun dump: GALLIUM_HUD non attivo per questo avvio)"
fi
echo "--- garbage collector di Go (GODEBUG=gctrace=1)"
grep '^gc ' "${LOGD}/ikemen.log" 2>/dev/null | tail -n 3 || true
echo "--- kernel"
dmesg 2>/dev/null | grep -i -E 'panfrost|mali|out of memory|oom-kill|throttl|critical temp' | tail -n 8
} 2>&1 | tee "${OUT}"
echo "(salvato in ${OUT})"
