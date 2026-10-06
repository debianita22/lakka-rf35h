#!/bin/sh
# rf35h-display-dump.sh - lo stato del display, per confrontare "buono" e "rotto".
#
#   sh rf35h-display-dump.sh salva buono      subito dopo un avvio (schermo pulito)
#   sh rf35h-display-dump.sh rompi            spegne e riaccende lo schermo da sway
#                                             (riproduce sfarfallio e lentezza)
#   sh rf35h-display-dump.sh salva rotto      dopo "rompi"
#   sh rf35h-display-dump.sh confronta buono rotto
#   sh rf35h-display-dump.sh vop              interrupt del VOP al secondo (60 = buono)
#   sh rf35h-display-dump.sh ripara           58,5 Hz e ritorno a 60: riprogramma il
#                                             clock dei pixel
#
# Perche' (6/10/2026). Con la build ci-21 il DSI si accende prima dell'init del
# pannello e nessun comando va perso, eppure spegnere e riaccendere lo schermo
# (senza standby) basta a far sfarfallare l'immagine e rallentare la console;
# solo il riavvio la rimette a posto. Quindi qualcosa che il primo avvio fa e
# la riaccensione no, o viceversa. Qui si fotografa tutto quello che si puo'
# leggere: i registri di VOP, IOMMU del VOP, controller DSI, PHY DSI e GRF del
# VO, lo stato DRM, i clock, la frequenza degli interrupt (il VOP deve dare
# 60 interrupt al secondo), e due misure di velocita': CPU e memoria. Il
# confronto dice cosa cambia fra i due stati.
#
# Solo letture (devmem in lettura), niente di permanente.
set -u

DM="${RF35H_DEVMEM:-devmem}"
BASE="${RF35H_DISPLAY_DUMP_DIR:-/storage/display-diag}"

# nome | base | byte da leggere
REGIONI="
vop|0xff460000|0x400
vop-mmu|0xff460f00|0x40
dsi|0xff450000|0x100
dsi-phy|0xff2e0000|0x400
grf-vo|0xff140430|0x10
cru|0xff2b0000|0x300
pmucru|0xff2bc000|0x100
"

dump_regione() { # $1 base, $2 lunghezza
	b=$(( $1 )); n=$(( $2 )); o=0
	while [ "${o}" -lt "${n}" ]; do
		printf '%08x %s\n' $(( b + o )) "$("${DM}" $(( b + o )) 32 2>/dev/null || echo '?')"
		o=$(( o + 4 ))
	done
}

ms() { awk '{ printf "%d", $1 * 1000 }' /proc/uptime; }

irq_snap() { grep -E 'vop|dsi|gpu|mmu|mmc|dw-mci|i2c|arch_timer|rk817|rockchip' /proc/interrupts; }

salva() {
	D="${BASE}/$1"
	rm -rf "${D}"; mkdir -p "${D}"
	echo "salvo in ${D}"
	echo "${REGIONI}" | while IFS='|' read -r nome base len; do
		[ -n "${nome}" ] || continue
		dump_regione "${base}" "${len}" > "${D}/reg-${nome}.txt"
	done
	cat /sys/kernel/debug/dri/0/state > "${D}/drm-state.txt" 2>/dev/null
	grep -E 'dclk_vop|aclk_vo|hclk_vo|dsi|dphy|vopb|cpll|npll|gpll|apll|dpll|clk_gpu|aclk_gpu' \
		/sys/kernel/debug/clk/clk_summary > "${D}/clk.txt" 2>/dev/null
	cat /sys/kernel/debug/dri/0/vop* > "${D}/vop-debugfs.txt" 2>/dev/null
	# interrupt in 5 s
	irq_snap > "${D}/irq-a.txt"; sleep 5; irq_snap > "${D}/irq-b.txt"
	awk 'NR==FNR { for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i; a[$1] = s; s = 0; next }
	     { for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i
	       d = s - a[$1]; s = 0
	       if (d > 0) { $1 = $1; printf "%8.1f/s  %s\n", d / 5, $0 } }' \
		"${D}/irq-a.txt" "${D}/irq-b.txt" > "${D}/irq-rate.txt"
	# velocita': ciclo di shell (CPU) e copia in memoria (banda). Tempi da
	# /proc/uptime (centesimi): basta, i due lavori durano piu' di un secondo.
	t0=$(ms); i=0; while [ "${i}" -lt 300000 ]; do i=$((i + 1)); done; t1=$(ms)
	echo "cpu: ciclo 300000 in $(( t1 - t0 )) ms" > "${D}/velocita.txt"
	t0=$(ms); dd if=/dev/zero of=/dev/null bs=4M count=1000 2>/dev/null; t1=$(ms)
	echo "memoria: 4000 MB in $(( t1 - t0 )) ms" >> "${D}/velocita.txt"
	top -b -n 1 2>/dev/null | head -15 > "${D}/top.txt"
	cat "${D}/velocita.txt"
	echo "interrupt al secondo:"; sed 's/^/  /' "${D}/irq-rate.txt" | head -20
}

