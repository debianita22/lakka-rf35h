#!/bin/bash
# verify-claims.sh - controlla che ogni modifica dichiarata sia DAVVERO presente.
#
# Nato da un incidente: diverse modifiche al README, fatte con un replace che
# non verificava l'ancora, stampavano "ok" anche quando non cambiavano nulla, e
# meta' della documentazione di tre giorni non e' mai arrivata. Il codice in
# quel caso era integro, ma nulla lo garantiva: questo script lo garantisce.
#
# Uso: tools/verify-claims.sh <albero-lakka-con-overlay-applicato> [overlay]
#      (l'albero deve essere passato per apply.sh)
set -u
W="${1:?uso: $0 <albero-lakka> [overlay]}"
O="${2:-$(cd "$(dirname "$0")/.." && pwd)}"
P="${O}/packages/rf35h-utils"
K="${W}/projects/Rockchip/devices/RK3326/linux/linux.aarch64.conf"
RA="${W}/packages/lakka/retroarch_base/retroarch/package.mk"
SDL="${W}/packages/lakka/lakka_depends/SDL/package.mk"
SWAY="${W}/packages/wayland/compositor/sway/config/config"
Z010="${O}/patches/linux/z-010-add-rf35h-dts.patch"
bad=0; n=0

chk() {
	n=$((n + 1))
	if eval "$2" >/dev/null 2>&1; then
		printf '  ok     %s\n' "$1"
	else
		printf '  MANCA  %s\n' "$1"; bad=$((bad + 1))
	fi
}

echo "== integrazione (albero dopo apply.sh)"
chk "sway: niente barra di stato"            "! grep -q status_command '$SWAY'"
chk "sway: sfondo nero"                      "grep -q 'bg #000000 solid_color' '$SWAY'"
# La copia in /storage non si aggiorna da sola: senza migrazione chi aveva gia'
# la configurazione di serie continuava a vedere barra e sfondo.
chk "sway: migrazione della vecchia copia"   "grep -q 'rf35h-backup' '${W}/packages/wayland/compositor/sway/scripts/sway-config'"
chk "RetroArch: PKG_STAMP su DISPLAYSERVER"  "grep -q 'PKG_STAMP=\"\${DISPLAYSERVER}\"' '$RA'"
chk "RetroArch: audio_out_rate 44100"        "grep -q 'audio_out_rate = \"44100\"' '$RA'"
chk "RetroArch: resampler quality 2"         "grep -q 'audio_resampler_quality = \"2\"' '$RA'"
chk "SDL: host senza sysroot del target"     "! sed -n '/PKG_CONFIGURE_OPTS_HOST=/,/without-x\"/p' '$SDL' | grep -q SYSROOT_PREFIX"
chk "SDL: target conserva ALSA"              "sed -n '/PKG_CONFIGURE_OPTS_TARGET=/,/^\$/p' '$SDL' | grep -qE -- '--enable-alsa([[:space:]]|\\\\\\\\|\$)'"
chk "applewin: xxd:host"                     "grep -q 'xxd:host' '${W}/packages/lakka/libretro_cores/applewin/package.mk'"
chk "uae4arm: rinomina numbers"              "grep -q td_numbers '${W}/packages/lakka/libretro_cores/uae4arm/package.mk'"
chk "cannonball: -std=gnu++11"               "grep -q 'std=gnu++11' '${W}/packages/lakka/libretro_cores/cannonball/package.mk'"
# SND_SOC_ROCKCHIP non esiste come simbolo (7.0.1 e 7.2.7): portarlo a =y era
# una riga morta. Conta l'I2S; e l'opzione morta non deve tornare.
chk "kconfig: I2S built-in"                   "grep -q '^CONFIG_SND_SOC_ROCKCHIP_I2S=y' '$K'"
chk "kconfig: niente opzione morta ROCKCHIP"  "! grep -q '^CONFIG_SND_SOC_ROCKCHIP=y' '$K'"
chk "kconfig: amplificatore modulo"          "grep -q '^CONFIG_SND_SOC_SIMPLE_AMPLIFIER=m' '$K'"
chk "kconfig: debug spento"                  "grep -q '^# CONFIG_DEBUG_PREEMPT is not set' '$K' && grep -q '^# CONFIG_DEBUG_GPIO is not set' '$K'"

# Tasti volume su scala cubica a passi del 5 %. Storia: prima passi da 2 dB
# (fondo risolto, cima a salti 94->74->59->47 %), prima ancora 0,5 dB (160
# pressioni). Il widget deve mostrare la STESSA scala, arrotondare invece di
# troncare (0,9499 -> 95, non 94), e mostrare 0 al muto (in cubica varrebbe 5 %).
chk "RetroArch: tasti volume su scala cubica"   "grep -q 'cbrtf(powf(10.0f, cur / 20.0f))' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"
chk "RetroArch: griglia del 5 %"                "grep -q 'x \* 20.0f + 1e-4f' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"
chk "RetroArch: widget sulla stessa scala"      "grep -q 'cbrt(pow(10, new_volume/20))' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"
chk "RetroArch: widget arrotonda"               "grep -q '100.0f + 0.5f' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"
chk "RetroArch: widget 0 al muto"               "grep -q 'new_volume <= -79.9f) ? 0.0f' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"
chk "RetroArch: niente residui dei passi in dB" "! grep -q -- 'set_volume(settings, -2.0f' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch' && ! grep -q 'new_volume < -40.0f' '${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1006-volume-steps.patch'"

# free() all'uscita: config_string_options() marca i values con SD_FREE_FLAG_VALUES
# e menu_setting_free() li libera. Passando costanti, RetroArch moriva di SIGABRT
# ("free(): invalid pointer") a ogni uscita: 4 crash su 4 uscite registrate.
M1003="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch"
# 7 tendine, tutte del device (IKEMEN GO sta in Core senza contenuto)
chk "RetroArch: le 7 opzioni del menu sono allocate" "[ \"\$(grep -cE '^\+ +strdup\(RF35H_[A-Z_]+\),\$' '$M1003')\" = 7 ]"
chk "RetroArch: nessuna costante passata come values" "! grep -qE '^\+ +RF35H_[A-Z_]+(MODES|SPEEDS|SERVERS|OUTS|REGIONS),\$' '$M1003'"
chk "generatore del menu: stessi 7 strdup"          "[ \"\$(grep -cE '^ +strdup\(RF35H_[A-Z_]+\),\$' '$O/tools/gen-retroarch-rf35h-menu.py')\" = 7 ]"

M1005="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1005-wifi-connect-wait.patch"
M1008="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1008-connmanctl-hardening.patch"
# connmanctl: popen() mai controllato (un fallimento e' un SEGV) e lista delle
# reti svuotata mentre il menu la legge da un altro thread. Vedi il SEGV del 22/9.
chk "connmanctl: la 1008 arriva nell'albero"         "[ -f '$M1008' ]"
chk "connmanctl: refresh_services controlla popen"  "grep -q '^+   if (!serv_file)' '$M1008'"
chk "connmanctl: lista scambiata alla fine"          "grep -q '^+   connman->scan.net_list = net_list;' '$M1008'"
chk "connmanctl: tolti tutti e 5 i pclose(popen())" "[ \"\$(grep -c '^-.*pclose(popen(' '$M1008')\" = 5 ]"
# La riga del refresh finale diff la allinea con quella originale (contesto,
# non "+"): si controllano le proprieta', non il conteggio delle righe aggiunte.
chk "attese Wi-Fi: lettura privata di connmanctl"   "grep -q '^+static bool connmanctl_service_state' '$M1005'"
chk "attese Wi-Fi: nessun refresh dentro le attese" "awk '/^[+ ]static bool connmanctl_wait_(for_service|connected)\\(/{f=1} f && /refresh_services/{bad=1} f && /^[+ ]}/{f=0} END{exit bad}' '$M1005'"
chk "attese Wi-Fi: un refresh alla fine"            "grep -A4 '^+   success = connmanctl_wait_connected(netid, 15);' '$M1005' | grep -q 'connmanctl_refresh_services(connman);'"

M1009="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1009-wifi-list-lock.patch"
M1010="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1010-config-atomic-write.patch"
chk "connmanctl: i 4 cicli su popen protetti"       "[ \"\$(grep -c '^+.*while (command_file && fgets' '$M1008')\" = 4 ]"
chk "connmanctl: tmp liberato, AP inizializzato"     "grep -q '^+   free(tmp);' '$M1008' && grep -q '^+      if (!\*ap_name || !\*pass_key)' '$M1008'"
chk "lista Wi-Fi: 7 regioni sotto lock"              "[ \"\$(grep -c '^+.*driver_wifi_list_lock();' '$M1009')\" = 7 ]"
chk "lista Wi-Fi: password alla rete per id"         "grep -q '^+static char menu_wifi_dialog_netid' '$M1009'"
chk "config: scrittura atomica (fsync + rename)"     "grep -q 'fsync(fileno(file))' '$M1010' && grep -q '^+            if (ok && rename(tmp_path, path) != 0)' '$M1010'"

