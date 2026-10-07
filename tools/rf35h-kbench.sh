#!/bin/sh
# rf35h-kbench.sh - misure del kernel e della memoria, per confrontare due
# immagini, o due impostazioni, sulla stessa console.
#
#   sh rf35h-kbench.sh salva <nome> [--thp always|madvise|never] [--giri N]
#   sh rf35h-kbench.sh core <nome> <core> <rom> [--thp always,madvise]
#                      [--stato N] [--frames N] [--giri N]
#   sh rf35h-kbench.sh gioco <nome> [minuti] [--thp always|madvise|never]
#   sh rf35h-kbench.sh confronta <nome-a> <nome-b>
#
# Nato per le prove della v1.3.1 (7/10/2026): il kernel compilato con
# -mtune=cortex-a35 e le huge page trasparenti (THP) in "madvise" invece di
# "always". Prima i numeri, poi le modifiche (come rf35h-bench).
#
# salva: microbenchmark del kernel, N giri (default 5), mediana. Durante le
# misure governor "performance" (con ondemand la frequenza cambierebbe sotto le
# misure) e RetroArch fermo (il menu disegna 60 volte al secondo). Alla fine
# governor, huge page e RetroArch tornano com'erano.
#   pipe       perf bench sched pipe          cambi di contesto, usecs/op
#   messaging  perf bench sched messaging     scheduler e socket, secondi
#   syscall    perf bench syscall basic       una chiamata di sistema, usecs/op
#   futex      perf bench futex hash          lock del kernel, operazioni/s
#   dd         da /dev/zero a /dev/null, 4 GB a blocchi di 64 KB, MB/s:
#              le copie e gli azzeramenti del kernel
#   memcpy     perf bench mem memcpy, GB/s: copia di 64 MB in spazio utente.
#              Fra due kernel fa da controllo (non deve cambiare); con --thp
#              e' la stessa copia su pagine da 2 MB o da 4 KB
# piu' i contatori di huge page e compattazione (/proc/vmstat) e la
# temperatura. Nessuna di queste prove salta qua e la' in molti MB di memoria,
# che e' dove le huge page aiutano (meno miss del TLB): per quello c'e' "core".
#
# core: un gioco vero, sempre lo stesso pezzo. Fermato il servizio, RetroArch
# carica <core> (il nome, es. mupen64plus_next, o il percorso del .so) e <rom>,
# con --stato N lo stato salvato nello slot N (salvalo in un punto pesante del
# gioco), gira --frames fotogrammi (default 3600, un minuto a 60 Hz) senza
# input ed esce da solo (--max-frames). Misura con perf stat il tempo di CPU di
# RetroArch per quei fotogrammi (a 60 fps fissi: meno CPU = piu' margine), la
# durata e, al 90%, la memoria del processo (Rss + swap, e quanta in huge
# page). Con --thp always,madvise le corse si alternano, una per modalita' a
# ogni giro (default 5), dopo una di riscaldamento che non conta; alla fine il
# confronto. Gira su una copia di retroarch.cfg senza salvataggio della config,
# stati automatici, achievement, cronologia e tempo di gioco, con i salvataggi
# del gioco (.srm) copiati in una cartella temporanea: i tuoi non li tocca. I
# core che scrivono da se' (PPSSPP, memory card condivise) scrivono dove
# scrivono sempre, ma senza input e' raro che il gioco salvi.
#
# gioco: mentre giochi (lancialo da ssh e gioca per i minuti indicati) conta le
# compattazioni della memoria, le huge page create, lo swap su zram, e alla
# fine la memoria del sistema e di RetroArch. Con --thp prima riavvia
# RetroArch, cosi' tutta la sua memoria segue quella modalita'; alla fine la
# modalita' torna com'era. Se cade la ssh va avanti e scrive lo stesso.
#
# confronta: le mediane una accanto all'altra. "meglio" o "peggio" solo se
# tutti i giri di una parte stanno oltre tutti quelli dell'altra; se si
# sovrappongono e' rumore, anche quando la mediana si sposta.
#
# Tutto in /storage/kbench/.
set -u

DIR="${RF35H_KBENCH_DIR:-/storage/kbench}"
CPUFREQ="${RF35H_CPUFREQ:-/sys/devices/system/cpu/cpu0/cpufreq}"
THP="${RF35H_THP:-/sys/kernel/mm/transparent_hugepage/enabled}"
VMSTAT="${RF35H_VMSTAT:-/proc/vmstat}"
MEMINFO="${RF35H_MEMINFO:-/proc/meminfo}"
TEMP="${RF35H_TEMP:-/sys/class/thermal/thermal_zone0/temp}"
PERF="${RF35H_PERF:-perf}"
SYSTEMCTL="${RF35H_SYSTEMCTL:-systemctl}"
RA="${RF35H_RA:-/usr/bin/retroarch}"
RA_CFG="${RF35H_RA_CFG:-/storage/.config/retroarch/retroarch.cfg}"
RA_ENV="${RF35H_RA_ENV:-/usr/lib/retroarch/retroarch-env.conf}"
RA_RUNENV="${RF35H_RA_RUNENV:-/run/libreelec/retroarch.conf}"
CORES="${RF35H_CORES:-/tmp/cores}"
# fotogrammi al secondo del pannello: servono solo per i tempi di attesa di
# "core" (le prove lo abbassano per fare presto)
FPS="${RF35H_KBENCH_FPS:-60}"