confronta() {
	A="${BASE}/$1"; B="${BASE}/$2"
	[ -d "${A}" ] && [ -d "${B}" ] || { echo "mancano ${A} o ${B}"; exit 1; }
	# Niente paste ne' diff: su Lakka "paste" e' pastebinit (carica su
	# paste.libreelec.tv) e diff non c'e'. Solo awk.
	for f in "${A}"/reg-*.txt; do
		n="$(basename "${f}")"
		echo "== ${n#reg-}: registri diversi (indirizzo, $1, $2)"
		awk 'FILENAME == ARGV[1] { a[$1] = $2; next } ($1 in a) && a[$1] != $2 { print "  " $1, a[$1], $2 }' \
			"${f}" "${B}/${n}"
	done
	echo "== velocita' ($1, poi $2)"; sed 's/^/  /' "${A}/velocita.txt" "${B}/velocita.txt"
	echo "== interrupt al secondo, $1"; sed 's/^/  /' "${A}/irq-rate.txt" | head -12
	echo "== interrupt al secondo, $2"; sed 's/^/  /' "${B}/irq-rate.txt" | head -12
	for f in drm-state.txt clk.txt; do
		echo "== ${f}: righe solo in $1 (<) o solo in $2 (>)"
		awk 'FILENAME == ARGV[1] { a[$0]++; next } { if (a[$0]) a[$0]--; else print "  > " $0 }' "${A}/${f}" "${B}/${f}" | head -30
		awk 'FILENAME == ARGV[1] { a[$0]++; next } { if (a[$0]) a[$0]--; else print "  < " $0 }' "${B}/${f}" "${A}/${f}" | head -30
	done
	( cd "${BASE}" && tar -czf "confronto-$1-$2.tar.gz" "$1" "$2" )
	echo "tutto in ${BASE}/confronto-$1-$2.tar.gz"
}

vop_hz() { # interrupt del VOP al secondo, su 3 s
	a=$(awk '/vop/ { s = 0; for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i; print s }' /proc/interrupts)
	sleep 3
	b=$(awk '/vop/ { s = 0; for (i = 2; i <= NF && $i ~ /^[0-9]+$/; i++) s += $i; print s }' /proc/interrupts)
	echo $(( (b - a) / 3 ))
}

sway_sock() {
	for s in /var/run/0-runtime-dir/sway-ipc.*.sock /run/0-runtime-dir/sway-ipc.*.sock; do
		[ -S "${s}" ] && S="${s}"
	done
	[ -n "${S:-}" ] || { echo "sway non trovato"; exit 1; }
}

# Cambia modo e torna al 60 Hz: costringe il kernel a riprogrammare il clock
# dei pixel (dclk_vopb, divisore frazionario dal CPLL). Se dopo questo il VOP
# torna a 60 interrupt al secondo, il colpevole e' il clock dei pixel non
# riprogrammato alla riaccensione.
ripara() {
	sway_sock
	echo "VOP prima: $(vop_hz) interrupt/s"
	SWAYSOCK="${S}" swaymsg output DSI-1 mode 640x480@58.500Hz >/dev/null
	sleep 2
	echo "VOP a 58,5 Hz: $(vop_hz) interrupt/s"
	SWAYSOCK="${S}" swaymsg output DSI-1 mode 640x480@60.000Hz >/dev/null
	sleep 2
	echo "VOP di nuovo a 60 Hz: $(vop_hz) interrupt/s"
	echo "Guarda lo schermo: e' tornato pulito e veloce?"
}

rompi() {
	sway_sock
	SWAYSOCK="${S}" swaymsg output DSI-1 power off >/dev/null
	sleep 2
	SWAYSOCK="${S}" swaymsg output DSI-1 power on >/dev/null
	sleep 3
	echo "schermo spento e riacceso: ora 'salva rotto'"
}

case "${1:-}" in
salva)     [ -n "${2:-}" ] || { echo "uso: $0 salva <nome>"; exit 1; }; salva "$2" ;;
vop)       echo "VOP: $(vop_hz) interrupt/s (60 = buono)" ;;
ripara)    ripara ;;
rompi)     rompi ;;
confronta) [ -n "${3:-}" ] || { echo "uso: $0 confronta <a> <b>"; exit 1; }; confronta "$2" "$3" ;;
*)         echo "uso: sh $0 salva <nome> | rompi | confronta <a> <b> | vop | ripara" >&2; exit 1 ;;
esac
