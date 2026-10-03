#!/bin/sh
# verify-kernel.sh - controlla che le nostre patch siano davvero finite nel
# sorgente del kernel che la build ha usato.
#
#   ./verify-kernel.sh [percorso/dell/albero]
#
# Perche' serve: scripts/unpack applica le patch con un semplice
#
#     patch -d "${PKG_BUILD}" -p1 <${i}
#
# senza controllarne l'esito, non ha "set -e", e scripts/build non guarda il
# suo codice di uscita. Una patch che non applica **non ferma la build**: esce
# un kernel senza quella modifica, in silenzio.
#
# Non e' un caso limite: LibreELEC stessa ha due patch identiche in
# packages/linux/patches/default/ (linux-9901-pm-disable-async... e
# linux-999.02-0001-pm-disable-async...). La seconda fallisce a ogni build di
# ogni device e nessuno se ne accorge, proprio per questo.
#
# Alcune mancate applicazioni si vedrebbero comunque - senza z-010 non c'e' il
# DTS e il Makefile del kernel si ferma - ma altre no: senza r-024 parte un
# kernel senza Wi-Fi, senza r-025 uno con il pannello che potrebbe non
# inizializzarsi. Meglio guardare.

set -eu

TREE="${1:-./lakka-rf35h-build}"
# Esce 1 se mancano patch, 2 se non c'e' niente da controllare.
[ -d "${TREE}/packages" ] || { echo "Non sembra un albero Lakka: ${TREE}" >&2; exit 2; }

# Il SORGENTE: build.*/build/linux-7.x. La versione piu' alta, non la prima
# trovata: dopo il passaggio alla 7.2.7 l'albero di build conserva
# build/linux-7.0.1 delle build precedenti, e con "head -1" si poteva finire a
# controllare quello. E solo sotto build/: a build finita esiste anche
# build.*/install_pkg/linux-7.2.7 (config/functions: PKG_INSTALL, dove il
# pacchetto si installa per l'immagine), che ha lo stesso nome ma nessun
# sorgente, e "install_pkg" viene dopo "build" nell'ordinamento: si prendeva
# quello, e tutti i controlli davano MANCA su un kernel corretto.
K="$(find "${TREE}" -maxdepth 3 -type d -path '*/build.*/build/linux-7.*' 2>/dev/null | sort -V | tail -1)"
[ -n "${K}" ] || {
	echo "Non trovo il sorgente del kernel sotto ${TREE}." >&2
	echo "Lo si vede solo dopo che la build ha scompattato il pacchetto linux." >&2
	exit 2
}
echo "kernel: ${K}"
echo

fail=0
D="${K}/arch/arm64/boot/dts/rockchip"

# marcatore | file | descrizione
check() {
	printf '  %-34s ' "$3"
	if [ -f "$2" ] && grep -q "$1" "$2" 2>/dev/null; then
		echo "ok"
	else
		echo "MANCA"
		fail=$((fail + 1))
	fi
}

