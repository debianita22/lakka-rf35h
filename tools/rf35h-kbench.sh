#!/bin/sh
# rf35h-kbench.sh - misure del kernel e della memoria, per confrontare due
# immagini, o due impostazioni, sulla stessa console.
#
#   sh rf35h-kbench.sh salva <nome> [--thp always|madvise|never] [--giri N]
#   sh rf35h-kbench.sh gioco <nome> [minuti]     mentre giochi (default 10)
#   sh rf35h-kbench.sh confronta <nome-a> <nome-b>
#
# Nato per le prove della v1.3.1 (7/10/2026): il kernel compilato con
# -mtune=cortex-a35 (ramo ci-test/kernel-tune) e le huge page trasparenti in
# "madvise" invece di "always". Prima i numeri, poi le modifiche (come
# rf35h-bench).
#
# Ogni prova gira N volte (default 5) e si tiene la mediana. Durante le misure:
# governor "performance" (con ondemand la frequenza cambierebbe sotto le
# misure) e RetroArch fermo (il menu disegna 60 volte al secondo). Alla fine
# governor, huge page e RetroArch tornano com'erano.
#
# Le prove (perf c'e' nell'immagine: lo costruisce il pacchetto linux):
#   pipe       perf bench sched pipe          cambi di contesto, usecs/op
#   messaging  perf bench sched messaging     scheduler e socket, secondi
#   syscall    perf bench syscall basic       una chiamata di sistema, usecs/op
#   futex      perf bench futex hash          lock del kernel, operazioni/s
#   dd         da /dev/zero a /dev/null, 4 GB a blocchi di 64 KB, MB/s:
#              le copie e gli azzeramenti del kernel
#   memcpy     perf bench mem memcpy, GB/s: solo spazio utente, fa da
#              controllo (fra due kernel non deve cambiare)
# piu' i contatori di huge page e compattazione (/proc/vmstat) e la
# temperatura. Tutto in /storage/kbench/<nome>.txt, output grezzo compreso.
#
# "gioco" non misura niente da solo: mentre giochi (lancialo da ssh e gioca
# per i minuti indicati) conta quante volte il kernel si e' fermato a
# compattare la memoria e quante huge page ha creato, e la memoria alla fine.
# E' li' che "always" puo' costare (pause), non nelle prove di velocita', dove
# le huge page aiutano.
set -u

DIR="${RF35H_KBENCH_DIR:-/storage/kbench}"
CPUFREQ="${RF35H_CPUFREQ:-/sys/devices/system/cpu/cpu0/cpufreq}"
THP="${RF35H_THP:-/sys/kernel/mm/transparent_hugepage/enabled}"
VMSTAT="${RF35H_VMSTAT:-/proc/vmstat}"
TEMP="${RF35H_TEMP:-/sys/class/thermal/thermal_zone0/temp}"
PERF="${RF35H_PERF:-perf}"

uso() {
	echo "uso: sh $0 salva <nome> [--thp always|madvise|never] [--giri N]" >&2
	echo "     sh $0 gioco <nome> [minuti]" >&2
	echo "     sh $0 confronta <nome-a> <nome-b>" >&2
	exit 1
}

rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "?"; }
cs() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
temp_c() { t="$(rd "${TEMP}")"; case "${t}" in ''|*[!0-9]*) echo "?" ;; *) echo $(( t / 1000 )) ;; esac; }
# la modalita' attiva e' quella fra parentesi quadre: "always [madvise] never"
thp_now() { sed -n 's/.*\[\([a-z]*\)\].*/\1/p; t; p' "${THP}" 2>/dev/null; }

