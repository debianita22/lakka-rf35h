#!/bin/sh
# rf35h-resume-diag.sh - clock, frequenze e kernel dell'RF35H prima e dopo lo standby
#
#   sh rf35h-resume-diag.sh prima        con la console che va bene, prima dello standby
#   sh rf35h-resume-diag.sh dopo         dopo il risveglio, con flicker e lentezza
#   sh rf35h-resume-diag.sh confronta    stato dei PLL e registri del CRU cambiati
#   sh rf35h-resume-diag.sh ripristina   (facoltativo) rimette CPLL/NPLL/GPLL nel modo di "prima"
#
# Legge i registri veri del CRU e del PMUCRU con devmem: il kernel non salva ne'
# ripristina nulla del CRU del PX30 in sospensione (clk-px30.c non ha
# suspend/resume), e la sua vista (clk_summary) resta quella che ha in cache.
# prima, dopo e confronta solo leggono; ripristina scrive soltanto i bit di
# modo di CPLL, NPLL e GPLL. Si copia sulla console e si lancia da ssh:
#   curl -fsSLo /storage/rf35h-resume-diag.sh \
#     https://raw.githubusercontent.com/debianita22/lakka-rf35h/main/tools/rf35h-resume-diag.sh
D="${RF35H_DIAG_DIR:-/storage/resume-diag}"
DM="${RF35H_DEVMEM:-devmem}"

rd() { "${DM}" "$1" 32; }
dump() {   # base, byte
	a=$(($1)); e=$((a + $2))
	while [ "${a}" -lt "${e}" ]; do printf '%08x %s\n' "${a}" "$(rd "${a}")"; a=$((a + 4)); done
}
# valore di un registro da un dump ($1 file, $2 indirizzo)
val() { awk -v k="$(printf '%08x' $(($2)))" '$1 == k { print $2 }' "$1"; }

# nome, PLL_CON0, registro del modo, shift del modo (drivers/clk/rockchip/clk-px30.c)
PLLS="APLL 0xff2b0000 0xff2b00a0 0
DPLL 0xff2b0020 0xff2b00a0 4
CPLL 0xff2b0040 0xff2b00a0 2
NPLL 0xff2b0060 0xff2b00a0 6
GPLL 0xff2bc000 0xff2bc020 0"

modo() { case "$1" in 0) echo slow ;; 1) echo normal ;; 2) echo deep ;; *) echo "?" ;; esac; }

# una riga per PLL da un dump: modo, MHz dai divisori, lock, power-down
pll_table() {   # $1 cartella
	echo "${PLLS}" | while read -r n c0 m sh; do
		f="$1/cru.txt"; case "${c0}" in 0xff2bc*) f="$1/pmucru.txt" ;; esac
		r0=$(($(val "${f}" "${c0}"))); r1=$(($(val "${f}" $((c0 + 4))))); rm_=$(($(val "${f}" "${m}")))
		fb=$((r0 & 0xfff)); p1=$(((r0 >> 12) & 7)); ref=$((r1 & 0x3f)); p2=$(((r1 >> 6) & 7))
		mhz="?"; [ "$((ref * p1 * p2))" -gt 0 ] && mhz=$((24 * fb / (ref * p1 * p2)))
		printf '  %s  %-6s %5s MHz  lock=%d pd=%d\n' "${n}" "$(modo $(((rm_ >> sh) & 3)))" "${mhz}" \
			$(((r1 >> 10) & 1)) $(((r1 >> 13) & 1))
	done
}