M1003B="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch"
# Tendine del menu: per gli array handle decide se la chiave si rilegge dal file.
chk "menu: le 7 tendine si rileggono (handle=true)"  "[ \"\$(grep -cE '^\+   SETTING_ARRAY\(\"rf35h_[a-z_]+\",.*, true\);$' '$M1003B')\" = 7 ]"
chk "menu: chiave vuota -> stato reale del device"   "grep -q '^+static void rf35h_arrays_fill(settings_t \*settings)' '$M1003B' && grep -q '^+   rf35h_arrays_fill(settings);' '$M1003B'"
chk "generatore: handle=true per le 7 tendine"       "[ \"\$(grep -cE 'SETTING_ARRAY\(\"rf35h_.*DEFAULT_RF35H_[A-Z_]+, true\);' '$O/tools/gen-retroarch-rf35h-menu.py')\" = 7 ]"

# Revisione delle patch di RetroArch per la 1.1.0: Samba e il modo "transfer"
# della USB-C (1007), toggle dei servizi senza gare ne' zombie (1007), stop di
# scraper e aggiornamento senza bloccare il menu, valori del menu giusti subito
# dopo un cambio, installazione dell'aggiornamento solo dopo "rf35h-update
# install" (batteria), uscita audio USB per id con ripiego all'avvio (1003), e
# gli irrobustimenti: password WPA lunghe (1009), tether_status (1008), fsync
# della directory (1010), nome del SoC (1004), array RF35H nel ciclo (1003).
M1004="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1004-arm64-neon-cpu-model.patch"
M1007="${W}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1007-service-toggle-keep-conf.patch"
chk "Samba: il flag messo da parte conta come spento"    "grep -q '^+bool config_samba_enabled(void)' '$M1007' && [ \"\$(grep -c '^+         settings->bools.samba_enable, config_samba_enabled());' '$M1007')\" = 2 ]"
chk "Samba: il salvataggio non tocca il flag da parte"   "grep -q '^+   if (!filestream_exists(RF35H_SAMBA_ASIDE_PATH))' '$M1007'"
chk "Samba: acceso dal menu, via anche il flag da parte" "grep -q '^+      filestream_delete(RF35H_SAMBA_ASIDE_PATH);' '$M1007'"
chk "Samba: stesso nome del flag in rf35h-usb"           "grep -q 'LAKKA_SAMBA_DISABLED_FILE_PATH \".rf35h-usb\"' '$M1007' && grep -q 'SMB_ASIDE=\"\${SMB_FLAG}.rf35h-usb\"' '$P/scripts/rf35h-usb'"
chk "toggle servizi: file prima del fork, niente zombie" "grep -q '^+   config_set_service_state(path, enable);' '$M1007' && grep -q '^+      while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) { }' '$M1007' && grep -q '^+         _exit(127);' '$M1007' && [ \"\$(grep -c '^+   systemd_service_spawn(enable' '$M1007')\" = 2 ]"
chk "toggle servizi: .conf creato senza troncare"        "grep -q '^+      if ((f = fopen(conf_path, \"a\")))' '$M1007'"
chk "scraper e aggiornamento: stop senza bloccare"       "[ \"\$(grep -c 'systemctl --no-block stop rf35h-' '$M1003B')\" = 2 ] && ! grep -q 'systemctl stop rf35h-' '$M1003B' && grep -q 'systemctl --no-block stop rf35h-scrape.service' '$O/tools/gen-retroarch-rf35h-menu.py'"
chk "menu: dopo un cambio 3 s senza rileggere gli stati" "grep -q '^+   rf35h_last_run = cpu_features_get_time_usec();' '$M1003B' && grep -q '^+         && cpu_features_get_time_usec() - rf35h_last_run < 3000000)' '$M1003B'"
chk "aggiornamento: rf35h-update install, poi riavvio"   "grep -q 'popen(\"/usr/bin/rf35h-update install\", \"r\")' '$M1003B' && grep -q 'WEXITSTATUS(st) == 0' '$M1003B'"
chk "rf35h-update ha il comando install del menu"        "grep -qE '^[[:space:]]*\"?([a-z-]+[|])*install([|][a-z-]+)*\"?[)]' '$P/scripts/rf35h-update'"
chk "audio USB: scheda per id, ripiego all'avvio"        "grep -q 'plughw:CARD=%s,DEV=0' '$M1003B' && grep -q '^+   rf35h_audio_device_check(settings);' '$M1003B'"
chk "array RF35H letti con la loro dimensione"           "grep -q '^+               rf35h_array_size(settings, array_settings\[i\].ptr));' '$M1003B'"
chk "Wi-Fi: password WPA fino a 63 caratteri"           "grep -q '^+   char passphrase\[65\];' '$M1009'"
chk "connmanctl: tether_status controlla fgets"         "grep -q '^+   if (!fgets(ln, sizeof(ln), command_file))' '$M1008'"
chk "config: fsync della directory dopo la rename"      "grep -q 'open(tmp_path, O_RDONLY | O_DIRECTORY)' '$M1010'"
chk "nome della CPU: niente overflow con vendor lunghi" "grep -q 'i < sl; i++)' '$M1004' && grep -q 'i < sl; i++)' '$O/tools/gen-retroarch-arm64-fixes.py'"

