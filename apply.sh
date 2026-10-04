#!/bin/bash
# devaOS -> Lakka: aggiunge il device rf35h all'albero Lakka devel.
#   ./apply.sh /percorso/Lakka-LibreELEC /percorso/devaos/buildroot-external/boards/rf35h
set -euo pipefail
L="${1:?uso: ./apply.sh <Lakka-LibreELEC> <boards/rf35h di devaOS>}"
B="${2:?}"
O="$(cd "$(dirname "$0")" && pwd)"
RK="$L/projects/Rockchip/devices/RK3326"

[ -d "$RK" ] || { echo "apply: $RK non esiste - branch sbagliato? serve 'devel'" >&2; exit 1; }
[ -f "$B/loader/known-good.bin" ] || { echo "apply: manca $B/loader/known-good.bin" >&2; exit 1; }
[ -f "$B/loader/known-good.sha256" ] || { echo "apply: manca $B/loader/known-good.sha256 - non posso verificare il loader" >&2; exit 1; }
( cd "$B/loader" && sha256sum -c --quiet known-good.sha256 ) || { echo "apply: known-good.bin non corrisponde al suo sha256" >&2; exit 1; }

# Le patch non sono idempotenti: applicarle due volte da "Reversed (or
# previously applied) patch detected", che non spiega niente a chi lo legge.
# Il marcatore e' nel file che tocca release-rf35h.patch.
if grep -q "RF35H_LOADER" "$L/projects/Rockchip/bootloader/release" 2>/dev/null; then
	echo "apply: l'overlay risulta gia' applicato a $L" >&2
	echo "       per rifarlo da capo:  git -C $L checkout -- . && git -C $L clean -fd" >&2
	exit 1
fi