uso() {
	echo "uso: sh $0 salva <nome> [--thp always|madvise|never] [--giri N]" >&2
	echo "     sh $0 core <nome> <core> <rom> [--thp always,madvise] [--stato N] [--frames N] [--giri N]" >&2
	echo "     sh $0 gioco <nome> [minuti] [--thp always|madvise|never]" >&2
	echo "     sh $0 confronta <nome-a> <nome-b>" >&2
	exit 1
}

rd() { [ -r "$1" ] && cat "$1" 2>/dev/null || echo "?"; }
cs() { awk '{ printf "%d", $1 * 100 }' /proc/uptime; }
temp_c() { t="$(rd "${TEMP}")"; case "${t}" in ''|*[!0-9]*) echo "?" ;; *) echo $(( t / 1000 )) ;; esac; }
# la modalita' attiva e' quella fra parentesi quadre: "always [madvise] never"
thp_now() { sed -n 's/.*\[\([a-z]*\)\].*/\1/p; t; p' "${THP}" 2>/dev/null; }
nome_ok() { case "$1" in ''|*[!A-Za-z0-9_.-]*) echo "nome vuoto o con caratteri strani: '$1'" >&2; exit 1 ;; esac; }
ra_pid() { pidof retroarch 2>/dev/null | awk '{ print $1 }'; }
# Rss, swap e huge page anonime di un processo, in kB ("? ? ?" se non si legge)
mem_proc() {
	if [ -n "${1:-}" ] && [ -r "/proc/$1/smaps_rollup" ]; then
		awk '/^Rss:/ { r = $2 } /^Swap:/ { s = $2 } /^AnonHugePages:/ { h = $2 }
			END { if (r == "") print "? ? ?"; else printf "%d %d %d\n", r, s, h + 0 }' "/proc/$1/smaps_rollup"
	else
		echo "? ? ?"
	fi
}
# tempo di CPU di un processo (tutti i suoi thread e i figli attesi), in
# centesimi di secondo: campi 14-17 di /proc/<pid>/stat, contati dopo la ")"
# del nome, che puo' contenere spazi
cpu_ticks() {
	if [ -n "${1:-}" ] && [ -r "/proc/$1/stat" ]; then
		sed 's/.*) //' "/proc/$1/stat" | awk '{ print $12 + $13 + $14 + $15 }'
	else
		echo "?"
	fi
}