case "${1:-}" in
	prima|dopo)
		o="${D}/$1"; mkdir -p "${o}" || exit 1
		dump 0xff2b0000 0x400 > "${o}/cru.txt"
		dump 0xff2bc000 0x100 > "${o}/pmucru.txt"
		{
			echo "== $(date)  uptime $(cut -d' ' -f1 /proc/uptime)  $(grep -m1 VERSION= /etc/os-release)"
			echo "mem_sleep: $(cat /sys/power/mem_sleep 2>/dev/null)"
			for f in scaling_governor scaling_cur_freq cpuinfo_cur_freq scaling_max_freq; do
				echo "cpu0 ${f}: $(cat /sys/devices/system/cpu/cpu0/cpufreq/${f} 2>/dev/null)"
			done
			echo "cpu0 time_in_state:"; cat /sys/devices/system/cpu/cpu0/cpufreq/stats/time_in_state 2>/dev/null
			for d in /sys/class/devfreq/*; do
				[ -e "${d}/cur_freq" ] && echo "devfreq $(basename "${d}"): $(cat "${d}/governor") cur=$(cat "${d}/cur_freq") max=$(cat "${d}/max_freq")"
			done
			for c in /sys/class/thermal/cooling_device*; do
				[ -e "${c}/cur_state" ] && echo "cooling $(cat "${c}/type"): $(cat "${c}/cur_state")/$(cat "${c}/max_state")"
			done
			for t in /sys/class/thermal/thermal_zone*; do
				[ -e "${t}/temp" ] && echo "thermal $(cat "${t}/type"): $(cat "${t}/temp")"
			done
			echo "loadavg: $(cat /proc/loadavg)"
			s1="$(head -1 /proc/stat)"; ps -o pid,stat,time,comm > "${o}/ps1.txt" 2>&1
			cat /proc/interrupts > "${o}/irq1.txt"; sleep 5
			s2="$(head -1 /proc/stat)"; ps -o pid,stat,time,comm > "${o}/ps2.txt" 2>&1
			cat /proc/interrupts > "${o}/irq2.txt"
			# CPU occupata nei 5 s: (totale - idle - iowait) / totale
			echo "${s1}
${s2}" | awk '{ t = 0; for (i = 2; i <= NF; i++) t += $i; tot[NR] = t; idle[NR] = $5 + $6 }
				END { dt = tot[2] - tot[1]; if (dt > 0) printf "cpu occupata (5 s): %d%%\n", 100 * (dt - (idle[2] - idle[1])) / dt }'
		} > "${o}/stato.txt" 2>&1
		[ -r /sys/kernel/debug/clk/clk_summary ] && cp /sys/kernel/debug/clk/clk_summary "${o}/clk_summary.txt"
		dmesg > "${o}/dmesg.txt" 2>&1
		journalctl -b --no-pager -p warning > "${o}/journal-warning.txt" 2>&1
		echo "fatto: ${o}"
		pll_table "${o}"
		;;
	confronta)
		for x in prima dopo; do [ -s "${D}/${x}/cru.txt" ] || { echo "manca ${D}/${x}: lancia prima 'sh $0 ${x}'"; exit 1; }; done
		for x in prima dopo; do echo "PLL, ${x}:"; pll_table "${D}/${x}"; done
		for f in cru pmucru; do
			echo "registri ${f} cambiati (indirizzo, prima, dopo):"
			awk 'NR == FNR { a[$1] = $2; next } a[$1] != $2 { print "  " $1, a[$1], $2 }' \
				"${D}/prima/${f}.txt" "${D}/dopo/${f}.txt"
		done
		for x in prima dopo; do
			echo "cpu, gpu, termica, ${x}:"
			grep -E "^(mem_sleep|cpu0 scaling_(governor|cur)|cpu0 cpuinfo_cur|devfreq|cpu occupata|cooling|loadavg)" "${D}/${x}/stato.txt" | sed 's/^/  /'
		done
		;;
	ripristina)
		# Solo CPLL, NPLL e GPLL (display, bus, periferiche): APLL dipende dalla
		# tensione della CPU e DPLL e' la DDR, che gestisce il firmware. Solo se il
		# PLL adesso e' acceso e agganciato: il modo "normal" su un PLL spento
		# toglierebbe il clock a chi lo usa.
		[ -s "${D}/prima/cru.txt" ] || { echo "manca ${D}/prima"; exit 1; }
		echo "${PLLS}" | while read -r n c0 m sh; do
			case "${n}" in CPLL|NPLL|GPLL) ;; *) continue ;; esac
			f="${D}/prima/cru.txt"; case "${c0}" in 0xff2bc*) f="${D}/prima/pmucru.txt" ;; esac
			want=$((($(val "${f}" "${m}") >> sh) & 3))
			now=$((($(rd "${m}") >> sh) & 3))
			r1=$(($(rd $((c0 + 4)))))
			if [ "${want}" = "${now}" ]; then
				echo "  ${n}: gia' $(modo "${now}")"
			elif [ "$(((r1 >> 10) & 1))" != 1 ] || [ "$(((r1 >> 13) & 1))" != 0 ]; then
				echo "  ${n}: $(modo "${now}"), NON ripristinato: PLL spento o non agganciato"
			else
				"${DM}" "${m}" 32 $(((3 << (sh + 16)) | (want << sh)))
				echo "  ${n}: $(modo "${now}") -> $(modo "${want}")"
			fi
		done
		;;
	*)
		sed -n '2,7p' "$0"; exit 2 ;;
esac
