#!/bin/sh
# rf35h-panel-diag.sh - in che ordine si accendono pannello e DSI.
#
#   sh rf35h-panel-diag.sh soc        PX30 o PX30S (RK3326S)
#   sh rf35h-panel-diag.sh schermo    spegne e riaccende lo schermo da sway,
#                                     senza standby (stesso percorso del risveglio)
#   sh rf35h-panel-diag.sh standby    standby vero: premi il tasto power per
#                                     risvegliare, lo script riprende da solo
#
# Perche' (5/10/2026). Il driver del pannello (z-002, panel-generic-dsi di
# ROCKNIX) manda la sequenza di init in prepare(). Nella 7.2 il ponte DSI
# (dw-mipi-dsi) accende il controller nel suo pre_enable, e la catena dei
# ponti chiama i pre_enable dall'ultimo al primo: senza prepare_prev_first nel
# pannello, prepare() gira PRIMA che il DSI sia acceso e i comandi di init
# finiscono in un controller in reset, senza errori. z-002 ora mette
# prepare_prev_first (panel_generic_dsi.prev_first=0 sulla riga di comando del
# kernel per tornare indietro) e z-036 scrive nel log:
#   "rf35h: DSI host on/off"           il controller DSI;
#   "rf35h: panel on/off"              il pannello;
#   "sent with the host powered down"  un comando perso.
# Questo script raccoglie quelle righe intorno a uno spegnimento dello schermo
# o a uno standby e dice in che ordine sono andate. Serve un kernel con z-036.
#
# Non cambia niente di permanente.
set -u

DM="${RF35H_DEVMEM:-devmem}"
DSI=0xff450000
OUT="${RF35H_PANEL_DIAG_OUT:-/storage/panel-diag}"

mkdir -p "${OUT}"

rd() { "${DM}" "$1" 32 2>/dev/null || echo "?"; }

soc() {
	v="$(rd 0xff630004)"
	case "${v}" in
	\?) echo "DDR_GRF_CON1 illeggibile (devmem?)"; return ;;
	esac
	b=$(( (v >> 14) & 3 ))
	if [ "${b}" -eq 3 ]; then
		echo "SoC: PX30S / RK3326S (DDR_GRF_CON1=${v}, bit 15:14 = 3)"
	else
		echo "SoC: PX30 / RK3326 (DDR_GRF_CON1=${v}, bit 15:14 = ${b})"
	fi
}

regs() {
	echo "-- registri DSI ($1)"
	for r in 0x04:PWR_UP 0x34:MODE_CFG 0x74:CMD_PKT_STATUS 0x94:LPCLK_CTRL 0xa0:PHY_RSTZ 0xb0:PHY_STATUS 0xbc:INT_ST0 0xc0:INT_ST1; do
		off="${r%%:*}"; name="${r#*:}"
		printf '   %-15s %s\n' "${name}" "$(rd $(( DSI + off )))"
	done
}

marca() { echo "rf35h-panel-diag: inizio $1" > /dev/kmsg; }

# Le righe dal marcatore in poi, solo quelle che servono, in ordine di tempo.
estrai() {
	dmesg | sed -n "/rf35h-panel-diag: inizio $1/,\$p" \
		| grep -E 'rf35h|panel-generic-dsi|dsi|DSI|PM: suspend|failed|timeout' \
		> "${OUT}/$1.txt"
	cat "${OUT}/$1.txt"
	echo "-- verdetto"
	if ! grep -q 'rf35h: DSI host' "${OUT}/$1.txt"; then
		echo "   nessuna riga \"rf35h: DSI host\": questo kernel non ha z-036"
	elif grep -q 'sent with the host powered down' "${OUT}/$1.txt"; then
		echo "   comandi al pannello PERSI (DSI spento): e' la causa"
	else
		pi="$(grep -nE 'rf35h: panel on' "${OUT}/$1.txt" | tail -1 | cut -d: -f1)"
		di="$(grep -nE 'rf35h: DSI host on' "${OUT}/$1.txt" | tail -1 | cut -d: -f1)"
		if [ -n "${pi}" ] && [ -n "${di}" ] && [ "${di}" -lt "${pi}" ]; then
			echo "   DSI acceso prima del pannello, nessun comando perso"
		else
			echo "   ordine non chiaro: mandami ${OUT}/$1.txt"
		fi
	fi
	echo "   prev_first: $(cat /sys/module/panel_generic_dsi/parameters/prev_first 2>/dev/null || echo assente)"
	echo "tutto in ${OUT}/$1.txt"
}

swaysock() {
	for s in /var/run/0-runtime-dir/sway-ipc.*.sock /run/0-runtime-dir/sway-ipc.*.sock; do
		[ -S "${s}" ] && { echo "${s}"; return; }
	done
}

case "${1:-}" in
soc)
	soc ;;
schermo)
	S="$(swaysock)"
	[ -n "${S}" ] || { echo "sway non trovato"; exit 1; }
	soc
	regs "prima"
	marca schermo
	SWAYSOCK="${S}" swaymsg output DSI-1 power off >/dev/null
	sleep 2
	regs "schermo spento"
	SWAYSOCK="${S}" swaymsg output DSI-1 power on >/dev/null
	sleep 3
	regs "riacceso"
	estrai schermo
	echo "Guarda lo schermo: sfarfalla, e' spostato o lento come dopo lo standby?"
	;;
standby)
	soc
	regs "prima"
	marca standby
	echo "Sospendo fra 3 s. Risveglia con il tasto power."
	sleep 3
	systemctl suspend
	sleep 8
	regs "dopo il risveglio"
	estrai standby
	;;
*)
	echo "uso: sh $0 soc | schermo | standby" >&2
	exit 1 ;;
esac