echo "== Vulkan accanto a OpenGL ES, IKEMEN GO"
OPT="${W}/projects/Rockchip/devices/RK3326/options"
IK="${O}/packages/ikemen-go"
IKP="${IK}/patches"
L1="${IK}/scripts/rf35h-ikemen"
chk "options: Vulkan acceso ma spegnibile (RF35H_VULKAN)"  "grep -q 'RF35H_VULKAN:-yes' '$OPT' && grep -q 'VULKAN=\"vulkan-loader\"' '$OPT'"
chk "options: IKEMEN GO spegnibile (RF35H_IKEMEN)"       "grep -q 'RF35H_IKEMEN:-yes' '$OPT' && grep -q 'ADDITIONAL_PACKAGES+=\" ikemen-go\"' '$OPT'"
chk "wlroots: niente renderer Vulkan sull'RF35H"         "grep -q 'UBOOT_SYSTEM}\" != \"rf35h\"' '${W}/packages/wayland/lib/wlroots/package.mk'"
# stamp su VULKAN: Mesa, RetroArch e ogni core che legge VULKAN_SUPPORT
chk "stamp su VULKAN: Mesa e RetroArch"                  "grep -q 'PKG_STAMP+=\" VULKAN=' '${W}/packages/graphics/mesa/package.mk' && grep -q 'PKG_STAMP+=\" VULKAN=' '$RA'"
chk "stamp su VULKAN: tutti i core che lo leggono"       "[ \"\$(grep -lE 'VULKAN_SUPPORT' '${W}'/packages/lakka/libretro_cores/*/package.mk | wc -l)\" = \"\$(grep -l 'PKG_STAMP+=\" VULKAN=' '${W}'/packages/lakka/libretro_cores/*/package.mk | wc -l)\" ]"
chk "RetroArch: PanVK sbloccato nel servizio"            "grep -qx 'Environment=PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1' '$P/retroarch.service.d/rf35h-vulkan.conf'"
chk "RetroArch: ripiego automatico su gl"                "grep -q 'rf35h-ra-guard pre' '$P/retroarch.service.d/rf35h-vulkan.conf' && grep -q 'rf35h-ra-guard post' '$P/retroarch.service.d/rf35h-vulkan.conf' && [ -x '$P/scripts/rf35h-ra-guard' ]"
chk "rf35h-utils installa drop-in e profile.d"           "grep -q 'rf35h-vulkan.conf' '$P/package.mk' && grep -q '99-rf35h-vulkan.conf' '$P/package.mk'"
LC="${IK}/launcher/ikemen_libretro.c"; LI="${IK}/launcher/ikemen_libretro.info"
chk "IKEMEN GO in Core senza contenuto (filtro Monouso)"  "grep -qx 'supports_no_game = \"true\"' '$LI' && grep -qx 'single_purpose = \"true\"' '$LI' && grep -q 'RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME' '$LC'"
chk "core lanciatore: avvio via systemd, niente blocco"  "grep -q \"start %s >/dev/null 2>&1\" '$LC' && grep -q 'systemctl --no-block start rf35h-ikemen.service' '$L1'"
chk "core lanciatore: renderer nelle opzioni, dallo stato" "grep -q 'ikemen_renderer' '$LC' && grep -q 'RETRO_ENVIRONMENT_SET_VARIABLE' '$LC' && grep -q 'renderer 2>/dev/null' '$LC'"
chk "core lanciatore: compilato e installato col .info"   "grep -q 'launcher/ikemen_libretro.c' '$IK/package.mk' && grep -q 'ikemen_libretro.info' '$IK/package.mk' && grep -q 'IKEMEN GO.png' '$IK/package.mk'"
chk "IKEMEN GO fuori da Impostazioni dispositivo (1003)" "! grep -qi ikemen '$M1003'"
chk "core lanciatore: tempo di gioco vero nel .lrtl"     "grep -q 'IKEMEN GO/IKEMEN GO.lrtl' '$L1' && grep -q 'runtime_add \"\${el}\"' '$L1'"
chk "retroarch.cfg letto come RetroArch (prima chiave)"  "grep -q 'head -n 1' '$P/scripts/rf35h-ra-guard' && grep -q 'head -n 1' '$L1'"
chk "IKEMEN: tag egl gles nodialog e arenas"             "grep -q 'go build -tags \"egl gles nodialog\"' '$IK/package.mk' && grep -q 'GOEXPERIMENT=arenas' '$IK/package.mk'"
chk "IKEMEN: sorgenti fissati per commit"                "grep -q '^PKG_VERSION=\"81c6da71d689625e20db79586815b695da00dd6d\"' '$IK/package.mk' && grep -q '^PKG_VERSION=\"11d6ea7223fc15209664730503412841045f7939\"' '${O}/packages/ikemen-screenpack/package.mk'"
chk "IKEMEN: GLES su Linux (render_gles32 con tag gles)" "grep -q '^+//go:build android || gles' '$IKP/ikemen-go-0001-linux-gles-renderer-nodialog.patch'"
chk "IKEMEN: menu col renderer solo se compilato"        "grep -q 'isRendererAvailable' '$IKP/ikemen-go-0001-linux-gles-renderer-nodialog.patch'"
chk "IKEMEN: FBO di post-processing RGBA8 su GLES"       "grep -q '^+			gl.RGBA8,' '$IKP/ikemen-go-0002-gles-vulkan-fixes.patch'"
chk "IKEMEN: shader esterni GLES con precision, senza crash" "grep -q 'esPostHeader' '$IKP/ikemen-go-0002-gles-vulkan-fixes.patch' && grep -q 'skipped' '$IKP/ikemen-go-0002-gles-vulkan-fixes.patch'"
chk "IKEMEN: Vulkan, limiti della GPU integrata e scissor" "grep -q 'Limits of the GPU actually used' '$IKP/ikemen-go-0002-gles-vulkan-fixes.patch' && grep -q 'Clamp to the render target' '$IKP/ikemen-go-0002-gles-vulkan-fixes.patch'"
chk "IKEMEN: lanciatore con override Mesa per renderer"  "grep -q 'MESA_GLES_VERSION_OVERRIDE=3.2' '$L1' && grep -q 'MESA_GL_VERSION_OVERRIDE=3.3' '$L1'"
chk "IKEMEN: ombre 3D sempre spente, ripiego su opengles" "grep -q 'ini_set \"\${CFG}\" Video EnableModelShadow 0' '$L1' && grep -q 'ikemen-fallback-' '$L1'"
chk "IKEMEN: uno stop non e' un errore di renderer"      "grep -q 'STOPPING=1' '$L1' && grep -q 'STOPPING}\" = 1' '$L1'"
# Vulkan in IKEMEN: PanVK sul Mali-G31 e' Vulkan 1.0, il renderer di IKEMEN
# vuole la 1.3; forzata, schermo nero (provato sulla console il 25/9/2026).
chk "IKEMEN: Vulkan spento anche nel suo menu (0003)"   "grep -q 'export IKEMEN_DISABLE_VULKAN=1' '$L1' && grep -q 'return !vulkanDisabled()' '$IKP/ikemen-go-0003-disable-vulkan.patch'"
chk "IKEMEN: vulkan non si sceglie ne' si eredita"      "grep -q \"Vulkan non e' disponibile per IKEMEN\" '$L1' && ! grep -q '\"Vulkan 1.3\") echo vulkan' '$L1' && ! grep -q '{ \"vulkan\"' '$LC'"
chk "IKEMEN: servizio in conflitto con RetroArch"        "grep -qx 'Conflicts=retroarch.service' '$IK/system.d/rf35h-ikemen.service' && grep -q 'rf35h-ikemen back' '$IK/system.d/rf35h-ikemen.service'"
chk "IKEMEN: icone PNG installate (senza, panic)"        "grep -q 'rm -f \${share}/external/icons/\*.ico' '$IK/package.mk' && ! grep -q 'icons/\*.png' '$IK/package.mk'"
chk "Go per l'host: checksum per amd64 e arm64"          "grep -q '990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282' '${O}/packages/golang-bin/package.mk' && grep -q 'c958a1fe1b361391db163a485e21f5f228142d6f8b584f6bef89b26f66dc5b23' '${O}/packages/golang-bin/package.mk'"
chk "SDL2 di IKEMEN: privata e con controllo delle feature" "grep -q 'libdir=/usr/lib/ikemen-sdl2' '${O}/packages/ikemen-sdl2/package.mk' && grep -q 'non abilitato dal configure' '${O}/packages/ikemen-sdl2/package.mk'"
chk "libxmp: statica, solo nel sysroot"                  "grep -q 'BUILD_SHARED=OFF' '${O}/packages/libxmp/package.mk' && grep -q 'DESTDIR=\${SYSROOT_PREFIX} ninja install' '${O}/packages/libxmp/package.mk'"
chk "build: --no-vulkan e --no-ikemen arrivano a make"   "grep -q 'RF35H_VULKAN=\"\${WITH_VULKAN}\"' '$O/build-lakka-rf35h.sh' && grep -q 'RF35H_IKEMEN=\"\${WITH_IKEMEN}\"' '$O/build-lakka-rf35h.sh'"

echo "== giochi: GTA SA, GTA III (re3), OpenXeenNG, Deva's Awesome Adventures"
RKP="${W}/projects/Rockchip/devices/RK3326/packages"
GT="${O}/packages/gtasa"; R3="${RKP}/re3"; OX="${O}/packages/openxeenng"; DV="${O}/packages/deva_adventures"
chk "options: i quattro giochi, ognuno spegnibile"      "( for g in GTASA:gtasa RE3:re3 OPENXEENNG:openxeenng DEVA_ADVENTURES:deva_adventures; do grep -q \"RF35H_\${g%%:*}:-yes\" '$OPT' && grep -q \"ADDITIONAL_PACKAGES+=\\\" \${g#*:}\\\"\" '$OPT' || exit 1; done )"
chk "apply: i pacchetti dei giochi nell'albero"        "( for d in gtasa openxeenng rust-bin rust-std-aarch64 deva_adventures; do [ -f '$RKP'/\$d/package.mk ] || exit 1; done )"
# re3 non ha licenza: fuori dall'overlay, in un repository privato; nell'albero
# e nell'immagine solo con --re3 (le options lo aggiungono se il pacchetto c'e')
chk "re3: fuori dall'overlay, nell'immagine solo con --re3" "[ ! -e '$O/packages/re3' ] && grep -q 'packages/re3/package.mk\" \]; then' '$OPT' && grep -q 'RF35H_RE3_PKG=\"\${RE3_PKG}\"' '$O/build-lakka-rf35h.sh'"
chk "build: --no-gtasa/re3/openxeenng/deva arrivano a make" "grep -q 'RF35H_GTASA=\"\${WITH_GTASA}\"' '$O/build-lakka-rf35h.sh' && grep -q 'RF35H_RE3=\"\${WITH_RE3}\"' '$O/build-lakka-rf35h.sh' && grep -q 'RF35H_OPENXEENNG=\"\${WITH_OPENXEENNG}\"' '$O/build-lakka-rf35h.sh' && grep -q 'RF35H_DEVA_ADVENTURES=\"\${WITH_DEVA}\"' '$O/build-lakka-rf35h.sh'"
# --keep-going: un gioco che non compila toglie il gioco, non ferma tutto;
# openal-soft e mpg123 (di due giochi) restano pacchetti di sistema
chk "keep-going: un gioco rotto si toglie dall'immagine" "grep -q 'drop_extra \"\${EXTRA}\"' '$O/build-lakka-rf35h.sh' && grep -q 'openxeenng|rust-bin|rust-std-aarch64' '$O/build-lakka-rf35h.sh' && ! sed -n '/^extra_of()/,/^}/p' '$O/build-lakka-rf35h.sh' | grep -q 'openal-soft'"
chk "re3: avviso uso personale alla build"              "grep -q 're3 incluso: il suo codice non ha licenza' '$O/build-lakka-rf35h.sh'"
# GTA SA e GTA III: lanciatore/core in Core senza contenuto, nessun dato del gioco
chk "GTA SA: lanciatore in Core senza contenuto"        "grep -qx 'supports_no_game = \"true\"' '$GT/launcher/gtasa_libretro.info' && grep -qx 'single_purpose = \"true\"' '$GT/launcher/gtasa_libretro.info'"
chk "GTA SA: servizio in conflitto con RetroArch"       "grep -qx 'Conflicts=retroarch.service' '$GT/system.d/rf35h-gtasa.service' && grep -q 'rf35h-gtasa run' '$GT/system.d/rf35h-gtasa.service'"
chk "GTA SA: nessun file del gioco nel pacchetto"       "[ -f '$GT/package.mk' ] && ! find '$GT' -iname '*.so' -o -iname '*.apk' -o -iname '*.obb' | grep -q ."
if [ -f "$R3/package.mk" ]; then
	chk "re3 (--re3): commit fissato, 33 patch, mirror"   "grep -q '^PKG_VERSION=\"3233ffe1c4b99e8efb4c41c6794b4fce880cf503\"' '$R3/package.mk' && [ \$(ls '$R3'/patches/*.patch | wc -l) = 33 ] && grep -q 'hottabxp/re3' '$R3/package.mk'"
	chk "re3 (--re3): core in Core senza contenuto"       "grep -qx 'single_purpose = \"true\"' '$R3/files/re3_libretro.info' && grep -q 'gamefiles' '$R3/package.mk'"
	chk "re3 (--re3): RE3_PGO non obbligatoria"            "grep -q 'case \"\${RE3_PGO:-}\" in' '$R3/package.mk'"