check "MMC_CAP2_WIFI_RK912" "${K}/include/linux/mmc/host.h"        "r-024 hack SDIO per rk915"
# Da solo non discrimina: la riga aggiunta da r-025 esiste gia' una volta nella
# 7.2.7 originale (con la patch diventa due). L'assenza di r-025 la rileva il
# controllo "riga vecchia rimossa" piu' sotto.
check "DSI_PWR_UP, POWERUP" "${K}/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c" "r-025 fix MIPI"
# La build deve aver usato davvero la 7.2.7, non un sorgente rimasto in cache.
check "^PATCHLEVEL = 2$"   "${K}/Makefile"                          "kernel 7.2 (PATCHLEVEL)"
check "^SUBLEVEL = 7$"     "${K}/Makefile"                          "kernel 7.2.7 (SUBLEVEL)"
# Porting alla 7.2: senza questi due il sorgente compila solo a meta'.
check "host->mmc->caps2 & MMC_CAP2_WIFI_RK912" "${K}/drivers/mmc/host/dw_mmc.c" "r-024 porting dw_mmc (slot->host)"
check "devm_drm_panel_alloc" "${K}/drivers/gpu/drm/panel/panel-generic-dsi.c"    "z-002 porting pannello 7.2"
# Le quattro patch di Lakka che la pila snella tiene.
check 'name = "battery"'   "${K}/drivers/power/supply/rk817_charger.c" "0000 batteria rinominata (LED carica)"
# Ancorato alla definizione: "pm_async_enabled = 0" compare anche nel gestore
# del parametro pm_async=off, quindi senza ancora il controllo passava anche a
# patch assente (trovato col controllo negativo sull'albero originale).
check "^int pm_async_enabled = 0;" "${K}/kernel/power/main.c"        "9901 suspend asincrono spento"
check "dmc: dmc"           "${K}/arch/arm64/boot/dts/rockchip/px30.dtsi" "0012 etichetta dmc"
check "abs(rel_y) < 2 && abs(rel_x) < 2" "${K}/drivers/media/rc/imon.c"       "0062 imon, diagonali ignorate"
check "rocknix,generic-dsi" "${K}/drivers/gpu/drm/panel/panel-generic-dsi.c"     "z-002 panel-generic-dsi"
check "rk3326-xifan-rf35h"  "${D}/Makefile"                          "z-010 DTS nel Makefile"
check "opp-600000000"       "${D}/rk3326-xifan-rf35h.dts"            "z-010 scala OPP piena"
check "role-switch-default" "${D}/rk3326-xifan-rf35h.dts"            "z-010 USB OTG host"
# z-010 porta tutte le regolazioni della board: se la patch fosse applicata a
# meta' (o rigenerata male) il DTS compilerebbe lo stesso, ma con meno cose.
check "5000000"            "${D}/rk3326-xifan-rf35h.dts"            "z-010 BOOST a 5,0 V"
check "joyled-power"       "${D}/rk3326-xifan-rf35h.dts"            "z-010 alimentazione LED stick"
check "GPIO_ACTIVE_HIGH"   "${D}/rk3326-xifan-rf35h.dts"            "z-010 rumble attivo-alto"
check "3228000"            "${D}/rk3326-xifan-rf35h.dts"            "z-010 batteria OEM"
check "amux-b-gpios"       "${D}/rk3326-xifan-rf35h.dts"            "z-010 amux-b OEM"
check "disabled"           "${D}/rk3326-xifan-rf35h.dts"            "z-010 eMMC spenta"
check "clock=31080 horizontal=640,150,60,150 vertical=480,20,6,12 default=1" "${D}/rk3326-xifan-xf35h.dts" "z-010 pannello a 60 Hz"

# r-025 sostituisce una riga: se quella vecchia c'e' ancora, non ha applicato.
# Controllo in negativo, quindi il file deve esistere: senza, "la riga non
# c'e'" era vero per forza, ed e' stato l'unico ok nei 20 falsi MANCA della
# cartella install_pkg.
DSI="${K}/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c"
printf '  %-34s ' "r-025 riga vecchia rimossa"
if [ ! -f "${DSI}" ]; then
	echo "MANCA (niente dw-mipi-dsi.c)"
	fail=$((fail + 1))
elif grep -q "Switch to cmd mode for panel-bridge" "${DSI}"; then
	echo "ANCORA PRESENTE"
	fail=$((fail + 1))
else
	echo "ok"
fi

# il DTB compilato, se la build ci e' arrivata
DTB="$(find "${TREE}" -name 'rk3326-xifan-rf35h.dtb' 2>/dev/null | head -1)"
echo
if [ -n "${DTB}" ]; then
	echo "  DTB compilato: ${DTB}"
else
	echo "  DTB non ancora compilato (la build non e' arrivata in fondo al kernel)"
fi

echo
if [ "${fail}" = "0" ]; then
	echo "Tutte le patch della pila snella sono nel sorgente."
else
	echo "${fail} controlli falliti: il kernel costruito NON ha tutte le patch." >&2
	echo "La build non se ne accorge da sola, vedi il commento in testa a questo file." >&2
	exit 1
fi
