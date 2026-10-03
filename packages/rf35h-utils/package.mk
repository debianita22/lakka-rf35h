# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="rf35h-utils"
PKG_ARCH="any"
PKG_LICENSE="OSS"
# Niente u-boot-tools:host. mkimage serve (boot.scr), ma lo prendiamo dalla
# distro: il package di LibreELEC e' rotto per RK3326 - unpack() cerca un
# .tar.bz2 fisso mentre il u-boot di questo device arriva da github come
# .tar.gz - e comunque vorrebbe dire compilare i tool di uno U-Boot del 2018
# col compilatore di oggi. projects/Rockchip/bootloader/mkimage lo risolve a
# runtime, toolchain prima e sistema poi.
PKG_DEPENDS_TARGET="toolchain curl eventservice odroidgo2-utils"
PKG_LONGDESC="Supporto per l'XiFan RF35H: audio, tasti volume, retroilluminazione, LED degli stick e diagnostica. Rimpiazza odroidgoa-volkeys e la parte audio di odroidgo2-utils, che assumono hardware Odroid Go Advance."
# Niente PKG_TOOLCHAIN=manual: con PKG_URL vuoto e una cartella sources/,
# scripts/unpack copia sources/ nel build dir e il toolchain "make" (default)
# compila rf35h-tty con il CC del target. E' lo schema di eventservice.
PKG_URL=""

makeinstall_target() {
  # il binario, dal Makefile in sources/
  make -C ${PKG_BUILD} install DESTDIR=${INSTALL}
  # adc-keys (i tasti volume) e' un modulo (CONFIG_KEYBOARD_ADC=m): senza
  # questo arriva al coldplug di udev, a +20 s, mentre il joypad lo carichiamo
  # in sysinit. spkeys-service ora aspetta entrambi, ma meglio averli insieme.
  mkdir -p ${INSTALL}/usr/lib/modules-load.d
    echo "adc-keys" > ${INSTALL}/usr/lib/modules-load.d/rf35h-adc-keys.conf

  # NIENTE modules-load per l'audio: da quando la kconfig compila
  # snd_soc_rockchip_i2s nel kernel (=y, come AURKNIX) il controller e' gia'
  # registrato all'avvio e non c'e' alcun modulo da anticipare. Il vecchio
  # rattoppo compensava un ordine di probe sbagliato invece di correggerlo.

  # drop-in su retroarch.service: OnFailure -> rf35h-crashlog. Con Restart=always
  # un crash all'avvio era un loop muto; ora ogni fallimento lascia un file in
  # /storage/rf35h-logs, che sopravvive al reboot (il journal no: /var e' tmpfs).
  mkdir -p ${INSTALL}/usr/lib/systemd/system/retroarch.service.d
    cp ${PKG_DIR}/retroarch.service.d/rf35h-crashlog.conf \
       ${INSTALL}/usr/lib/systemd/system/retroarch.service.d/

  # Vulkan (Mesa PanVK) come alternativa a "gl" per RetroArch: la variabile
  # che sblocca PanVK su Bifrost e il ripiego automatico su "gl" se Vulkan non
  # parte (scripts/rf35h-ra-guard). Innocuo in un'immagine senza Vulkan: la
  # variabile non fa niente e il driver resta "gl".
    cp ${PKG_DIR}/retroarch.service.d/rf35h-vulkan.conf \
       ${INSTALL}/usr/lib/systemd/system/retroarch.service.d/
  # la stessa variabile per le shell (vulkaninfo e vkcube da ssh)
  mkdir -p ${INSTALL}/etc/profile.d
    cp ${PKG_DIR}/profile.d/99-rf35h-vulkan.conf ${INSTALL}/etc/profile.d/

  # drop-in per systemd-timesyncd: toglie la ConditionPathExists che lo
  # disattivava a ogni avvio (vedi scripts/rf35h-ntp).
  mkdir -p ${INSTALL}/usr/lib/systemd/system/systemd-timesyncd.service.d
    cp ${PKG_DIR}/timesyncd.d/rf35h-timesyncd.conf \
       ${INSTALL}/usr/lib/systemd/system/systemd-timesyncd.service.d/

  # gli script
  mkdir -p ${INSTALL}/usr/bin
    cp -v ${PKG_DIR}/scripts/* ${INSTALL}/usr/bin
    chmod +x ${INSTALL}/usr/bin/rf35h-*

  # Override per-core di RetroArch: i default stanno nell'immagine e
  # rf35h-overrides.service li copia in /storage solo se mancano. cp -r
  # conserva le cartelle con gli spazi nel nome ("TGB Dual", "Beetle NeoPop").
  mkdir -p ${INSTALL}/usr/share/rf35h/retroarch-overrides
    cp -r "${PKG_DIR}/overrides/." ${INSTALL}/usr/share/rf35h/retroarch-overrides/
}

post_install() {
  # Il servizio di odroidgo2-utils non viene abilitato affatto su questa board:
  # la guardia sta nel suo post_install (integration/odroidgo2-utils-rf35h.patch),
  # non qui. Un "rm" da questa parte dipenderebbe dall'ordine di installazione,
  # che con il builder multithread non e' garantito.
  # Di quel package ci serve solo il binario headphone-sense, che riusiamo.
  # rf35h-audio (headphone-sense, ereditato da odroidgo2-utils) NON viene piu'
  # abilitato: AURKNIX, che ha audio funzionante su questo hardware con lo
  # stesso device tree, non ha alcun demone di commutazione. Il kernel fa tutto
  # da solo - simple-audio-card registra il jack da hp-det-gpio, il pin-switch
  # su "Internal Speakers" e le route DAPM commutano il percorso. Quel demone
  # forzava con amixer controlli che DAPM gestisce gia', e sul device lasciava
  # l'altoparlante muto dopo aver scollegato le cuffie. Il file resta
  # installato: per riattivarlo, "systemctl enable --now rf35h-audio".
  enable_service rf35h-volkeys.service
  enable_service rf35h-state.service
  enable_service rf35h-suspend.service
  enable_service rf35h-idle.service
  enable_service rf35h-bootlog.service
  enable_service rf35h-ledd.service
  enable_service rf35h-zram.service
  enable_service rf35h-overrides.service
  enable_service rf35h-ntp.service
  enable_service rf35h-dacvol.service
  enable_service rf35h-rk915-load.service
  enable_service rf35h-bootlog-late.timer
}