# mediana di una lista di numeri (anche decimali)
mediana() {
	printf '%s\n' "$@" | grep -E '^[0-9.]+$' | sort -n | awk '{ v[NR] = $1 } END {
		if (NR == 0) { print "?"; exit }
		if (NR % 2) print v[(NR + 1) / 2]; else printf "%.6g\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# ---- confronto ---------------------------------------------------------------
# Le chiavi finiscono in _basso (meglio se scende) o _alto (meglio se sale).
confronta() {
	a="${DIR}/$1.txt"; b="${DIR}/$2.txt"
	[ -f "${a}" ] || { echo "non trovo ${a}" >&2; exit 1; }
	[ -f "${b}" ] || { echo "non trovo ${b}" >&2; exit 1; }
	echo "== $1 -> $2"
	awk -v A="$1" -v B="$2" '
		FILENAME == ARGV[1] && $1 ~ /_(basso|alto)$/ { va[$1] = $2; next }
		FILENAME == ARGV[1] && $1 ~ /^info_/ { ia[$1] = $0; next }
		$1 ~ /^info_/ { ib[$1] = $0; next }
		$1 ~ /_(basso|alto)$/ && ($1 in va) {
			x = va[$1]; y = $2
			if (x + 0 == 0 || x == "?" || y == "?") { printf "  %-22s %12s %12s\n", $1, x, y; next }
			d = (y - x) / x * 100
			meglio = ($1 ~ /_basso$/) ? (d < 0) : (d > 0)
			giudizio = (d < 1 && d > -1) ? "uguale (entro 1%)" : (meglio ? "meglio" : "peggio")
			printf "  %-22s %12s %12s  %+6.1f%%  %s\n", $1, x, y, d, giudizio
		}
		END {
			print "-- condizioni"
			for (k in ia) printf "  %s\n  %s\n", ia[k], (k in ib) ? ib[k] : "(manca in " B ")"
		}' "${a}" "${b}"
	echo "(differenze sotto il 2-3% sono rumore, se i giri di una stessa prova"
	echo " variano gia' di tanto: guarda le righe *_giri nei due file)"
}

# ---- misure ------------------------------------------------------------------
NOME=""; THP_SET=""; GIRI=5
salva_prep() {
	[ -n "${NOME}" ] || uso
	case "${NOME}" in *[!A-Za-z0-9_.-]*) echo "nome con caratteri strani: ${NOME}" >&2; exit 1 ;; esac
	command -v "${PERF}" >/dev/null 2>&1 || { echo "manca perf" >&2; exit 2; }
	mkdir -p "${DIR}" || exit 1
	OUT="${DIR}/${NOME}.txt"; RAW="${DIR}/${NOME}.grezzo.txt"
	: > "${OUT}"; : > "${RAW}"
}

GOV_PRIMA=""; THP_PRIMA=""; RA_FERMATO=""
ripristina() {
	[ -n "${GOV_PRIMA}" ] && echo "${GOV_PRIMA}" > "${CPUFREQ}/scaling_governor" 2>/dev/null
	[ -n "${THP_PRIMA}" ] && echo "${THP_PRIMA}" > "${THP}" 2>/dev/null
	[ -n "${RA_FERMATO}" ] && systemctl start retroarch 2>/dev/null
	GOV_PRIMA=""; THP_PRIMA=""; RA_FERMATO=""
}

# una prova: nome, chiave del risultato, comando; il risultato lo estrae awk
# dall'output (programma in $3), il comando e' il resto
prova() {
	chiave="$1"; estrai="$2"; shift 2
	valori=""
	i=1
	while [ "${i}" -le "${GIRI}" ]; do
		o="$("$@" 2>&1)"
		printf '### %s giro %s: %s\n%s\n' "${chiave}" "${i}" "$*" "${o}" >> "${RAW}"
		v="$(printf '%s\n' "${o}" | awk "${estrai}" | head -1)"
		valori="${valori} ${v:-?}"
		i=$((i + 1))
	done
	# shellcheck disable=SC2086  # elenco di numeri
	m="$(mediana ${valori})"
	printf '%s %s\n' "${chiave}" "${m}" >> "${OUT}"
	printf '%s_giri%s\n' "${chiave%_*}" "${valori}" >> "${OUT}"
	printf '  %-22s %s   (giri:%s)\n' "${chiave}" "${m}" "${valori}"
}

# dd: il tempo lo misura lo script (la busybox puo' non stampare la velocita')
dd_mbs() {
	t0="$(cs)"
	dd if=/dev/zero of=/dev/null bs=64k count=65536 2>/dev/null
	t1="$(cs)"
	awk -v d="$(( t1 - t0 ))" 'BEGIN { if (d <= 0) print "?"; else printf "%.1f\n", 4096 / (d / 100) }'
}