# mediana dei numeri sullo stdin (anche decimali, separati da spazi o a capo;
# gli altri, come "?", non contano). Dallo stdin e non come argomenti: un "?"
# non quotato la shell lo espanderebbe come glob.
mediana() {
	tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -n | awk '{ v[NR] = $1 } END {
		if (NR == 0) { print "?"; exit }
		if (NR % 2) print v[(NR + 1) / 2]; else printf "%.6g\n", (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

# ---- confronto ---------------------------------------------------------------
# Le chiavi finiscono in _basso (meglio se scende) o _alto (meglio se sale);
# <prova>_giri ha i valori dei singoli giri. Verdetto solo se i giri delle due
# parti non si sovrappongono: con 5 giri contro 5 succede per caso 2 volte su
# 252 (la probabilita' la stampa per i giri che ci sono).
confronta() {
	a="${DIR}/$1.txt"; b="${DIR}/$2.txt"
	[ -f "${a}" ] || { echo "non trovo ${a}" >&2; exit 1; }
	[ -f "${b}" ] || { echo "non trovo ${b}" >&2; exit 1; }
	echo "== $1 -> $2"
	awk -v A="$1" -v B="$2" -v Q="'" '
		function num(x) { return (x ~ /^-?[0-9]+(\.[0-9]+)?([eE][-+]?[0-9]+)?$/) }
		function giri(s, arr,   n, i, t, k) {
			n = split(s, t, " "); k = 0
			for (i = 1; i <= n; i++) if (num(t[i])) arr[++k] = t[i] + 0
			return k
		}
		{
			f = (FILENAME == ARGV[1]) ? "a" : "b"
			k = $1; v = $0; sub(/^[^ ]+ */, "", v)
			if (k ~ /^vm[01]$/) next
			if (!(k in visto)) { visto[k] = 1; ord[++no] = k }
			val[f ":" k] = v
		}
		END {
			for (i = 1; i <= no; i++) {
				k = ord[i]
				if (k !~ /_(basso|alto)$/) continue
				if (!((("a:" k) in val) && (("b:" k) in val))) continue
				x = val["a:" k]; y = val["b:" k]
				if (!num(x) || !num(y) || x + 0 == 0) { printf "  %-22s %12s %12s\n", k, x, y; continue }
				d = (y - x) / x * 100
				bene = (k ~ /_basso$/) ? (d < 0) : (d > 0)
				g = k; sub(/_(basso|alto)$/, "_giri", g)
				na = (("a:" g) in val) ? giri(val["a:" g], ga) : 0
				nb = (("b:" g) in val) ? giri(val["b:" g], gb) : 0
				if (na >= 2 && nb >= 2) {
					mina = maxa = ga[1]; for (j = 2; j <= na; j++) { if (ga[j] < mina) mina = ga[j]; if (ga[j] > maxa) maxa = ga[j] }
					minb = maxb = gb[1]; for (j = 2; j <= nb; j++) { if (gb[j] < minb) minb = gb[j]; if (gb[j] > maxb) maxb = gb[j] }
					if (maxa < minb || maxb < mina) giudizio = bene ? "meglio" : "peggio"
					else giudizio = "= rumore"
					c = 1; for (j = 1; j <= na; j++) c = c * (nb + j) / j
					if (200 / c > pmax) pmax = 200 / c
					conGiri = 1
				} else {
					giudizio = "(una misura sola)"
					uno = 1
				}
				printf "  %-22s %12s %12s  %+6.1f%%  %s\n", k, x, y, d, giudizio
			}
			if (conGiri) printf "(meglio/peggio: tutti i giri di una parte oltre tutti quelli dell%saltra,\n che per caso succede al massimo il %.1f%% delle volte; \"= rumore\": i giri\n si sovrappongono, anche se la mediana si e%s spostata)\n", Q, pmax, Q
			if (uno) print "(una misura sola: conta solo una differenza grande)"

			h = 0
			for (i = 1; i <= no; i++) {
				k = ord[i]
				if (k ~ /_(basso|alto|giri)$/ || k ~ /^info_/) continue
				if (!((("a:" k) in val) && (("b:" k) in val))) continue
				split(val["a:" k], xa, " "); split(val["b:" k], xb, " ")
				if (!num(xa[1]) || !num(xb[1]) || xa[1] == xb[1]) continue
				if (!h) { print "-- altri numeri, senza giudizio (solo quelli diversi)"; h = 1 }
				printf "  %-34s %12s %12s\n", k, xa[1], xb[1]
			}

			print "-- condizioni (" A " | " B ")"
			for (i = 1; i <= no; i++) {
				k = ord[i]
				if (k !~ /^info_/) continue
				x = (("a:" k) in val) ? val["a:" k] : "-"
				y = (("b:" k) in val) ? val["b:" k] : "-"
				n = k; sub(/^info_/, "", n)
				if (x == y) printf "  %-20s %s (uguale)\n", n, x
				else if (length(x) + length(y) < 56) printf "  %-20s %s | %s\n", n, x, y
				else printf "  %s\n    %s: %s\n    %s: %s\n", n, A, x, B, y
			}
		}' "${a}" "${b}"
}

# ---- ripristino --------------------------------------------------------------
GOV_PRIMA=""; THP_PRIMA=""; RA_FERMATO=""; RA_BENCH=""; T=""
ripristina() {
	# un RetroArch lanciato da "core" e ancora acceso (Ctrl+C a meta' corsa:
	# in uno script i comandi in background ignorano SIGINT)
	if [ -n "${RA_BENCH}" ]; then
		pkill -x retroarch 2>/dev/null; sleep 2; pkill -9 -x retroarch 2>/dev/null
		RA_BENCH=""
	fi
	[ -n "${GOV_PRIMA}" ] && echo "${GOV_PRIMA}" > "${CPUFREQ}/scaling_governor" 2>/dev/null
	[ -n "${THP_PRIMA}" ] && echo "${THP_PRIMA}" > "${THP}" 2>/dev/null
	[ -n "${RA_FERMATO}" ] && "${SYSTEMCTL}" start retroarch 2>/dev/null
	[ -n "${T}" ] && rm -rf "${T}"
	GOV_PRIMA=""; THP_PRIMA=""; RA_FERMATO=""; T=""
}

ferma_retroarch() {
	if command -v "${SYSTEMCTL}" >/dev/null 2>&1 && "${SYSTEMCTL}" is-active -q retroarch 2>/dev/null; then
		echo "fermo RetroArch durante le misure (lo rimetto alla fine)"
		"${SYSTEMCTL}" stop retroarch && RA_FERMATO=1
		sleep 2
	fi
}
performance() {
	if [ -w "${CPUFREQ}/scaling_governor" ]; then
		GOV_PRIMA="$(rd "${CPUFREQ}/scaling_governor")"
		echo performance > "${CPUFREQ}/scaling_governor"
	fi
}
governor_info() { echo "$(rd "${CPUFREQ}/scaling_governor") a $(rd "${CPUFREQ}/scaling_cur_freq") kHz (prima: ${GOV_PRIMA:-non cambiato})"; }

# ---- salva: microbenchmark ---------------------------------------------------
NOME=""; THP_SET=""; GIRI=5

# una prova: chiave del risultato, programma awk che lo estrae dall'output,
# comando
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
	m="$(echo "${valori}" | mediana)"
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
	nome_ok "${NOME}"
	command -v "${PERF}" >/dev/null 2>&1 || { echo "manca perf" >&2; exit 2; }
	mkdir -p "${DIR}" || exit 1
	OUT="${DIR}/${NOME}.txt"; RAW="${DIR}/${NOME}.grezzo.txt"
	: > "${OUT}"; : > "${RAW}"
	# anche se cade la ssh (HUP) o si chiude la pipe di chi legge (PIPE)
	trap 'ripristina; exit 130' INT TERM HUP PIPE
	trap 'ripristina' EXIT

	grep -E '^(thp_|compact_)' "${VMSTAT}" > "${DIR}/.vm0" 2>/dev/null
	{
		echo "info_kernel $(rd /proc/version)"
		echo "info_avvio $(date '+%Y-%m-%d %H:%M') uptime $(cut -d' ' -f1 /proc/uptime)s"
	} >> "${OUT}"

	ferma_retroarch
	performance
	if [ -n "${THP_SET}" ]; then
		THP_PRIMA="$(thp_now)"
		echo "${THP_SET}" > "${THP}" || { echo "non riesco a scrivere ${THP}" >&2; exit 1; }
	fi
	{
		echo "info_thp $(thp_now)"
		echo "info_governor $(governor_info)"
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

# ---- core: un gioco vero -----------------------------------------------------
CORE=""; ROM=""; STATO=""; FRAMES=3600; THP_LISTA=""
VMK='^(thp_fault_alloc|thp_fault_fallback|thp_collapse_alloc|compact_stall|pswpout) '

# copia di retroarch.cfg per le corse: niente che scriva fuori da ${T}, e il
# log su stderr (cioe' nel log della misura) anche se la config lo manda su file
core_config() {
	grep -v -E '^[[:space:]]*(config_save_on_exit|savestate_auto_load|savestate_auto_save|cheevos_enable|history_list_enable|content_runtime_log|content_runtime_log_aggregate|savefile_directory|savefiles_in_content_dir|log_to_file)[[:space:]]*=' \
		"${RA_CFG}" > "${T}/ra.cfg"
	cat >> "${T}/ra.cfg" <<EOF
config_save_on_exit = "false"
savestate_auto_load = "false"
savestate_auto_save = "false"
cheevos_enable = "false"
history_list_enable = "false"
content_runtime_log = "false"
content_runtime_log_aggregate = "false"
savefiles_in_content_dir = "false"
savefile_directory = "${T}/sram"
log_to_file = "false"
EOF
	# i salvataggi di questo gioco (stesso nome della rom, anche nelle
	# sottocartelle per core), copiati: il gioco parte come sempre, ma quello
	# che scrive uscendo resta qui
	sd="$(sed -n 's/^[[:space:]]*savefile_directory[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${RA_CFG}" | tail -1)"
	case "${sd}" in "~"/*) sd="${HOME:-/storage}${sd#\~}" ;; esac
	grep -q -E '^[[:space:]]*savefiles_in_content_dir[[:space:]]*=[[:space:]]*"true"' "${RA_CFG}" && sd=""
	[ -z "${sd}" ] || [ "${sd}" = default ] && sd="$(dirname "${ROM}")"
	mkdir -p "${T}/sram"
	n=0
	if [ -d "${sd}" ]; then
		( cd "${sd}" && find . -maxdepth 2 -type f -name "${pat}.*" ! -name "*.state*" 2>/dev/null ) > "${T}/sram.lista"
		while IFS= read -r f; do
			mkdir -p "${T}/sram/$(dirname "${f}")" && cp -p "${sd}/${f}" "${T}/sram/${f}" && n=$((n + 1))
		done < "${T}/sram.lista"
	fi
	echo "salvataggi del gioco: ${n} file copiati da ${sd} (gli originali non si toccano)"
}

# una corsa: $1 modalita' THP, $2 etichetta. Risultati in ${T}/r.*
core_corsa() {
	m="$1"; lab="$2"
	echo "${m}" > "${THP}" 2>/dev/null || { echo "non riesco a scrivere ${THP}" >&2; exit 1; }
	rm -f "${T}"/r.* "${T}/perf.txt"
	grep -E "${VMK}" "${VMSTAT}" > "${T}/vm0" 2>/dev/null
	printf '\n### %s, THP %s, %s\n' "${lab}" "${m}" "$(date '+%H:%M:%S')" >> "${LOG}"
	RA_BENCH=1
	t0="$(cs)"
	"${PERF}" stat -x ';' -o "${T}/perf.txt" -e task-clock,cycles,instructions -- \
		"${RA}" --verbose --config="${T}/ra.cfg" -L "${CORE_SO}" ${STATO:+"--entryslot=${STATO}"} \
		--max-frames="${FRAMES}" "${ROM}" </dev/null >> "${LOG}" 2>&1 &
	p=$!
	# in parallelo: memoria e frequenza al 90%, e limite di tempo. La fine si
	# prende con wait, al centesimo.
	( n=0
	  while kill -0 "${p}" 2>/dev/null; do
		sleep 1; n=$((n + 1))
		if [ "${n}" -eq "${CAMP}" ]; then
			mem_proc "$(ra_pid)" > "${T}/r.mem"
			rd "${CPUFREQ}/scaling_cur_freq" > "${T}/r.khz"
		fi
		[ "${n}" -eq "${TMAX}" ] && { : > "${T}/r.timeout"; pkill -x retroarch; }
		[ "${n}" -eq $(( TMAX + 15 )) ] && pkill -9 -x retroarch
	  done ) 2>/dev/null &
	w=$!
	wait "${p}"; rc=$?
	t1="$(cs)"
	RA_BENCH=""
	kill "${w}" 2>/dev/null; wait "${w}" 2>/dev/null
	grep -E "${VMK}" "${VMSTAT}" > "${T}/vm1" 2>/dev/null

	R_DUR="$(awk -v d="$(( t1 - t0 ))" 'BEGIN { printf "%.1f", d / 100 }')"
	R_CPU="$(awk -F';' '$3 ~ /^task-clock/ && $1 ~ /^[0-9.]+$/ { printf "%.2f", $1 / 1000; exit }' "${T}/perf.txt" 2>/dev/null)"
	R_IPC="$(awk -F';' '$3 ~ /^cycles/ && $1 ~ /^[0-9]+$/ { c = $1 } $3 ~ /^instructions/ && $1 ~ /^[0-9]+$/ { i = $1 }
		END { if (c > 0 && i > 0) printf "%.3f", i / c }' "${T}/perf.txt" 2>/dev/null)"
	R_VM="$(awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) { printf "%s%s=%d", s, $1, $2 - a[$1]; s = " " }' "${T}/vm0" "${T}/vm1" 2>/dev/null)"
	R_KHZ="$(rd "${T}/r.khz")"
	R_MEM="?"; R_THP="?"
	mp="$(rd "${T}/r.mem")"
	r1="${mp%% *}"; mp="${mp#* }"; r2="${mp%% *}"; r3="${mp#* }"
	case "${r1}:${r2}:${r3}" in
		*[!0-9:]*|:*|*::*|*:) ;;
		*) R_MEM=$(( (r1 + r2) / 1024 )); R_THP=$(( r3 / 1024 )) ;;
	esac

	# Una corsa che non e' arrivata in fondo non si conta. Non dal codice di
	# uscita: c'e' chi va in crash chiudendo, dopo aver fatto i suoi
	# fotogrammi. Dalla durata: con il vsync, N fotogrammi non stanno in meno di
	# N/60 secondi.
	corta="$(awk -v d="${R_DUR}" -v f="${FRAMES}" -v fps="${FPS}" 'BEGIN { print (d < 0.9 * f / fps) ? 1 : 0 }')"
	if [ -e "${T}/r.timeout" ] || [ "${corta}" = 1 ] || [ -z "${R_CPU}" ]; then
		echo "corsa non riuscita (${lab}): uscita ${rc} dopo ${R_DUR} s$([ -e "${T}/r.timeout" ] && echo ", fermata a ${TMAX} s")." >&2
		echo "Il gioco e' partito? (O il vsync e' spento: allora i fotogrammi vanno piu' veloci di 60 al secondo.)" >&2
		echo "Ultime righe di ${LOG}:" >&2
		tail -n 15 "${LOG}" >&2
		exit 1
	fi
	[ "${rc}" -ne 0 ] && echo "  (RetroArch e' uscito con ${rc}, ma dopo i suoi fotogrammi: la corsa vale)"
	return 0
}

core() {
	nome_ok "${NOME}"
	case "${CORE}" in
		*/*) CORE_SO="${CORE}" ;;
		*)   CORE_SO="${CORES}/${CORE%_libretro.so}_libretro.so" ;;
	esac
	[ -f "${CORE_SO}" ] || { echo "non trovo il core ${CORE_SO}" >&2; exit 1; }
	[ -f "${ROM}" ] || { echo "non trovo il gioco ${ROM}" >&2; exit 1; }
	[ -x "${RA}" ] || { echo "non trovo ${RA}" >&2; exit 1; }
	[ -f "${RA_CFG}" ] || { echo "non trovo ${RA_CFG}" >&2; exit 1; }
	command -v "${PERF}" >/dev/null 2>&1 || { echo "manca perf" >&2; exit 2; }
	[ -n "${THP_LISTA}" ] || THP_LISTA="$(thp_now)"
	modi="$(echo "${THP_LISTA}" | tr ',' ' ')"
	for m in ${modi}; do
		case "${m}" in always|madvise|never) ;; *) echo "modalita' THP sconosciuta: ${m}" >&2; exit 1 ;; esac
	done
	# shellcheck disable=SC2086  # elenco di parole
	set -- ${modi}
	nmodi=$#

	# il nome dei file del gioco (salvataggi, stati) e lo stesso nome come
	# pattern di find, con [ ] * ? protetti: le rom hanno spesso "[!]"
	base="$(basename "${ROM}")"; base="${base%.*}"
	pat="$(printf '%s' "${base}" | sed 's/[][*?\\]/\\&/g')"
	# lo stato chiesto deve esserci, altrimenti RetroArch partirebbe da capo
	# senza dirlo e si misurerebbe un'altra cosa. Nomi come RetroArch: slot 0
	# <gioco>.state, slot N <gioco>.stateN (o .stateN.entry)
	if [ -n "${STATO}" ]; then
		ss="$(sed -n 's/^[[:space:]]*savestate_directory[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "${RA_CFG}" | tail -1)"
		case "${ss}" in "~"/*) ss="${HOME:-/storage}${ss#\~}" ;; esac
		grep -q -E '^[[:space:]]*savestates_in_content_dir[[:space:]]*=[[:space:]]*"true"' "${RA_CFG}" && ss=""
		[ -z "${ss}" ] || [ "${ss}" = default ] && ss="$(dirname "${ROM}")"
		sn=""; [ "${STATO}" -gt 0 ] && sn="${STATO}"
		if ! ( cd "${ss}" 2>/dev/null && find . -maxdepth 2 -type f \( -name "${pat}.state${sn}" -o -name "${pat}.state${STATO}.entry" \) ) | grep -q .; then
			echo "non trovo lo stato ${STATO} di \"${base}\" in ${ss}: salvalo dal menu rapido (slot ${STATO}) e rilancia" >&2
			exit 1
		fi
	fi

	mkdir -p "${DIR}" || exit 1
	LOG="${DIR}/${NOME}.retroarch.log"; : > "${LOG}"
	# niente core dump se RetroArch cade: sarebbero centinaia di MB in /storage
	# shellcheck disable=SC3045  # ulimit -c: ce l'hanno ash della busybox e dash
	ulimit -c 0 2>/dev/null
	# cosi' fra il primo comando e l'ultimo i tempi sono quelli giusti anche se
	# cade la ssh: va avanti e alla fine scrive i file
	trap '' HUP
	trap 'ripristina; exit 130' INT TERM
	trap 'ripristina' EXIT
	T="$(mktemp -d)" || exit 1

	# l'ambiente del servizio retroarch (Wayland di sway, ALSA, librerie)
	set -a
	# shellcheck disable=SC1090
	[ -r "${RA_ENV}" ] && . "${RA_ENV}"
	# shellcheck disable=SC1090
	[ -r "${RA_RUNENV}" ] && . "${RA_RUNENV}"
	set +a
	core_config

	ferma_retroarch
	if [ -n "$(ra_pid)" ]; then
		echo "c'e' ancora un RetroArch acceso che non e' il servizio: chiudilo e rilancia" >&2
		exit 1
	fi
	performance
	THP_PRIMA="$(thp_now)"
	CAMP=$(( FRAMES * 9 / (FPS * 10) )); [ "${CAMP}" -ge 1 ] || CAMP=1
	TMAX=$(( FRAMES * 3 / FPS + 120 ))
	MAXKHZ="$(rd "${CPUFREQ}/scaling_max_freq")"
	AVVIO="$(date '+%Y-%m-%d %H:%M') uptime $(cut -d' ' -f1 /proc/uptime)s"
	GOVINFO="$(governor_info)"
	TEMP0="$(temp_c)"
	echo "== ${NOME}: $(basename "${CORE_SO}"), $(basename "${ROM}")${STATO:+, stato ${STATO}}, ${FRAMES} fotogrammi"
	echo "   THP ${THP_LISTA}, ${GIRI} giri, prima una corsa di riscaldamento. Non toccare la console."

	core_corsa "$1" "riscaldamento"
	echo "  riscaldamento (${1}): CPU ${R_CPU} s, ${R_DUR} s"
	g=1
	while [ "${g}" -le "${GIRI}" ]; do
		for m in ${modi}; do
			core_corsa "${m}" "giro ${g}"
			echo "${R_CPU}" >> "${T}/${m}.cpu"; echo "${R_DUR}" >> "${T}/${m}.dur"
			echo "${R_MEM}" >> "${T}/${m}.mem"; echo "${R_THP}" >> "${T}/${m}.thp"
			[ -n "${R_IPC}" ] && echo "${R_IPC}" >> "${T}/${m}.ipc"
			echo "${R_KHZ}" >> "${T}/${m}.khz"; echo "${R_VM}" >> "${T}/${m}.vm"
			case "${R_KHZ}" in
				''|*[!0-9]*) ;;
				*) case "${MAXKHZ}" in ''|*[!0-9]*) ;; *) [ "${R_KHZ}" -lt "${MAXKHZ}" ] && CALDO=1 ;; esac ;;
			esac
			printf '  %-8s giro %d: CPU %6s s, %6s s, memoria %4s MB (huge page %s MB)%s\n' "${m}" "${g}" \
				"${R_CPU}" "${R_DUR}" "${R_MEM}" "${R_THP}" "${R_IPC:+, IPC ${R_IPC}}"
		done
		g=$((g + 1))
	done
	TEMP1="$(temp_c)"

	for m in ${modi}; do
		if [ "${nmodi}" -gt 1 ]; then out="${DIR}/${NOME}-${m}.txt"; else out="${DIR}/${NOME}.txt"; fi
		{
			echo "info_kernel $(rd /proc/version)"
			echo "info_avvio ${AVVIO}"
			echo "info_core ${CORE_SO}"
			echo "info_gioco ${ROM}${STATO:+ (stato ${STATO})}"
			echo "info_misura ${FRAMES} fotogrammi, ${GIRI} giri"
			echo "info_thp ${m}"
			echo "info_governor ${GOVINFO}"
			echo "info_temperatura_inizio ${TEMP0} C"
			echo "info_temperatura_fine ${TEMP1} C"
			echo "info_cpu_mhz $(awk '/^[0-9]+$/ { printf "%s%d", s, $1 / 1000; s = " " }' "${T}/${m}.khz")"
			echo "info_huge_page_mb $(tr '\n' ' ' < "${T}/${m}.thp")"
			echo "info_vmstat $(tr ' ' '\n' < "${T}/${m}.vm" | awk -F= 'NF == 2 { if (!($1 in s)) o[++n] = $1; s[$1] += $2 }
				END { for (i = 1; i <= n; i++) printf "%s%s=%d", (i > 1 ? " " : ""), o[i], s[o[i]] }')"
			# chiave e file dei valori: la mediana, poi i giri per "confronta"
			for kf in cpu_s_basso:cpu durata_s_basso:dur memoria_mb_basso:mem ipc_alto:ipc; do
				k="${kf%:*}"; f="${T}/${m}.${kf#*:}"
				[ -s "${f}" ] || continue
				echo "${k} $(mediana < "${f}")"
				echo "${k%_*}_giri $(tr '\n' ' ' < "${f}" | sed 's/ $//')"
			done
		} > "${out}"
		echo "  ${m}: ${out}"
	done
	echo "  log di RetroArch: ${LOG}"
	[ -n "${CALDO:-}" ] && echo "ATTENZIONE: in qualche corsa la CPU non era al massimo (${MAXKHZ} kHz): throttling termico? Tempi di CPU poco confrontabili."
	if [ "${nmodi}" -gt 1 ]; then
		first="$1"; shift
		for m in "$@"; do confronta "${NOME}-${first}" "${NOME}-${m}"; done
	fi
}

# ---- gioco: contatori mentre giochi -------------------------------------------
gioco() {
	nome_ok "${NOME}"
	mkdir -p "${DIR}" || exit 1
	OUT="${DIR}/${NOME}.txt"
	# se cade la ssh si va avanti: i risultati finiscono comunque nel file
	trap '' HUP PIPE
	trap 'ripristina; exit 130' INT TERM
	trap 'ripristina' EXIT
	if [ -n "${THP_SET}" ]; then
		THP_PRIMA="$(thp_now)"
		echo "${THP_SET}" > "${THP}" || { echo "non riesco a scrivere ${THP}" >&2; exit 1; }
		if "${SYSTEMCTL}" is-active -q retroarch 2>/dev/null; then
			echo "riavvio RetroArch, cosi' tutta la sua memoria segue THP ${THP_SET}"
			"${SYSTEMCTL}" restart retroarch
			sleep 5
		fi
	fi
	p0="$(ra_pid)"; c0="$(cpu_ticks "${p0}")"; s0="$(cs)"
	grep -E '^(thp_|compact_|pswp|pgmajfault)' "${VMSTAT}" > "${DIR}/.vm0" 2>/dev/null
	echo "== ${NOME}: THP $(thp_now), ${MIN} minuti. Gioca: alla fine scrivo i contatori."
	sleep $(( MIN * 60 ))
	grep -E '^(thp_|compact_|pswp|pgmajfault)' "${VMSTAT}" > "${DIR}/.vm1" 2>/dev/null
	p1="$(ra_pid)"; c1="$(cpu_ticks "${p1}")"; s1="$(cs)"
	mp="$(mem_proc "${p1}")"
	r1="${mp%% *}"; mp="${mp#* }"; r2="${mp%% *}"; r3="${mp#* }"
	{
		echo "info_kernel $(rd /proc/version)"
		echo "info_thp $(thp_now)"
		echo "info_gioco ${MIN} minuti, fine $(date '+%Y-%m-%d %H:%M')"
		awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) { printf "%s_delta_basso %d\n", $1, $2 - a[$1] }' \
			"${DIR}/.vm0" "${DIR}/.vm1" | grep -E '^(compact_stall|compact_fail|thp_fault_fallback|pgmajfault|pswpin|pswpout)_'
		awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) { printf "%s_delta %d\n", $1, $2 - a[$1] }' \
			"${DIR}/.vm0" "${DIR}/.vm1" | grep -vE '^(compact_stall|compact_fail|thp_fault_fallback|pgmajfault|pswpin|pswpout)_'
		grep -E '^(MemTotal|MemAvailable|AnonHugePages|SwapTotal|SwapFree):' "${MEMINFO}" | sed 's/: */ /; s/^/mem_/'
		# RetroArch alla fine: memoria (Rss + swap) e quanta in huge page; la
		# CPU solo se nel frattempo non si e' riavviato
		case "${r1}:${r2}:${r3}" in
			*[!0-9:]*|:*|*::*|*:) echo "info_retroarch non letto (pid ${p1:-nessuno})" ;;
			*) echo "ra_memoria_mb_basso $(( (r1 + r2) / 1024 ))"; echo "ra_huge_page_mb $(( r3 / 1024 ))" ;;
		esac
		if [ -n "${p0}" ] && [ "${p0}" = "${p1}" ] && [ "${c0}" != "?" ] && [ "${c1}" != "?" ]; then
			awk -v c="$(( c1 - c0 ))" -v s="$(( s1 - s0 ))" 'BEGIN { if (s > 0) printf "ra_cpu_pct %.1f\n", c / s * 100 }'
		fi
	} > "${OUT}"
	rm -f "${DIR}/.vm0" "${DIR}/.vm1"
	grep -E '_delta|^mem_|^ra_|^info_retroarch' "${OUT}" | sed 's/^/  /'
	echo "tutto in ${OUT}"
}

