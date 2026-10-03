# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2009-2016 Stephan Raue (stephan@openelec.tv)
# Copyright (C) 2019-present Team LibreELEC (https://libreelec.tv)
#
# devaOS RF35H: Lakka e' iwd-only dalla v6 - questo package esisteva fino alla
# v5.x ed e' stato tolto. Lo si riporta qui, nella cartella del device, perche'
# su questo hardware il Wi-Fi funziona con wpa_supplicant (e' quello che usa
# devaOS) e con iwd la UI non vede reti. Il ramo di connman per
# WIRELESS_DAEMON=wpa_supplicant esiste ancora ed e' quello che lo tira dentro.
#
# Rispetto alla v5.x: 2.8 -> 2.11 (supporto a OpenSSL 3, compilato con questo
# config contro OpenSSL 3.0 senza errori), CONFIG_PEERKEY rimossa perche' non
# esiste piu', CONFIG_LIBNL32 per il blocco libnl3 attuale, e i due .service
# che dalla 2.11 sono template da generare.
#
# E soprattutto CONFIG_SAE + CONFIG_IEEE80211W: connman 2.0 manda a ogni rete
# PSK la stringa "SAE WPA-PSK WPA-PSK-SHA256" (gsupplicant/supplicant.c, case
# G_SUPPLICANT_SECURITY_PSK). Senza SAE compilato, wpa_supplicant rifiuta
# l'intera configurazione - "invalid key_mgmt 'SAE'" nel journal - e connman
# lo riporta come "invalid-key": la rete si vede ma il connect fallisce sempre.
# Il config di Lakka v5 era pre-WPA3 e non poteva funzionare con connman 2.0.

PKG_NAME="wpa_supplicant"
PKG_VERSION="2.11"
PKG_SHA256="9f1109e2aef8e591004bec8e9d8dd363be61c2edaf99f4cc14e35b74316d5a45"
PKG_LICENSE="GPL"
PKG_SITE="https://w1.fi/wpa_supplicant/"
# Il repack di Ubuntu: e' l'unico di cui lo sha256 sia verificabile da dove
# e' stato preparato questo package. Dentro c'e' la release hostap 2.11, nella
# cartella wpa-2.11 - da cui PKG_SOURCE_DIR.
PKG_URL="http://archive.ubuntu.com/ubuntu/pool/main/w/wpa/wpa_${PKG_VERSION}.orig.tar.xz"
PKG_SOURCE_DIR="wpa-${PKG_VERSION}"
PKG_DEPENDS_TARGET="toolchain dbus libnl openssl"
PKG_LONGDESC="A free software implementation of an IEEE 802.11i supplicant."
PKG_TOOLCHAIN="make"
PKG_BUILD_FLAGS="+lto-parallel"

PKG_MAKE_OPTS_TARGET="-C wpa_supplicant V=1 LIBDIR=/usr/lib BINDIR=/usr/bin"
PKG_MAKEINSTALL_OPTS_TARGET="-C wpa_supplicant V=1 LIBDIR=/usr/lib BINDIR=/usr/bin"

configure_target() {
  LDFLAGS="$LDFLAGS -lpthread -lm"

  cp $PKG_DIR/config/makefile.config wpa_supplicant/.config
}

post_makeinstall_target() {
  # wpa_cli resta: rf35h-ap lo usa per vedere se l'interfaccia e' in modo AP
  # (connman con wpa_supplicant non riporta il tethering in modo affidabile).
  # Il demone parte con -u (dbus, per connman): per il socket di controllo di
  # wpa_cli si aggiunge -O /var/run/wpa_supplicant alla unit.

  # Dalla 2.11 i .service sono template .in: make li genera sostituendo
  # @BINDIR@, ma solo se glieli si chiede.
  make -C wpa_supplicant BINDIR=/usr/bin \
    systemd/wpa_supplicant.service dbus/fi.w1.wpa_supplicant1.service

  mkdir -p $INSTALL/etc/dbus-1/system.d
    cp wpa_supplicant/dbus/dbus-wpa_supplicant.conf $INSTALL/etc/dbus-1/system.d

  mkdir -p $INSTALL/usr/lib/systemd/system
    cp wpa_supplicant/systemd/wpa_supplicant.service $INSTALL/usr/lib/systemd/system
    # socket di controllo per wpa_cli (rf35h-ap), accanto al dbus per connman
    sed -i 's|^ExecStart=\(.*\)wpa_supplicant -u|ExecStart=\1wpa_supplicant -u -O /var/run/wpa_supplicant|' \
      $INSTALL/usr/lib/systemd/system/wpa_supplicant.service
    grep -q "wpa_supplicant -u -O /var/run/wpa_supplicant" $INSTALL/usr/lib/systemd/system/wpa_supplicant.service \
      || { echo "wpa_supplicant.service: la ExecStart non e' quella attesa, -O non aggiunto"; exit 1; }

  mkdir -p $INSTALL/usr/share/dbus-1/system-services
    cp wpa_supplicant/dbus/fi.w1.wpa_supplicant1.service $INSTALL/usr/share/dbus-1/system-services
    sed -i 's|^Exec=\(.*\)wpa_supplicant -u|Exec=\1wpa_supplicant -u -O /var/run/wpa_supplicant|' \
      $INSTALL/usr/share/dbus-1/system-services/fi.w1.wpa_supplicant1.service
}