salva() {
	salva_prep
	# anche se cade la ssh (HUP) o si chiude la pipe di chi legge (PIPE)
	trap 'ripristina; exit 130' INT TERM HUP PIPE
	trap 'ripristina' EXIT

	grep -E '^(thp_|compact_)' "${VMSTAT}" > "${DIR}/.vm0" 2>/dev/null
	{
		echo "info_kernel $(rd /proc/version)"
		echo "info_avvio $(date '+%Y-%m-%d %H:%M') uptime $(cut -d' ' -f1 /proc/uptime)s"
	} >> "${OUT}"

	if command -v systemctl >/dev/null 2>&1 && systemctl is-active -q retroarch 2>/dev/null; then
		echo "fermo RetroArch durante le misure (lo rimetto alla fine)"
		systemctl stop retroarch && RA_FERMATO=1
		sleep 2
	fi
	if [ -w "${CPUFREQ}/scaling_governor" ]; then
		GOV_PRIMA="$(rd "${CPUFREQ}/scaling_governor")"
		echo performance > "${CPUFREQ}/scaling_governor"
	fi
	if [ -n "${THP_SET}" ]; then
		THP_PRIMA="$(thp_now)"
		echo "${THP_SET}" > "${THP}" || { echo "non riesco a scrivere ${THP}" >&2; exit 1; }
	fi
	{
		echo "info_thp $(thp_now)"
		echo "info_governor $(rd "${CPUFREQ}/scaling_governor") a $(rd "${CPUFREQ}/scaling_cur_freq") kHz (prima: ${GOV_PRIMA:-non cambiato})"
		echo "info_temperatura_inizio $(temp_c) C"
	} >> "${OUT}"
	echo "== ${NOME}: kernel $(uname -r), THP $(thp_now), ${GIRI} giri per prova"

	prova pipe_usecs_basso       '/usecs\/op/ { print $1 }'                    "${PERF}" bench sched pipe -l 100000
	prova messaging_sec_basso    '/Total time/ { print $3 }'                   "${PERF}" bench sched messaging -g 4 -l 50
	prova syscall_usecs_basso    '/usecs\/op/ { print $1 }'                    "${PERF}" bench syscall basic -l 2000000
	prova futex_ops_alto         '/Averaged/ { print $2 }'                     "${PERF}" bench futex hash -r 3 -t 4
	prova dd_mbs_alto            '{ print $1 }'                                dd_mbs
	prova memcpy_gbs_alto        '/GB\/sec/ { print $1; exit } /MB\/sec/ { printf "%.4f\n", $1 / 1024; exit }' \
		"${PERF}" bench mem memcpy -s 64MB -l 20

	grep -E '^(thp_|compact_)' "${VMSTAT}" > "${DIR}/.vm1" 2>/dev/null
	{
		echo "info_temperatura_fine $(temp_c) C"
		sed 's/^/vm0 /' "${DIR}/.vm0"
		sed 's/^/vm1 /' "${DIR}/.vm1"
	} >> "${OUT}"
	echo "  huge page e compattazione durante le misure (solo i contatori cambiati):"
	awk 'FILENAME == ARGV[1] { a[$1] = $2; next }
		($1 in a) && $2 != a[$1] { printf "    %-28s +%d\n", $1, $2 - a[$1]; n++ }
		END { if (!n) print "    nessuno" }' "${DIR}/.vm0" "${DIR}/.vm1"
	rm -f "${DIR}/.vm0" "${DIR}/.vm1"
	echo "tutto in ${OUT} (e l'output di perf in ${RAW})"
}

gioco() {
	[ -n "${NOME}" ] || uso
	case "${NOME}" in *[!A-Za-z0-9_.-]*) echo "nome con caratteri strani: ${NOME}" >&2; exit 1 ;; esac
	mkdir -p "${DIR}" || exit 1
	OUT="${DIR}/${NOME}.txt"
	grep -E '^(thp_|compact_|pswp|pgmajfault)' "${VMSTAT}" > "${DIR}/.vm0" 2>/dev/null
	echo "== ${NOME}: THP $(thp_now), ${MIN} minuti. Gioca: alla fine scrivo i contatori."
	sleep $(( MIN * 60 ))
	grep -E '^(thp_|compact_|pswp|pgmajfault)' "${VMSTAT}" > "${DIR}/.vm1" 2>/dev/null
	{
		echo "info_kernel $(rd /proc/version)"
		echo "info_thp $(thp_now)"
		echo "info_gioco ${MIN} minuti, fine $(date '+%Y-%m-%d %H:%M')"
		awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) { printf "%s_delta_basso %d\n", $1, $2 - a[$1] }' \
			"${DIR}/.vm0" "${DIR}/.vm1" | grep -E '^(compact_stall|compact_fail|thp_fault_fallback|pgmajfault|pswpin|pswpout)_'
		awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) { printf "%s_delta %d\n", $1, $2 - a[$1] }' \
			"${DIR}/.vm0" "${DIR}/.vm1" | grep -vE '^(compact_stall|compact_fail|thp_fault_fallback|pgmajfault|pswpin|pswpout)_'
		grep -E '^(MemAvailable|AnonHugePages|SwapTotal|SwapFree):' /proc/meminfo | sed 's/: */ /; s/^/mem_/'
	} > "${OUT}"
	rm -f "${DIR}/.vm0" "${DIR}/.vm1"
	grep -E '_delta|^mem_' "${OUT}" | sed 's/^/  /'
	echo "tutto in ${OUT}"
}

case "${1:-}" in
	gioco)
		NOME="${2:-}"; MIN="${3:-10}"
		case "${MIN}" in ''|*[!0-9]*) uso ;; esac
		gioco ;;
	salva)
		NOME="${2:-}"; [ $# -ge 2 ] && shift 2 || uso
		while [ $# -gt 0 ]; do
			case "$1" in
				--thp)  case "${2:-}" in always|madvise|never) THP_SET="$2" ;; *) uso ;; esac; shift 2 ;;
				--giri) case "${2:-}" in ''|*[!0-9]*) uso ;; esac; GIRI="$2"; shift 2 ;;
				*) uso ;;
			esac
		done
		salva ;;
	confronta)
		[ $# -eq 3 ] || uso
		confronta "$2" "$3" ;;
	*) uso ;;
esac