echo "[1/8] patch kernel (device tree incluso in z-010)"
# Prima si toglie quello che avevamo messo in un giro precedente: se una
# versione vecchia dell'overlay portava un patch poi rinominato o ritirato,
# scompattando sopra resterebbero entrambi e si applicherebbero tutti e due.
# I prefissi r- e z- sono solo nostri: Lakka usa 0*, 1000* e uvc-*.
rm -f "$RK"/patches/linux/r-*.patch "$RK"/patches/linux/z-*.patch
cp "$O"/patches/linux/*.patch "$RK/patches/linux/"

# Kernel 7.2.y, pila snella. Le patch di Lakka per RK3326 sono scritte per la
# 7.0.1 e servono molte console; la RF35H ne usa due: 0000 (il trigger del LED
# di carica si chiama battery-charging solo col power supply rinominato) e 0012
# (l'etichetta dmc del device tree). Le altre sono per Odroid, RG351, GameForce
# ed esp8089, e la 0002 reintroduce API che mainline ha tolto (of_gpio.h non
# esiste piu' nella 7.2). Elenco di quelle da TENERE, non da togliere: una patch
# che Lakka aggiungesse in futuro, scritta per la 7.0, verrebbe scartata invece
# di fallire sulla 7.2 - e lo si dice. La 0000 e' la nostra, rigenerata a
# fuzz 0 (quella di Lakka applicava con fuzz 2); cp sopra l'ha gia' sostituita.
for p in "$RK"/patches/linux/*.patch; do
	case "$(basename "$p")" in
		r-*|z-*|0000-rename-rk817-battery.patch|0012-px30-and-rk3326-odroid-go-more-adjustment.patch) ;;
		*) echo "       pila snella 7.2, scartata: $(basename "$p")"; rm -f "$p" ;;
	esac
done
# Patch generiche di Lakka: le due ntfs portano indietro codice della 7.1, gia'
# presente nella 7.2 (fallirebbero come "gia' applicate"). Si tengono 0062 e
# 9901; la 9901 e' la nostra, rigenerata a fuzz 0.
cp "$O"/patches/linux-default/*.patch "$L/packages/linux/patches/default/"
for p in "$L"/packages/linux/patches/default/*.patch; do
	case "$(basename "$p")" in
		linux-0062-imon_pad_ignore_diagonal.patch|linux-9901-pm-disable-async-suspend-resume-by-default.patch) ;;
		*) echo "       pila snella 7.2, scartata: default/$(basename "$p")"; rm -f "$p" ;;
	esac
done


echo "[2/8] package out-of-tree"
# projects/<PROJECT>/devices/<DEVICE>/packages e' la prima directory che
# config/functions mette nella cache "local", e la local vince sulla global:
# e' dove stanno gia' librga, rk3326-firmware e u-boot di questo device.
mkdir -p "$RK/packages"
cp -r "$O"/packages/rk915 "$O"/packages/rocknix-joypad "$RK/packages/"
# IKEMEN GO e cio' che gli serve: Go ufficiale per l'host (golang-bin), SDL2
# completa e libxmp statiche, lo screenpack. Nomi nuovi: non rimpiazzano nulla
# di Lakka (SDL2_input e libxmp-lite restano come sono).
cp -r "$O"/packages/golang-bin "$O"/packages/libxmp "$O"/packages/ikemen-sdl2 \
      "$O"/packages/ikemen-screenpack "$O"/packages/ikemen-go "$RK/packages/"
# I giochi fatti per questa console (options: RF35H_GTASA, RF35H_RE3,
# RF35H_OPENXEENNG, RF35H_DEVA_ADVENTURES). Nessun dato dei giochi: GTA SA e GTA
# III dalle copie dell'utente, OpenXeenNG dagli archivi GOG. deva_adventures e
# openxeenng si scaricano dai loro repository a un commit fissato. rust-bin (+
# rust-std-aarch64): Rust ufficiale per l'host, per openxeenng, invece di
# compilare rustc.
cp -r "$O"/packages/gtasa "$O"/packages/openxeenng \
      "$O"/packages/rust-bin "$O"/packages/rust-std-aarch64 \
      "$O"/packages/deva_adventures "$RK/packages/"
# re3 (GTA III) non sta nell'overlay: il suo codice non ha licenza e il
# pacchetto vive in un repository privato. RF35H_RE3_PKG (--re3 del build
# script) e' la sua cartella: se ne copiano package.mk, files/ e patches/, e
# le options lo aggiungono all'immagine solo se c'e'. Si toglie sempre prima:
# senza --re3 non deve restarne uno di un giro precedente.
rm -rf "$RK/packages/re3"
if [ -n "${RF35H_RE3_PKG:-}" ]; then
	grep -q '^PKG_NAME="re3"' "$RF35H_RE3_PKG/package.mk" 2>/dev/null \
		|| { echo "apply: $RF35H_RE3_PKG non e' il pacchetto re3 (manca package.mk con PKG_NAME=\"re3\")" >&2; exit 1; }
	mkdir -p "$RK/packages/re3"
	cp -r "$RF35H_RE3_PKG"/package.mk "$RF35H_RE3_PKG"/files "$RF35H_RE3_PKG"/patches "$RK/packages/re3/"
	echo "    re3 da $RF35H_RE3_PKG"
fi

echo "[3/8] bootloader (known-good AURKNIX, 16 MB)"
mkdir -p "$RK/bootloader"
cp "$B/loader/known-good.bin" "$RK/bootloader/rf35h-loader.bin"

echo "[4/8] uboot_helper"
python3 - "$L/scripts/uboot_helper" <<'PY'
import sys,re
p=sys.argv[1]; s=open(p).read()
if "'rf35h'" in s: print("    gia' presente, salto"); sys.exit()
entry = """      'rf35h': {
        'dtb': 'rk3326-xifan-rf35h.dtb',
        'config': 'odroidgoa_defconfig',
        'rockchip_legacy_boot': '1'
      },
"""
anchor = """      'rg351v': {
        'dtb': 'rk3326-anbernic-rg351v.dtb',
        'config': 'odroidgoa_defconfig',
        'rockchip_legacy_boot': '1'
      },
"""
assert anchor in s, "ancora rg351v non trovata: uboot_helper cambiato"
s=s.replace(anchor, anchor+entry, 1)
open(p,'w').write(s); print("    voce rf35h aggiunta")
PY

# --fuzz=0 su tutte: un patch che "trova un posto che somiglia" e' un patch
# applicato nel punto sbagliato. E' successo con le vecchie patch della catena
# del DTS, una generata contro un albero che ne aveva gia' un'altra: passava
# col fuzz di default e sarebbe rimasta
# rotta fino al primo cambio di contesto. Meglio un errore chiaro.
echo "[5/8] options + release + mkimage"
grep -q "ADDITIONAL_DRIVERS.*rk915" "$RK/options" || \
  printf '\n# devaOS RF35H: driver out-of-tree richiesti dall'"'"'hardware\nADDITIONAL_DRIVERS+=" rk915 rocknix-joypad"\n' >> "$RK/options"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/release-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/bootloader-install-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/mkimage-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/init-update-visible-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/options-rf35h.patch"
# Vulkan (PanVK) accanto a OpenGL ES, e IKEMEN GO nell'immagine. Si spengono
# alla build con RF35H_VULKAN=no / RF35H_IKEMEN=no (build-lakka-rf35h.sh:
# --no-vulkan / --no-ikemen).
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/options-vulkan-ikemen-rf35h.patch"
# ...ma non per sway: il renderer Vulkan di wlroots qui non serve e vorrebbe
# glslang sull'host prima del tempo
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/wlroots-no-vulkan-rf35h.patch"
# Kernel 7.2.y: il ramo 7.0 e' fuori supporto dal 27/06/2026. Versione e
# SHA256 stanno solo in quella patch (un aggiornamento cambia due righe li').
KV="$(sed -n 's/^+ *PKG_VERSION="\([0-9][0-9.]*\)".*/\1/p' "$O/integration/linux-rf35h.patch")"
[ -n "$KV" ] || { echo "apply: versione del kernel non trovata in integration/linux-rf35h.patch" >&2; exit 1; }
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/linux-rf35h.patch"
# perf usa da solo strumenti dell'host se li trova: rustc (carico di test in
# Rust, per aarch64 fallisce) e shellcheck (ogni avviso ferma la build).
# NO_RUST=1 e NO_SHELLCHECK=1 accanto agli altri NO_*.
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/perf-host-tools-rf35h.patch"
# L'hash dei pacchetti divideva sugli spazi i nomi dei nostri override
# ("TGB Dual/TGB Dual.cfg"): errori sha256sum e file esclusi dall'hash.
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/stamp-spaces-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/retroarch-no-go2-rf35h.patch"
# RF35H_ALL_CORES=1: include anche lr_moonlight e vitaquake3, che Lakka
# esclude su ogni progetto. La patch sta in optional/ perche' quei due
# probabilmente non compilano: si applica solo su richiesta.
if [ "${RF35H_ALL_CORES:-0}" = 1 ]; then
	echo "  RF35H_ALL_CORES=1: includo anche lr_moonlight e vitaquake3"
	patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/optional/all-cores.patch"