# ---- argomenti ------------------------------------------------------------------
numero() { case "${1:-}" in ''|*[!0-9]*) uso ;; esac; }
case "${1:-}" in
	salva)
		[ $# -ge 2 ] || uso
		NOME="$2"; shift 2
		while [ $# -gt 0 ]; do
			case "$1" in
				--thp)  case "${2:-}" in always|madvise|never) THP_SET="$2" ;; *) uso ;; esac; shift 2 ;;
				--giri) numero "${2:-}"; GIRI="$2"; shift 2 ;;
				*) uso ;;
			esac
		done
		salva ;;
	core)
		[ $# -ge 4 ] || uso
		NOME="$2"; CORE="$3"; ROM="$4"; shift 4
		while [ $# -gt 0 ]; do
			case "$1" in
				--thp)    case "${2:-}" in ''|-*) uso ;; esac; THP_LISTA="$2"; shift 2 ;;
				--stato)  numero "${2:-}"; STATO="$2"; shift 2 ;;
				--frames) numero "${2:-}"; FRAMES="$2"; shift 2 ;;
				--giri)   numero "${2:-}"; GIRI="$2"; shift 2 ;;
				*) uso ;;
			esac
		done
		[ "${GIRI}" -ge 1 ] && [ "${FRAMES}" -ge 60 ] || uso
		core ;;
	gioco)
		[ $# -ge 2 ] || uso
		NOME="$2"; shift 2
		MIN=10
		case "${1:-}" in ''|-*) ;; *) numero "$1"; MIN="$1"; shift ;; esac
		while [ $# -gt 0 ]; do
			case "$1" in
				--thp) case "${2:-}" in always|madvise|never) THP_SET="$2" ;; *) uso ;; esac; shift 2 ;;
				*) uso ;;
			esac
		done
		gioco ;;
	confronta)
		[ $# -eq 3 ] || uso
		confronta "$2" "$3" ;;
	*) uso ;;
esac