fi
# Deva e OpenXeenNG dai loro repository, a un commit fissato: niente archivi
# nell'overlay, niente segnaposto del proprietario rimasti
chk "Deva: dal suo repository, commit della 1.0.0"      "grep -qx 'PKG_VERSION=\"1e93ae98d9cd2cb0b8f6039e48e92aa362460424\"' '$DV/package.mk' && grep -q '^PKG_URL=\"\${PKG_SITE}.git\"' '$DV/package.mk' && grep -q '^PKG_SITE=\"https://github.com/[^/]*/deva-adventures\"' '$DV/package.mk' && [ ! -e '$DV/archive' ]"
chk "Deva: dati in /usr/share"                          "grep -q 'DATA_DIR=/usr/share/deva_adventures' '$DV/package.mk' && grep -q 'cp -PR data/deva_adventures/.' '$DV/package.mk'"
chk "OpenXeenNG: dal suo repository, commit afe41a1"    "grep -qx 'PKG_VERSION=\"afe41a19bb74e7dc81984f00504c40758efee5b2\"' '$OX/package.mk' && grep -q '^PKG_URL=\"\${PKG_SITE}.git\"' '$OX/package.mk' && grep -q '^PKG_SITE=\"https://github.com/[^/]*/OpenXeenNG\"' '$OX/package.mk' && [ ! -e '$OX/archive' ]"
chk "nessun segnaposto @GH_OWNER@"                      "! grep -rq '@GH_OWNER@' '$O/packages' '$O/apply.sh' '$O/integration'"
chk "OpenXeenNG: build senza rete (workspace ridotto)"    "grep -q 'cargo build --release --offline --locked -p openxeenng-libretro' '$OX/package.mk' && grep -q '^-    \"crates/tool\",' '$OX/patches/openxeenng-0001-lakka-libretro-only-workspace.patch'"
chk "OpenXeenNG: triple ufficiale, link col gcc di LibreELEC" "grep -q 'triple=\"aarch64-unknown-linux-gnu\"' '$OX/package.mk' && grep -q 'CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=\"\${CC}\"' '$OX/package.mk'"
# Rust ufficiale: stessa versione di rust di Lakka (i *-snapshot la seguono),
# libreria per aarch64 col checksum del manifest del canale 1.95.0
chk "rust-bin: versione = rust di Lakka = rust-std-aarch64" "v=\$(sed -n 's/^PKG_VERSION=\"\\(.*\\)\"/\\1/p' '${W}/packages/rust/rust/package.mk'); grep -q \"^PKG_VERSION=\\\"\$v\\\"\" '${O}/packages/rust-bin/package.mk' && grep -q \"^PKG_VERSION=\\\"\$v\\\"\" '${O}/packages/rust-std-aarch64/package.mk'"
chk "rust-bin: binari ufficiali, std aarch64 verificata" "grep -q 'PKG_DEPENDS_UNPACK=\"rustc-snapshot cargo-snapshot rust-std-snapshot rust-std-aarch64\"' '${O}/packages/rust-bin/package.mk' && grep -q '3a21b271b1ff973b94d69b25e7a39992f9fbcae1ab6d9475844a23e6ad3908ac' '${O}/packages/rust-std-aarch64/package.mk'"

echo "== pacchetto rf35h-utils"
chk "DAC: default 28% applicato sempre"      "grep -q '^DEFAULT=28' '$P/scripts/rf35h-dac-volume' && ! grep -q '^ConditionPathExists' '$P/system.d/rf35h-dacvol.service'"
chk "headphone-sense non abilitato"          "! grep -q 'enable_service rf35h-audio.service' '$P/package.mk'"
chk "servizi rk915-load, overrides, dacvol"  "grep -q 'enable_service rf35h-rk915-load.service' '$P/package.mk' && grep -q 'enable_service rf35h-overrides.service' '$P/package.mk' && grep -q 'enable_service rf35h-dacvol.service' '$P/package.mk'"
chk "override: 11 .cfg e 1 .opt"             "[ \$(find '$P/overrides' -name '*.cfg' | wc -l) = 11 ] && [ \$(find '$P/overrides' -name '*.opt' | wc -l) = 1 ]"
chk "rf35h-i2c rifiuta scritture al codec"   "grep -q RF35H_I2C_FORCE '$P/sources/rf35h-i2c.c'"
chk "timesyncd: nessun ordinamento"          "! grep -qE '^(After|Wants|Requires)=' '$P'/system.d/systemd-timesyncd.service.d/*.conf"

# revisione del codice: difetti corretti, che non devono tornare
chk "dac-volume status: controllo e registro distinti" "grep -q 'registro \$(( 255 - c ))' '$P/scripts/rf35h-dac-volume' && ! grep -q 'attuale (registro): values' '$P/scripts/rf35h-dac-volume'"
chk "rk915-load: fallimento non nascosto"     "grep -q 'modprobe rk915 fallito' '$P/scripts/rf35h-rk915-load' && ! grep -q 'modprobe rk915 2>/dev/null || exit 0' '$P/scripts/rf35h-rk915-load'"
chk "rumble: durata limitata a 1-10000 ms"    "grep -q 'ms > 10000' '$P/sources/rf35h-rumble.c'"
chk "ledd: fallimento inotify nel journal"    "grep -q 'inotify_init1 fallito' '$P/sources/rf35h-ledd.c'"
chk "brightness: lettura arrotondata"         "grep -q 'CUR \* 100 + MAX / 2' '$P/scripts/rf35h-brightness' && grep -q 'MAX=255 ;; esac' '$P/scripts/rf35h-brightness'"
chk "zram: percentuale validata (1-150)"      "grep -q 'PCT fuori da 1-150' '$P/scripts/rf35h-zram' && grep -q 'SIZE_PCT%\"%\"' '$P/scripts/rf35h-zram'"
chk "menu: descrizione LED 'charging' completa" "grep -q 'verde fisso a carica completa' '${O}/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch' && grep -q 'solid green when full' '${O}/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch'"
chk "check-menu-labels definisce HAVE_LAKKA"     "grep -q 'flags.append(\"-DHAVE_LAKKA=1\")' '${O}/tools/check-menu-labels.py'"
chk "led raw: validazione stretta"            "grep -q '(0-255 o 0x00-0xFF)' '$P/scripts/rf35h-led' && ! grep -q '0x\[0-9a-fA-F\]\*|\[0-9\]\*) ;;' '$P/scripts/rf35h-led'"

# sicurezza: punto d'accesso e toggle dei servizi
chk "AP: nessuna password pubblica di default" "grep -q 'gen_pass()' '$P/scripts/rf35h-ap' && ! grep 'printf' '$P/scripts/rf35h-ap' | grep -q 'PASSWORD=RetroArch'"
chk "AP: converte la password pubblica"       "grep -q \"grep -qx 'PASSWORD=RetroArch'\" '$P/scripts/rf35h-ap'"
chk "AP: il menu mostra le credenziali"       "grep -q 'rf35h-ap prepare' '${O}/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch' && grep -q 'password: %s' '${O}/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch'"
# 1007: non basta il toggle del menu, anche il salvataggio della configurazione
# (a ogni uscita, spegnimento o riavvio) svuotava sshd.conf
R1007="${O}/patches/retroarch/retroarch-1007-service-toggle-keep-conf.patch"
chk "servizi: il salvataggio non svuota sshd.conf" "grep -q '^+   config_set_service_state(LAKKA_SSH_PATH, settings->bools.ssh_enable);' '$R1007' && grep -q '^-      filestream_delete(LAKKA_SSH_PATH);' '$R1007'"
chk "servizi: il toggle non svuota la config"  "grep -q '^+   config_set_service_state(path, enable);' '$R1007'"
chk "servizi: spento = .disabled, come LibreELEC" "grep -q '^+      filestream_rename(conf_path, disabled_path);' '$R1007' && grep -q '^+            && filestream_rename(disabled_path, conf_path) == 0)' '$R1007'"