fi
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/kconfig-pwrkey-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/logind-powerkey-rf35h.patch"

echo "[6/8] userspace: audio, tasti volume"
cp -r "$O"/packages/rf35h-utils "$RK/packages/"
cp -r "$O"/packages/wpa_supplicant "$RK/packages/"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/odroidgo2-utils-rf35h.patch"
# lakka-update (da ssh) installerebbe l'immagine di Lakka per un RK3326
# generico: sull'RF35H passa a rf35h-update (la voce del menu la toglie la 1003)
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/lakka-update-rf35h.patch"
# strace 7.0 con gli header del kernel 7.2 non compila: i suoi
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/strace-bundled-headers-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/eventservice-modifier-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/fcft-checksum-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/foot-checksum-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/uboot-werror-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/iwd-off-with-wpa-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/connman-stamp-rf35h.patch"
# Porta USB-C in modo "trasferimento file": gadget di rete via configfs
# (kernel), udhcpd per dare l'IP al PC (busybox), e connman che lascia stare
# le interfacce usb* (i dongle ethernet USB si chiamano eth*, non li tocca).
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/kconfig-usb-gadget-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/kconfig-zram-gamepads-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/kconfig-audio-aurknix-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/kconfig-debug-off-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/busybox-udhcpd-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/connman-blacklist-usb-rf35h.patch"