# Kernel 7.2.y, pila snella: il ramo 7.0 e' fuori supporto dal 27/06/2026.
# Versione e SHA256 stanno solo in integration/linux-rf35h.patch: l'albero
# deve avere quelle, e lo SHA256 dev'essere un SHA256.
LPK="${W}/packages/linux/package.mk"; RKP="${W}/projects/Rockchip/devices/RK3326/patches/linux"; DEF="${W}/packages/linux/patches/default"
KV="$(sed -n 's/^+ *PKG_VERSION="\([0-9][0-9.]*\)".*/\1/p' "${O}/integration/linux-rf35h.patch")"
KS="$(sed -n 's/^+ *PKG_SHA256="\([^"]*\)".*/\1/p' "${O}/integration/linux-rf35h.patch")"
chk "kernel ${KV:-?} con il suo SHA256"        "[ -n '${KV}' ] && echo '${KS}' | grep -qxE '[0-9a-f]{64}' && grep -q 'PKG_VERSION=\"${KV}\"' '$LPK' && grep -q '${KS}' '$LPK'"
chk "kernel 7.2.y (ramo supportato)"           "case '${KV}' in 7.2.*) true ;; *) false ;; esac"
chk "sorgente del kernel tenuto (AUTOREMOVE)"  "grep -q '\[ \"\${PKG_NAME}\" = \"linux\" \] && exit 0' '${W}/scripts/autoremove'"
chk "patch del kernel mancante: build ferma"   "grep -q 'kernel incompleto: una o piu' '$O/build-lakka-rf35h.sh'"

# LTO: "+lto", il flag che questa LibreELEC conosce (lto, lto-fat, lto-off),
# sui core che apply.sh elenca, se l'LTO dei core e' acceso (il build script
# passa RF35H_CORE_LTO). "+lto-parallel" non esiste: con quello per mesi
# nessun core ha avuto l'LTO, e nessun controllo se n'era accorto.
LTOC="$(sed -n 's/.*RF35H_LTO_CORES:-\([a-z0-9_ ]*\)}.*/\1/p' "${O}/apply.sh")"
nolto=""; nlto=0
for c in ${LTOC}; do
	pm="${W}/packages/lakka/libretro_cores/${c}/package.mk"
	[ -f "${pm}" ] || continue
	nlto=$((nlto + 1))
	grep -qE '^PKG_BUILD_FLAGS="([^"]* )?[+]lto( [^"]*)?"' "${pm}" || nolto="${nolto} ${c}"
done
if [ "${RF35H_CORE_LTO:-yes}" = "yes" ]; then
	chk "LTO (+lto) su ${nlto} core${nolto:+, manca a:${nolto}}" "[ ${nlto} -ge 22 ] && [ -z '${nolto}' ]"
fi
chk "nessun +lto-parallel (flag inesistente)"  "! grep -rqE '^PKG_BUILD_FLAGS=.*lto-parallel' '${W}/packages/lakka/libretro_cores' '${W}/packages/graphics/mesa' '${O}/packages'"
chk "Mesa con LTO (+lto)"                      "grep -qx 'PKG_BUILD_FLAGS=\"+lto\"' '${W}/packages/graphics/mesa/package.mk'"
chk "RetroArch con LTO (+lto)"                 "[ \"\$(grep -c '^PKG_BUILD_FLAGS=' '${W}/packages/lakka/retroarch_base/retroarch/package.mk')\" = 1 ] && grep -qx 'PKG_BUILD_FLAGS=\"+lto\"' '${W}/packages/lakka/retroarch_base/retroarch/package.mk'"
chk "pila snella: 10 patch per RK3326"         "[ \$(ls '$RKP'/*.patch | wc -l) -eq 10 ]"
chk "pila snella: 2 patch generiche"           "[ \$(ls '$DEF'/*.patch | wc -l) -eq 2 ]"
chk "0000 e 9901 nostre, a fuzz 0"             "grep -q 'rigenerata sulla 7.2.7' '$RKP/0000-rename-rk817-battery.patch' && grep -q 'rigenerata sulla 7.2.7' '$DEF/linux-9901-pm-disable-async-suspend-resume-by-default.patch'"
chk "z-001 e 0002-input-polldev fuori"         "[ ! -e '$RKP/z-001-st7703-xifan-xf35h-panel.patch' ] && [ ! -e '$RKP/0002-add-input-polldev.patch' ]"
chk "r-024 portata (dw_mmc senza slot)"        "grep -q 'host->mmc->caps2 & MMC_CAP2_WIFI_RK912' '$RKP/r-024-mainline-linux-hacks-for-rk915.patch'"
# Standby (flicker e lentezza al risveglio): r-034 di ROCKNIX invariata (CRU:
# MODE_CON e CLKSEL_CON(0)), z-034 nostra (GPLL, solo se acceso e agganciato).
chk "r-034: CRU salvato e rimesso (ROCKNIX)"   "grep -q 'register_syscore(&px30_clk_syscore)' '$RKP/r-034-px30-cru-suspend-resume-restore.patch' && grep -q 'sha256 3d867b7df6cf' '$RKP/r-034-px30-cru-suspend-resume-restore.patch'"
chk "z-034: GPLL rimesso solo se agganciato"   "grep -q '^+	px30_pmucru_base = reg_base;' '$RKP/z-034-px30-pmucru-gpll-resume.patch' && grep -q 'PX30_PLLCON1_LOCK_STATUS) && !(con1 & PX30_PLLCON1_PWRDOWN' '$RKP/z-034-px30-pmucru-gpll-resume.patch'"
chk "z-002 portata (devm_drm_panel_alloc)"     "grep -q 'devm_drm_panel_alloc' '$RKP/z-002-panel-generic-dsi.patch' && ! grep -q '^+.*drm_panel_init(&ctx' '$RKP/z-002-panel-generic-dsi.patch'"
# Standby (5/10/2026): l'init del pannello sta in prepare(); senza
# prepare_prev_first partiva con il DSI ancora spento.
chk "z-002: DSI acceso prima dell'init (prepare_prev_first)" "grep -q '^+    ctx->panel.prepare_prev_first = prev_first;' '$RKP/z-002-panel-generic-dsi.patch' && grep -q '^+static bool prev_first = true;' '$RKP/z-002-panel-generic-dsi.patch'"
chk "z-002: unprepare senza uscita anticipata"  "! grep -A2 'failed to enter sleep mode' '$RKP/z-002-panel-generic-dsi.patch' | grep -q 'return ret'"
chk "z-036: avviso sui comandi a DSI spento"    "grep -q 'sent with the host powered down' '$RKP/z-036-dw-mipi-dsi-power-trace.patch'"
# Standby (6/10/2026): il VOP a 3-7 fps dopo la riaccensione era il clock dei
# pixel passato al frazionario da CPLL a 1584 MHz.
chk "z-037: clock dei pixel sul divisore intero" "grep -q '^+	MUX(0, \"dclk_vopb_mux\", mux_dclk_vopb_p, CLK_SET_RATE_PARENT | CLK_SET_RATE_NO_REPARENT,' '$RKP/z-037-px30-dclk-vopb-integer.patch' && grep -q '^+	COMPOSITE(0, \"dclk_vopb_src\", mux_cpll_npll_p, CLK_SET_RATE_NO_REPARENT,' '$RKP/z-037-px30-dclk-vopb-integer.patch'"
chk "rk915: strncpy sostituita (7.2)"          "grep -q 'strscpy_pad(priv->name, RPU_DRIVER_NAME, 12)' '${W}/projects/Rockchip/devices/RK3326/packages/rk915/patches/0003-rk915-linux-7.2-strncpy.patch'"
chk "joypad: of_gpio ricostruito (7.2)"        "grep -q 'gpio_device_find_by_fwnode' '${W}/projects/Rockchip/devices/RK3326/packages/rocknix-joypad/patches/0003-rocknix-joypad-linux-7.2-of-gpio.patch'"
chk "perf senza strumenti dell'host (Rust)"   "[ \$(grep -c 'NO_RUST=1' '$LPK') -eq 2 ]"
chk "perf senza strumenti dell'host (shellck)" "[ \$(grep -c 'NO_SHELLCHECK=1' '$LPK') -eq 2 ]"
chk "hash dei pacchetti: nomi con spazi"       "grep 'xargs -d' '${W}/config/functions' | grep -q 'sha256sum'"
chk "sorgenti GNU prima da mirrors.kernel.org"  "grep -q 'for url in \${GNU_MIRROR_URL} ' '${W}/scripts/get_archive' && grep -q 'https://ftp.gnu.org/pub/gnu/\*)' '${W}/scripts/get_archive'"
chk "kernel: -mtune per la CPU del device"      "grep -qF 'export KCFLAGS+=\" -mtune=\${TARGET_CPU}\"' '${W}/packages/linux/package.mk'"
chk "cargo: linker del target senza config.toml" "grep -qF 'export \"CARGO_TARGET_\${_rf35h_cargo_target//-/_}_LINKER=\${TARGET_PREFIX}gcc\"' '${W}/config/functions'"
chk "sorgenti: per ultimo tarballs.nixos.org"    "grep -q '\"\${PACKAGE_MIRROR}\" \${HASHED_MIRROR_URL}; do' '${W}/scripts/get_archive' && grep -qF 'https://tarballs.nixos.org/sha256/\${PKG_SHA256}' '${W}/scripts/get_archive'"
chk "audiotest: giri letti con validazione"    "grep -q 'ignorato:' '$P/scripts/rf35h-audiotest' && grep -q '^set -f$' '$P/scripts/rf35h-audiotest'"
# su Lakka diff non c'e' (busybox senza CONFIG_DIFF): il confronto e' in awk
chk "audiotest: confronto senza diff"          "! grep -vE '^[[:space:]]*#' '$P/scripts/rf35h-audiotest' | grep -qE '(^|[;&|(]|then|if)[[:space:]]*diff[[:space:]]' && grep -qF 'FILENAME == ARGV[1]' '$P/scripts/rf35h-audiotest'"
chk "verify-kernel sceglie il kernel piu' alto" "grep -q \"sort -V | tail -1\" '${O}/verify-kernel.sh'"
chk "joypad: niente flag legacy nella build"   "! grep -qE '^[^#]*-DROCKNIX_OF_GPIO_LEGACY_PRESENT' '${W}/projects/Rockchip/devices/RK3326/packages/rocknix-joypad/package.mk'"

# L'orologio della console non e' affidabile: uno snapshot datato 29/9 era del 23.
chk "crashlog: boot id e build in ogni file"         "grep -q 'random/boot_id' '$P/scripts/rf35h-crashlog' && grep -q 'BUILD_ID' '$P/scripts/rf35h-crashlog'"
chk "crashlog: dichiara se l'orologio e' affidabile" "grep -q 'timesync/synchronized' '$P/scripts/rf35h-crashlog'"
chk "RetroArch: niente core dump"                    "grep -qx 'LimitCORE=0' '$P/retroarch.service.d/rf35h-crashlog.conf'"
# systemctl enable a ogni boot faceva ricaricare systemd: ~5 s di boot fermo.
chk "rf35h-ntp: niente ricaricamento di systemd"    "grep -q -- '--no-reload enable' '$P/scripts/rf35h-ntp' && ! grep -qE '^[[:space:]]*systemctl (enable|disable) ' '$P/scripts/rf35h-ntp'"

# Revisione per la v1.1.0, parte console (script, tool C, unit): volume sulla
# scheda rk817 per id ALSA, LED degli stick non salvati "off" a ogni
# spegnimento (e rf35h-ledd visto davvero), config.ini di IKEMEN a disco pieno,
# bootlog che non ferma RetroArch, sospensione rimandata durante update,
# scraping e transfer, crash log con l'orologio tornato indietro, rf35h-i2c
# sulla PMIC, scraper (db_name come cartella, scraper.conf 0600).
dev_audio_card() {   # mai la scheda 0 per numero: con una cuffia USB all'avvio e' lei
	grep -q 'CARD="${RF35H_CARD_ID:-rk817ext}"' "$P/scripts/rf35h-dac-volume" \
		&& grep -q 'RF35H_CARD:-/proc/asound/rk817ext' "$P/scripts/rf35h-audio-wait" \
		&& grep -q 'hw:CARD=${CARD},DEV=0' "$P/scripts/rf35h-audiotest" \
		&& ! grep -rqE 'amixer[^|;]* -c 0|amixer -q cset|hw:0|asound/card0' "$P/scripts" "$P/system.d" \
		&& grep -qx 'ExecStart=/usr/bin/rf35h-dac-volume --restore' "$P/system.d/rf35h-dacvol.service"
}
dev_led_shutdown() {   # "rf35h-led off" salvava "off" come scelta dell'utente
	grep -qx 'ExecStop=-/usr/bin/rf35h-led --sleep' "$P/system.d/rf35h-state.service" \
		&& ! grep -q '^ExecStop=.*rf35h-led off' "$P/system.d/rf35h-state.service"
}
dev_ledd_flag() {   # il link invocation: e' un symlink senza bersaglio: -L, non -e
	grep -q '\[ -L "${_f}" \]' "$P/scripts/rf35h-led" && grep -q '\[ -L "${f}" \]' "$P/scripts/rf35h-statusled"
}
dev_ikemen_full() {   # niente "awk > tmp && mv": la busybox awk non segnala gli errori di scrittura
	local f="${O}/packages/ikemen-go/scripts/rf35h-ikemen"
	grep -q '^write_atomic()' "$f" && [ "$(grep -c 'write_atomic "' "$f")" -ge 2 ] \
		&& ! grep -qF '> "${tmp}"' "$f" && ! grep -qF '> "${f}.rf35h.$$"' "$f"
}
dev_bootlog() {   # multi-user.target, e quindi RetroArch, non aspetta la diagnosi
	local u="$P/system.d/rf35h-bootlog.service"
	grep -qx 'DefaultDependencies=no' "$u" && grep -qx 'Conflicts=shutdown.target' "$u" \
		&& grep -qx 'Before=shutdown.target' "$u" && grep -qE '^After=.*basic.target' "$u" \
		&& grep -qx 'Type=oneshot' "$u" && grep -qE '^TimeoutStartSec=[0-9]+$' "$u"
}
dev_idle_busy() {
	local c="$P/sources/rf35h-idle.c"
	grep -q 'lstat(path, &st)' "$c" && grep -q '"rf35h-update.service", "rf35h-scrape.service"' "$c" \
		&& grep -q 'usb_gadget/rf35h/UDC' "$c" && grep -q 'const char \*why = busy();' "$c"
}
dev_crash_clock() { grep -q '\[ "${age}" -ge 0 \] && \[ "${age}" -lt 60 \]' "$P/scripts/rf35h-crashlog"; }
dev_i2c_pmic() {   # ogni scrittura all'rk817 (codec e PMIC) solo con RF35H_I2C_FORCE=1
	local c="$P/sources/rf35h-i2c.c"
	grep -q 'if (val >= 0 && bus == 0 && addr == 0x20) {' "$c" && grep -q 'strcmp(force, "1") != 0' "$c" \
		&& ! grep -q 'reg >= 0x10 && reg <= 0x4f && !getenv' "$c"
}
dev_scrape() {
	local c="$P/sources/rf35h-scrape.cpp"
	grep -q 'if (!safeDirName(tdir))' "$c" && grep -q 'O_WRONLY | O_CREAT | O_EXCL, 0600' "$c" \
		&& grep -qE '^[[:space:]]+tightenConf\(\);' "$c" && ! grep -q 'fopen(CONF, "w")' "$c"
}
chk "audio: scheda rk817 per id, ripristino fallito visibile" "dev_audio_card"
chk "LED: allo spegnimento --sleep, il modo salvato resta"    "dev_led_shutdown"
chk "LED: rf35h-ledd attivo visto (symlink invocation, -L)"   "dev_ledd_flag"
chk "IKEMEN: config.ini e .lrtl intatti a disco pieno"        "dev_ikemen_full"
chk "bootlog: RetroArch non lo aspetta, durata limitata"      "dev_bootlog"
chk "idle: sospensione rimandata (update, scrape, transfer)"  "dev_idle_busy"
chk "crashlog: sentinel nel futuro = scaduto"                 "dev_crash_clock"
chk "rf35h-i2c: ogni scrittura all'rk817 rifiutata"           "dev_i2c_pmic"
chk "scraper: db_name come cartella, scraper.conf 0600"       "dev_scrape"

echo "== aggiornamento di sistema e release"
U="${P}/scripts/rf35h-update"
chk "rf35h-update: script e due unit"          "[ -x '$U' ] && [ -f '$P/system.d/rf35h-update.service' ] && [ -f '$P/system.d/rf35h-update-boot.service' ]"
chk "rf35h-update.service la avvia il menu"    "! grep -q 'enable_service rf35h-update.service' '$P/package.mk' && grep -q 'enable_service rf35h-update-boot.service' '$P/package.mk'"
chk "repository delle release nell'immagine"   "grep -q 'usr/share/rf35h/update-repo' '$P/package.mk' && grep -q '^PKG_STAMP=\"update-repo=' '$P/package.mk'"
chk "aggiornamento: dimensione e sha256 prima del pronto" "grep -q 'checksum mismatch' '$U' && grep -q 'wrong size' '$U' && [ \$(grep -n 'checksum mismatch' '$U' | cut -d: -f1) -lt \$(grep -n 'mv -f \"\${part}\" \"\${target}\"' '$U' | cut -d: -f1) ]"
chk "aggiornamento: update.txt validato campo per campo" "grep -q '^read_info()' '$U' && grep -q 'https://\\*) ;;' '$U'"
chk "aggiornamento: re3 conservato in /storage"  "grep -q '^preserve_re3()' '$U' && grep -q 're3-preserved' '$U'"
chk "menu: System Update, ultima voce"          "grep -q 'action_ok_rf35h_update' '$M1003' && grep -q 'action_bind_sublabel_rf35h_update' '$M1003' && grep -A1 'MENU_ENUM_LABEL_RF35H_UPDATE, *PARSE_ACTION' '$M1003' | tail -1 | grep -q '};'"
chk "menu: Update Lakka nascosto sull'RF35H"    "grep -q '!rf35h_present() && menu_entries_append' '$M1003'"
chk "lakka-update da ssh passa a rf35h-update"  "grep -q 'exec /usr/bin/rf35h-update run' '${W}/packages/lakka/lakka_tools/lakka_update/sources/lakka-update.sh'"
chk "strace con i suoi header (kernel 7.2)"      "grep -q 'PKG_CONFIGURE_OPTS_TARGET+=\" --enable-bundled=yes\"' '${W}/packages/debug/strace/package.mk'"
chk "glibc: nessun -O in PROJECT_CFLAGS"          "! grep -qE '^[^#]*PROJECT_CFLAGS=\"[^\"]*-O' '${W}/projects/Rockchip/devices/RK3326/options'"
chk "versione della release in os-release"      "grep -q 'CUSTOM_VERSION=\"\${RF35H_VERSION}\"' '$O/build-lakka-rf35h.sh'"
chk "CI: re3 cercato nel SYSTEM prima della release" "grep -q 're3 nel SYSTEM' '$O/tools/ci-build.sh'"
# Scrive solo il job release (build.yml) e il job kernel di upstream.yml (che
# spinge soltanto un ramo ci-test/kernel-*): le parti della build e i
# controlli no.
chk "CI: contents: write solo in release, kernel e cores/publish" "[ \$(cat '$O'/.github/workflows/*.yml | grep -c 'contents: write') = 3 ] && [ \$(grep -c 'contents: write' '$O/.github/workflows/build.yml') = 1 ] && [ \$(grep -c 'contents: write' '$O/.github/workflows/upstream.yml') = 1 ] && [ \$(grep -c 'contents: write' '$O/.github/workflows/cores.yml') = 1 ]"
# I core: pins.txt copre CORES_DEFAULT (ogni core dell'immagine ha il suo
# commit), apply.sh li scrive e li porta nell'immagine, il sysroot si salva.
chk "core: ogni core di CORES_DEFAULT ha un pin"  "( for c in \$(sed -n 's/^CORES_DEFAULT=\"\(.*\)\"$/\1/p' '$O/build-lakka-rf35h.sh'); do grep -qE \"^\${c} +https?://[^ ]+ +[0-9a-f]{40} \" '$O/cores/pins.txt' || exit 1; done )"
chk "core: pin applicati nell'albero"            "( for c in \$(sed -n 's/^CORES_DEFAULT=\"\(.*\)\"$/\1/p' '$O/build-lakka-rf35h.sh'); do sha=\$(awk -v c=\"\${c}\" '\$1 == c { print \$3 }' '$O/cores/pins.txt'); grep -q \"^PKG_VERSION=\\\"\${sha}\\\"\" \"${W}/packages/lakka/libretro_cores/\${c}/package.mk\" || exit 1; done )"
chk "core: elenco nell'immagine (cores.txt)"     "grep -q '^lakka=[0-9a-f]\{40\}$' '${RKP%/patches/linux}/packages/rf35h-utils/cores.txt' && [ \$(grep -c ' https' '${RKP%/patches/linux}/packages/rf35h-utils/cores.txt') -ge 34 ] && grep -q 'cores.txt' '$P/package.mk'"
chk "core: sysroot salvato a fine build"         "grep -q 'pack-sysroot' '$O/.github/workflows/build-stage.yml' && grep -q 'sysroot-' '$O/.github/workflows/cores.yml'"
chk "loader del repository: sha256 verificato"  "( cd '$O/board/loader' && sha256sum -c --quiet known-good.sha256 )"
# AUTOREMOVE=yes (la CI) cancella la cartella di build di un pacchetto appena
# nessun job del piano la dichiara in PKG_DEPENDS_UNPACK: ogni get_build_dir
# <nome> dei nostri pacchetti deve avere <nome> li'. ikemen-go leggeva
# libretro.h dalla build di RetroArch senza dichiararla.
unpack_ok() {
	local f n
	for f in "$O"/packages/*/package.mk; do
		for n in $(grep -o 'get_build_dir [A-Za-z0-9_.+-]*' "$f" | awk '{print $2}' | sort -u); do
			grep -qE "^PKG_DEPENDS_UNPACK\+?=\"(.* )?${n}( .*)?\"" "$f" || return 1
		done
	done
}
chk "AUTOREMOVE: ogni get_build_dir dichiarato" "unpack_ok"

echo "== kernel"
chk "GPU 600 MHz a 1,15 V"                   "grep -A2 opp-600000000 '$Z010' | grep -q 1150000"
chk "GPU: un solo blocco OPP"                "[ \$(grep -c '&gpu_opp_table' '$Z010') = 1 ]"
chk "DSI: celle dichiarate"                  "grep -q '#address-cells = <1>' '$Z010'"
chk "z-010 crea tre file"                    "[ \$(grep -c '^+++ ' '$Z010') = 3 ]"
# Il pannello a 58,5 Hz (primo modo di AURKNIX) rallentava del 2,5% tutto cio'
# che va col vsync: predefinito il 60,000 Hz, un solo modo con default=1.
chk "pannello: predefinito il 60,000 Hz"      "grep -q '^+.*\"M clock=31080 horizontal=640,150,60,150 vertical=480,20,6,12 default=1\",' '$Z010' && [ \$(grep -c '^+.*\"M .*default=1' '$Z010') = 1 ]"

# Debug del kernel acceso in produzione: REGULATOR_DEBUG era l'ultimo dei 40
# simboli che aggiungono -DDEBUG a una directory. E niente fotocamera nel DTS.
chk "kconfig: REGULATOR_DEBUG spenta"                "grep -qx '# CONFIG_REGULATOR_DEBUG is not set' '$K'"
chk "DTS: nessun nodo della fotocamera attivato"     "! grep -qE '^\+&(isp|csi_dphy) \{' '$Z010'"
echo "== build script e opzionali"
chk "--keep-going e --skip-core"             "grep -q -- '--keep-going)' '$O/build-lakka-rf35h.sh' && grep -q -- '--skip-core)' '$O/build-lakka-rf35h.sh'"
chk "keep-going: log del thread"             "grep -q 'threads/logs' '$O/build-lakka-rf35h.sh'"
chk "keep-going: niente ripetizioni a vuoto"  "grep -q 'gia.* escluso ma fallisce ancora' '$O/build-lakka-rf35h.sh'"
chk "KMS resta opzionale"                    "[ -f '$O/optional/kms-no-compositor.patch' ] && ! grep -q kms-no-compositor '$O/apply.sh'"
# Tre difetti visti alla prima build nel container: verify-kernel prendeva
# build.*/install_pkg/linux-7.2.7 (20 falsi MANCA), la verifica dell'immagine
# cercava lo script in ${RK}/tools (mai eseguita) e nel container mancava
# unsquashfs; la firma dell'overlay cambiava fra host e container.
chk "verify-kernel: sorgente solo da build/"  "grep -qF '/build.*/build/linux-[0-9]' '$O/verify-kernel.sh'"
chk "fine build: verify-image dall'overlay"   "grep -qF 'OVERLAY}/tools/verify-image.sh' '$O/build-lakka-rf35h.sh' && ! grep -qF 'RK}/tools/' '$O/build-lakka-rf35h.sh'"
chk "container con unsquashfs"                "grep -qE '^ +default-jre-headless .*squashfs-tools' '$O/build-in-docker.sh'"
chk "firma dell'overlay senza percorsi"       "grep -q 'overlay-sig2' '$O/build-lakka-rf35h.sh' && grep -qF 'cd \"\${OVERLAY}\" && find' '$O/build-lakka-rf35h.sh'"
chk "--verify-only e --sh in ogni posizione"  "grep -q -- '--verify-only) VERIFY_ONLY=' '$O/build-lakka-rf35h.sh' && grep -q 'SHMODE=yes' '$O/build-in-docker.sh'"
# con --workdir relativo il log finiva in ${WORKDIR}/${WORKDIR}/ dopo il cd
chk "--workdir reso assoluto (log della build)" "grep -qF 'pwd)/\$(basename \"\${WORKDIR}\")' '$O/build-lakka-rf35h.sh'"
# I core (6/10/2026): il default sono tutti quelli che compilano, il set di
# base resta per le build di prova. Con CUSTOM_LIBRETRO_CORES a spazio singolo
# Lakka incollava i vicini di un core escluso ("a b c" senza b: "ac").
BLD="$O/build-lakka-rf35h.sh"
NDEF="$(sed -n 's/^CORES_DEFAULT="\(.*\)"$/\1/p' "$BLD" | wc -w)"
NBASE="$(sed -n 's/^CORES_BASE="\(.*\)"$/\1/p' "$BLD" | wc -w)"
chk "core: CUSTOM_LIBRETRO_CORES coi nomi staccati" "grep -qF 'padded=\"\${padded} \${c} \"' '$BLD' && grep -qF 'CUSTOM_LIBRETRO_CORES=\"\${padded}\"' '$BLD'"
chk "core: --base-cores"                      "grep -qF -- '--base-cores) CORES=\"\${CORES_BASE}\"' '$BLD'"
chk "core: nel default nessuno che non compila" "! sed -n 's/^CORES_DEFAULT=\"\(.*\)\"\$/ \1 /p' '$BLD' | grep -qE ' (panda3ds|azahar|ecwolf|kronos|lr_moonlight|vitaquake3|np2kai|beetle_bsnes|beetle_saturn|blastem|bsnes_mercury|holani|lrps2) '"
chk "core: il set di base sta nel default"   "( for c in \$(sed -n 's/^CORES_BASE=\"\(.*\)\"\$/\1/p' '$BLD'); do sed -n 's/^CORES_DEFAULT=\"\(.*\)\"\$/ \1 /p' '$BLD' | grep -qF \" \${c} \" || exit 1; done )"
chk "core: ${NDEF} e ${NBASE} in help, README, guida e commenti" "[ '$NDEF' -gt '$NBASE' ] && grep -qF 'default: i $NDEF che compilano' '$BLD' && grep -qF 'invece dei $NDEF di' '$BLD' && grep -qF 'qui compilano, $NDEF.' '$BLD' && grep -qF 'set di base: $NBASE core' '$BLD' && grep -qF 'with $NDEF libretro cores' '$O/README.md' && grep -qF 'more for all $NDEF cores' '$O/README.md' && grep -qF 'has $NDEF libretro cores' '$O/docs/guide.md' && grep -qF 'base set of $NBASE cores' '$O/docs/guide.md' && grep -qF 'default set of $NDEF cores' '$O/docs/guide.md' && grep -qF 'kernel, $NDEF core)' '$O/tools/ci-build.sh' && grep -qF '# $NDEF core da zero' '$O/.github/workflows/build.yml'"

echo "== documentazione allineata ai file"
# Il riassunto in cima al README e' la prima cosa che si legge, ed e' stato
# trovato fermo a numeri di giorni prima (7 patch kernel invece di 5, 18 di
# integrazione invece di 27). Qui si confronta con i file veri.
R="${O}/docs/diario.md"
readme_n() { sed -n '/^## Cosa contiene/,/^## /p' "$R" | grep -oE "[0-9]+ $1" | head -1 | grep -oE '^[0-9]+'; }
chk "README: patch kernel"      "[ \"\$(readme_n 'patch kernel')\" = \"\$(ls '$O/patches/linux' | wc -l)\" ]"
chk "README: patch integrazione" "[ \"\$(readme_n \"patch all'albero\")\" = \"\$(ls '$O/integration' | wc -l)\" ]"
chk "README: patch RetroArch"   "[ \"\$(readme_n 'patch a RetroArch')\" = \"\$(ls '$O/patches/retroarch' | wc -l)\" ]"
chk "README: script rf35h-utils" "[ \"\$(readme_n 'script e')\" = \"\$(ls '$P/scripts' | wc -l)\" ]"

echo "== CI: build e release"
# Quattro difetti della pipeline (prove in tools/test-ci-build.sh): il
# controllo di re3 non scattava mai (unsquashfs -l | grep -q, con pipefail);
# una build che aveva perso core per --keep-going diventava la release che
# tutte le console scaricano; un link ucciso alla scadenza di una parte poteva
# arrivare nell'immagine come un .so di 0 byte; "latest" lo decideva GitHub,
# anche per una versione piu' bassa.
CIB="$O/tools/ci-build.sh"; BYML="$O/.github/workflows/build.yml"
chk "re3: elenco del SYSTEM in un file, mai in pipe" "grep -q '^check_system()' '$CIB' && ! grep -vE '^[[:space:]]*#' '$CIB' | grep -qE 'unsquashfs -l[^|]*[|]([^|]|\$)'"
chk "core di 0 byte o non ELF: l'immagine si ferma" "grep -q '^elf_ok()' '$CIB' && grep -q 'core rotti nel SYSTEM' '$CIB'"
chk "stato: i pacchetti interrotti si rifanno"     "sed -n '/^cmd_pack() {/,/^}/p' '$CIB' | grep -q drop_interrupted"
chk "release: re3 e core anche sui file scaricati" "grep -qF 'ci-build.sh check-dist dist' '$BYML'"
chk "release: core o giochi persi la fermano"      "grep -q '^completeness()' '$CIB' && grep -qF 'inputs.allow_incomplete' '$BYML'"
chk "release: col trattino sempre pre-release"     "grep -qF 'in *-*) prerelease=true' '$CIB'"
chk "release: tag solo dal ramo principale"        "grep -qF 'merge-base --is-ancestor' '$CIB' && grep -qF 'run: ./tools/ci-build.sh version' '$BYML'"
chk "release: latest solo alla versione piu' alta" "grep -qF 'sort -V' '$CIB' && grep -qF -- '--latest=\"\${latest}\"' '$CIB' && grep -qF 'run: ./tools/ci-build.sh publish dist' '$BYML'"
chk "release: una per versione alla volta"         "grep -qF 'inputs.version || github.ref }}' '$BYML'"
# Con tutti i core la build da zero sta in piu' di quattro parti, e il .tar
# cresce: GitHub rifiuta nella release i file da 2 GiB in su.
chk "CI: otto parti, l'ultima e' la 8"            "[ \"\$(grep -c 'last: true' '$BYML')\" = 1 ] && sed -n '/^  stage8:/,/^\$/p' '$BYML' | grep -q 'last: true' && grep -qF 'needs: [setup, stage1, stage2, stage3, stage4, stage5, stage6, stage7, stage8]' '$BYML' && grep -qF \"needs.stage8.outputs.result == 'done'\" '$BYML'"
chk "release: ogni file sotto i 2 GiB"             "grep -q '^too_big()' '$CIB' && sed -n '/^cmd_check_dist() {/,/^}/p' '$CIB' | grep -q 'file oltre i 2 GiB'"

echo "== aggiornamento e strumenti per la card: le correzioni dopo la v1.0.0"
# rf35h-update: (1) la batteria si guardava solo scaricando, e il .tar
# verificato, gia' in /storage/.update, lo installava qualunque avvio; (2)
# un'installazione fallita tornava in silenzio a "installed: <la vecchia>"; (3)
# si installava qualunque ultima release diversa, anche piu' vecchia.
# Strumenti per il PC: (4) rf35h-reflash-system lasciava in extlinux.conf
# l'UUID di /storage dell'immagine, e con un'altra build /storage non si
# trovava; (5) nessun controllo sul disco; (6) nessun modo di rimettere solo il
# loader; (7) rf35h-rescue cancellava l'autostart.sh dell'utente.
CT="$O/tools"
# in cmd_install la batteria viene prima dello spostamento in .update
upd_install_ok() {
	local body
	body="$(sed -n '/^cmd_install() {/,/^}/p' "$U")"
	[ -n "${body}" ] || return 1
	printf '%s\n' "${body}" | awk '/battery_check/ && !b { b = NR } index($0, "mv -f \"${f}\" \"${final}\"") { m = NR } END { exit !(b && m && b < m) }'
}
chk "rf35h-update: il .tar verificato aspetta fuori dalla vista dell'init" "grep -q '^STAGE=\"\${UPDATE_DIR}/.rf35h-staged\"' '$U' && grep -q 'target=\"\${STAGE}/\${U_TAR}\"' '$U'"
chk "rf35h-update install: batteria, poi il .tar in .update" "upd_install_ok && grep -q 'install) cmd_install' '$U'"
chk "rf35h-update boot: un'installazione fallita nel menu" "grep -q 'status \"error: install of \${m_ver} failed' '$U'"
chk "rf35h-update: dall'ultima release solo in avanti" "grep -q '^version_newer()' '$U' && grep -q 'if ! explicit_source; then' '$U'"
chk "reflash: extlinux.conf con l'UUID di /storage della card" "grep -qF 's/disk=UUID=\${IMG_UUID}/disk=UUID=\${CARD_UUID}/g' '$CT/rf35h-reflash-system.sh'"
chk "reflash e rescue: controlli sul disco, card Lakka" "grep -q 'card_check \"\${DEV}\"' '$CT/rf35h-reflash-system.sh' && grep -q 'card_check \"\$DEV\"' '$CT/rf35h-rescue.sh' && grep -q 'LAKKA_DISK' '$CT/rf35h-card.sh'"
chk "reflash --loader: il known-good verificato, a 32 KiB" "grep -q -- '--loader' '$CT/rf35h-reflash-system.sh' && grep -q 'sha256sum -c --quiet known-good.sha256' '$CT/rf35h-reflash-system.sh' && grep -q 'bs=32768 seek=1' '$CT/rf35h-reflash-system.sh'"
chk "rescue: l'autostart.sh dell'utente torna al suo posto" "grep -q 'cp -p \"\$AS\" \"\$ASB\"' '$CT/rf35h-rescue.sh' && grep -q 'mv -f /storage/.config/autostart.sh.rf35h-rescue /storage/.config/autostart.sh' '$CT/rf35h-rescue.sh'"

echo "== menu: le unit attive si vedono"
# /run/systemd/units/invocation:<unit> e' un link simbolico al suo invocation
# ID, che come percorso non esiste: path_is_valid() (stat) lo dava sempre
# assente. Lo scraper e System Update non si fermavano dalla loro voce, e
# l'ora di rete risultava spenta.
M1003C="${O}/patches/retroarch/retroarch-1003-rf35h-settings-menu.patch"
chk "menu: nessun path_is_valid sui link invocation:" "! grep -q 'path_is_valid(\"/run/systemd/units/invocation:' '$M1003C' && ! grep -q 'path_is_valid(\\\\\"/run/systemd/units/invocation:' '${O}/tools/gen-retroarch-rf35h-menu.py'"
chk "menu: rf35h_unit_active con lstat, tre file" "[ \"\$(grep -c '^+static bool rf35h_unit_active(const char \*unit)' '$M1003C')\" = 3 ] && grep -q '^+   return lstat(p, &st) == 0;' '$M1003C'"

echo "== Samba: niente condivisioni che danno root"
# L'ospite senza password e' root: Configfiles (autostart.sh), Services (SSH,
# password dell'AP) e Update (installato al riavvio) erano codice come root per
# chiunque nella stessa Wi-Fi; un core o una playlist cambiati pure.
SMB="${W}/distributions/Lakka/config/smb.conf"
chk "Samba: via Configfiles, Services e Update" "[ -f '$SMB' ] && ! grep -qE '^\[(Configfiles|Services|Update)\]' '$SMB'"
chk "Samba: Cores e Playlists in sola lettura"  "(for sh in Cores Playlists; do sed -n \"/^\\[\$sh\\]/,/^\$/p\" '$SMB' | grep -q '^  writeable = no\$' || exit 1; done)"

echo
if [ "$bad" -eq 0 ]; then
	echo "tutte le $n verifiche passano"
else
	echo "$bad verifiche su $n FALLITE"; exit 1
fi