# Ottimizzazione: -O2 lo mette LibreELEC a tutto (CFLAGS_OPTIM_DEFAULT). Qui
# l'LTO: Mesa sempre; i core solo quelli provati in C/C++ puro, senza
# dynarec. Il flag e' "+lto": questa LibreELEC conosce solo lto, lto-fat e
# lto-off (config/functions, setup_toolchain), e "+lto" da' -flto=N piu' i
# suoi -Werror=odr, lto-type-mismatch e strict-aliasing, che fermano un core
# su cui l'LTO rischierebbe codice sbagliato. "+lto-parallel" veniva da una
# LibreELEC vecchia e qui non faceva niente: fino al 4/10/2026 nessun core ha
# avuto l'LTO. Se un core con LTO si comporta male: RF35H_CORE_LTO=no, oppure
# PKG_BUILD_FLAGS="+lto-off" nel suo package.mk.
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/mesa-lto-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/sdl-host-flags-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/applewin-xxd-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/uae4arm-numbers-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/cannonball-cxx11-rf35h.patch"
patch -p1 --fuzz=0 --no-backup-if-mismatch -d "$L" < "$O/integration/sway-lean-rf35h.patch"
if [ "${RF35H_CORE_LTO:-yes}" = "yes" ]; then
	# LTO solo su interpreti in C/C++ puro. Fuori: chi ha dynarec o JIT
	# (picodrive, gpsp, mupen64plus_next, parallel_n64, melonds, melondsds,
	# flycast) e i giganti dove il link con LTO mangia gigabyte di RAM per
	# poco (fbneo, fbalpha2012, mame2010, mame2015).
	for c in ${RF35H_LTO_CORES:-snes9x2010 snes9x snes9x2005 gambatte sameboy tgbdual fceumm nestopia genesis_plus_gx gearsystem mgba beetle_pce_fast beetle_pce beetle_ngp race stella2014 stella cap32 crocods}; do
		pm="$L/packages/lakka/libretro_cores/$c/package.mk"
		[ -f "$pm" ] || { echo "  (core $c non presente, salto)"; continue; }
		if grep -qE '^PKG_BUILD_FLAGS=.*lto' "$pm"; then
			echo "  $c: ha gia' un flag lto suo, non tocco"
		elif grep -q '^PKG_BUILD_FLAGS=' "$pm"; then
			# c'e' gia' un flag (es. sameboy: "-parallel", il suo Makefile non
			# regge make -j): si aggiunge, non si sovrascrive. I due convivono.
			sed -i 's/^PKG_BUILD_FLAGS="\([^"]*\)"/PKG_BUILD_FLAGS="\1 +lto"/' "$pm"
			echo "  $c: +lto aggiunto a $(grep -oE '^PKG_BUILD_FLAGS="[^"]*"' "$pm")"
		else
			printf '\n# devaOS RF35H: LTO. Core in C/C++ puro senza dynarec; togli con +lto-off.\nPKG_BUILD_FLAGS="+lto"\n' >> "$pm"
			echo "  $c: +lto"
		fi
	done
fi

# Vulkan: chi legge VULKAN_SUPPORT compila in modo diverso (Mesa con o senza
# PanVK, RetroArch con o senza il driver vulkan; i core cambiano dipendenze
# o, fuori dal set di default come ppsspp, il renderer), ma calculate_stamp
# hasha la cartella del package e PKG_STAMP, non le options: senza questo, su
# un albero gia' compilato RF35H_VULKAN cambierebbe l'immagine a meta' (Mesa
# vecchia, RetroArch nuovo).
# In coda al package.mk, come riga a se': si somma a un PKG_STAMP esistente
# (RetroArch ha gia' quello su DISPLAYSERVER).
for pm in "$L/packages/graphics/mesa/package.mk" \
          "$L/packages/lakka/retroarch_base/retroarch/package.mk" \
          $(grep -lE 'VULKAN_SUPPORT' "$L"/packages/lakka/libretro_cores/*/package.mk); do
	grep -q 'PKG_STAMP+=" VULKAN=' "$pm" && continue
	printf '\n# devaOS RF35H: ricompila se cambia VULKAN (calculate_stamp non legge le options)\nPKG_STAMP+=" VULKAN=${VULKAN}"\n' >> "$pm"
done
echo "  PKG_STAMP su VULKAN: $(grep -l 'PKG_STAMP+=" VULKAN=' "$L/packages/graphics/mesa/package.mk" "$L/packages/lakka/retroarch_base/retroarch/package.mk" "$L"/packages/lakka/libretro_cores/*/package.mk | wc -l) package"

echo "[7/8] autoconfig joypad RetroArch"
# Nessuna patch: scripts/unpack copia ${PKG_DIR}/sources/* dentro l'albero di
# build, e il Makefile a monte installa tutti i .cfg di udev/. E' il modo in
# cui Lakka aggiunge GameForceChi-joypad.cfg e i GO-Advance. Un cp aggiuntivo
# in makeinstall_target avrebbe installato lo stesso config due volte.
cp "$O"/autoconfig/retrogame_joypad.cfg \
   "$L/packages/lakka/retroarch_base/retroarch_joypad_autoconfig/sources/udev/"

# Il menu "Device Settings" di RetroArch: una patch al sorgente, nella
# cartella patches/ del package, dove LibreELEC la applica con patch -p1 dopo
# quelle di Lakka (la 1003 viene dopo la 1002). Il menu compare solo se sul
# device esiste /usr/bin/rf35h-led: sugli altri RK3326 RetroArch non cambia.
cp "$O"/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# NEON su aarch64 e nome della CPU: due difetti di RetroArch che valgono per
# ogni Lakka a 64 bit, trovati leggendo System Information sull'RF35H. Vedi
# tools/gen-retroarch-arm64-fixes.py.
cp "$O"/patches/retroarch/retroarch-1004-arm64-neon-cpu-model.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# La prima connessione Wi-Fi falliva sempre: RetroArch chiedeva a connman di
# connettersi mentre connman era appena ripartito e non aveva ancora
# scansionato. Vale per ogni Lakka, non solo per questa board.
cp "$O"/patches/retroarch/retroarch-1005-wifi-connect-wait.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# Tasti volume: RetroArch saliva e scendeva a passi fissi da 0,5 dB, cioe' 160
# pressioni da 0 dB al silenzio, meta' delle quali sotto la soglia udibile
# dell'altoparlante. Ora scala cubica a passi del 5 %, come PipeWire e
# PulseAudio: 20 pressioni dal 100 % al muto.
cp "$O"/patches/retroarch/retroarch-1006-volume-steps.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# Il toggle dei servizi Lakka (SSH, Samba, Bluetooth) svuotava il file di
# configurazione riaccendendoli: per SSH significava perdere la protezione
# PasswordAuthentication=no e tornare alla password root di default.
cp "$O"/patches/retroarch/retroarch-1007-service-toggle-keep-conf.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# connmanctl non controllava mai popen() (un fallimento e' un SEGV) e svuotava
# la lista delle reti mentre il menu la leggeva da un altro thread. Vale per
# ogni Lakka: vedi il SEGV del 22/9 in docs/diario.md.
cp "$O"/patches/retroarch/retroarch-1008-connmanctl-hardening.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# La lista delle reti era ricostruita dai task Wi-Fi mentre il menu la leggeva,
# senza lock, e la finestra della password ritrovava la rete per indice.
cp "$O"/patches/retroarch/retroarch-1009-wifi-list-lock.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"
# retroarch.cfg si scriveva svuotandolo prima: un crash a meta' lo lasciava a
# 0 byte. Ora file temporaneo, fsync e rename.
cp "$O"/patches/retroarch/retroarch-1010-config-atomic-write.patch \
   "$L/packages/lakka/retroarch_base/retroarch/patches/"

echo "[8/8] controllo"
for f in "$RK/patches/linux/z-010-add-rf35h-dts.patch" \
         "$RK/packages/rk915/package.mk" \
         "$RK/packages/rocknix-joypad/package.mk" \
         "$RK/packages/rocknix-joypad/patches/0002-of-gpio-legacy-guard.patch" \
         "$RK/packages/rocknix-joypad/patches/0003-rocknix-joypad-linux-7.2-of-gpio.patch" \
         "$RK/packages/rk915/patches/0003-rk915-linux-7.2-strncpy.patch" \
         "$RK/patches/linux/0012-px30-and-rk3326-odroid-go-more-adjustment.patch" \
         "$L/packages/linux/patches/default/linux-9901-pm-disable-async-suspend-resume-by-default.patch" \
         "$RK/packages/rf35h-utils/package.mk" \
         "$RK/packages/rf35h-utils/retroarch.service.d/rf35h-vulkan.conf" \
         "$RK/packages/rf35h-utils/scripts/rf35h-ra-guard" \
         "$RK/packages/golang-bin/package.mk" \
         "$RK/packages/libxmp/package.mk" \
         "$RK/packages/ikemen-sdl2/package.mk" \
         "$RK/packages/ikemen-screenpack/package.mk" \
         "$RK/packages/ikemen-go/package.mk" \
         "$RK/packages/ikemen-go/scripts/rf35h-ikemen" \
         "$RK/packages/ikemen-go/system.d/rf35h-ikemen.service" \
         "$RK/packages/ikemen-go/patches/ikemen-go-0001-linux-gles-renderer-nodialog.patch" \
         "$RK/packages/ikemen-go/patches/ikemen-go-0002-gles-vulkan-fixes.patch" \
         "$RK/packages/ikemen-go/patches/ikemen-go-0003-disable-vulkan.patch" \
         "$RK/packages/ikemen-go/launcher/ikemen_libretro.c" \
         "$RK/packages/ikemen-go/launcher/ikemen_libretro.info" \
         "$RK/packages/ikemen-go/launcher/ikemen-icon.png" \
         "$RK/packages/gtasa/package.mk" \
         "$RK/packages/gtasa/launcher/gtasa_libretro.c" \
         "$RK/packages/gtasa/launcher/gtasa_libretro.info" \
         "$RK/packages/gtasa/scripts/rf35h-gtasa" \
         "$RK/packages/gtasa/system.d/rf35h-gtasa.service" \
         "$RK/packages/gtasa/sources/Makefile" \
         "$RK/packages/openxeenng/package.mk" \
         "$RK/packages/openxeenng/patches/openxeenng-0001-lakka-libretro-only-workspace.patch" \
         "$RK/packages/rust-bin/package.mk" \
         "$RK/packages/rust-std-aarch64/package.mk" \
         "$RK/packages/deva_adventures/package.mk" \
         "$RK/bootloader/rf35h-loader.bin" \
         "$L/packages/lakka/retroarch_base/retroarch_joypad_autoconfig/sources/udev/retrogame_joypad.cfg" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1004-arm64-neon-cpu-model.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1005-wifi-connect-wait.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1007-service-toggle-keep-conf.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1008-connmanctl-hardening.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1009-wifi-list-lock.patch" \
         "$L/packages/lakka/retroarch_base/retroarch/patches/retroarch-1010-config-atomic-write.patch"; do
  [ -e "$f" ] || { echo "apply: manca $f" >&2; exit 1; }
done

need() { grep -q "$2" "$1" || { echo "apply: $3" >&2; exit 1; }; }
need "$L/packages/linux/package.mk"                      "PKG_VERSION=\"$KV\"" "kernel non portato a $KV"
[ -e "$RK/patches/linux/z-001-st7703-xifan-xf35h-panel.patch" ] && { echo "apply: z-001 ancora presente (inerte, e senza 0101 finisce nel punto sbagliato)" >&2; exit 1; }
[ -e "$RK/patches/linux/0002-add-input-polldev.patch" ] && { echo "apply: 0002-add-input-polldev ancora presente (non applica sulla 7.2)" >&2; exit 1; }
need "$L/scripts/uboot_helper"                          "'rf35h'"        "voce rf35h assente da uboot_helper"
need "$RK/options"                                      "rk915"          "ADDITIONAL_DRIVERS non aggiornato"
need "$RK/linux/linux.aarch64.conf"                     "^CONFIG_INPUT_RK805_PWRKEY=y" "tasto power: simbolo non abilitato"
need "$RK/packages/odroidgo2-utils/package.mk"          "rf35h"          "odroidgo2-utils abiliterebbe ancora il suo servizio"
need "$RK/packages/odroidgo2-utils/sources/headphone-sense.c" "cmd_plugged" "headphone-sense non parametrizzato"
need "$RK/packages/eventservice/sources/spkeys-service.c" "modified_cmd" "spkeys-service senza supporto al modificatore"
need "$RK/options"                                      'VULKAN="vulkan-loader"' "options: manca il blocco Vulkan"
need "$RK/options"                                      'ikemen-go'      "options: IKEMEN GO non aggiunto"
need "$L/packages/wayland/lib/wlroots/package.mk"       'UBOOT_SYSTEM}" != "rf35h"' "wlroots: il renderer Vulkan non e' escluso sull'RF35H"
need "$L/packages/graphics/mesa/package.mk"             'PKG_STAMP+=" VULKAN=' "mesa: manca PKG_STAMP su VULKAN"
need "$L/packages/lakka/retroarch_base/retroarch/package.mk" 'PKG_STAMP+=" VULKAN=' "retroarch: manca PKG_STAMP su VULKAN"
need "$RK/packages/ikemen-go/launcher/ikemen_libretro.info" 'single_purpose = "true"' "IKEMEN GO non comparirebbe in Core senza contenuto"
need "$RK/packages/gtasa/launcher/gtasa_libretro.info" 'single_purpose = "true"' "GTA SA non comparirebbe in Core senza contenuto"
need "$RK/options"                                      'ADDITIONAL_PACKAGES+=" gtasa"' "options: GTA SA non aggiunto"
need "$RK/options"                                      'ADDITIONAL_PACKAGES+=" re3"' "options: re3 non aggiunto"
need "$RK/options"                                      'ADDITIONAL_PACKAGES+=" openxeenng"' "options: OpenXeenNG non aggiunto"
need "$RK/options"                                      'ADDITIONAL_PACKAGES+=" deva_adventures"' "options: Deva's Awesome Adventures non aggiunto"
# re3, se c'e': i file che servono e il .info monouso (se no non compare fra
# i Core senza contenuto col filtro di serie)
if [ -n "${RF35H_RE3_PKG:-}" ]; then
	for f in "$RK/packages/re3/package.mk" \
	         "$RK/packages/re3/files/re3_libretro.info" \
	         "$RK/packages/re3/files/re3.ini" \
	         "$RK/packages/re3/patches/0009-Add-a-libretro-core-build-RE3_LIBRETRO.patch"; do
		[ -e "$f" ] || { echo "apply: manca $f" >&2; exit 1; }
	done
	need "$RK/packages/re3/files/re3_libretro.info" 'single_purpose = "true"' "GTA III (re3) non comparirebbe in Core senza contenuto"
fi
[ -x "$RK/packages/gtasa/scripts/rf35h-gtasa" ] || { echo "apply: rf35h-gtasa non eseguibile" >&2; exit 1; }
for t in rf35h-led rf35h-brightness rf35h-diag rf35h-ra-guard; do
  [ -x "$RK/packages/rf35h-utils/scripts/$t" ] || { echo "apply: manca o non eseguibile $t" >&2; exit 1; }
done

echo
echo "fatto. build:"
echo "  cd $L && PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 UBOOT_SYSTEM=rf35h make image"
