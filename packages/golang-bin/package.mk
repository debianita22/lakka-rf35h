# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="golang-bin"
PKG_VERSION="1.26.2"
PKG_LICENSE="BSD"
PKG_SITE="https://go.dev"
# Il compilatore Go ufficiale gia' compilato, solo per l'host. Serve a
# ikemen-go.
#
# Perche' non go:host di LibreELEC: quello compila Go 1.26.2 dai sorgenti, e
# per farlo vuole un Go >= 1.24.6 gia' installato sull'host (make.bash:
# "Go 1.26 and later requires Go 1.24.6 as the minimum bootstrap toolchain").
# Le immagini Docker di Lakka ne hanno uno piu' vecchio: jammy e noble 1.23,
# bookworm 1.21, trixie 1.24 (1.24.4). La build si fermerebbe li', e nessun
# package del device lo usava finora, quindi non ce ne si era accorti.
# Stessa versione di go:host (1.26.2): il GOEXPERIMENT=arenas che IKEMEN
# richiede c'e' ancora (src/arena).
#
# Checksum ufficiali, gli stessi che verificano le immagini Docker "golang"
# (docker-library/golang, versions.json, commit f5af4bcd del 7/4/2026).
case "$(uname -m)" in
  aarch64|arm64)
    PKG_GO_HOSTARCH="arm64"
    PKG_SHA256="c958a1fe1b361391db163a485e21f5f228142d6f8b584f6bef89b26f66dc5b23"
    ;;
  *)
    PKG_GO_HOSTARCH="amd64"
    PKG_SHA256="990e6b4bbba816dc3ee129eaeaf4b42f17c2800b88a2166c265ac1a200262282"
    ;;
esac
PKG_URL="https://dl.google.com/go/go${PKG_VERSION}.linux-${PKG_GO_HOSTARCH}.tar.gz"
PKG_SOURCE_DIR="go"
PKG_DEPENDS_HOST="toolchain"
PKG_LONGDESC="Go ${PKG_VERSION} ufficiale (binario per l'host) per compilare IKEMEN GO senza bootstrap."
PKG_TOOLCHAIN="manual"

makeinstall_host() {
  rm -rf ${TOOLCHAIN}/lib/golang-bin
  mkdir -p ${TOOLCHAIN}/lib/golang-bin
  cp -a ${PKG_BUILD}/. ${TOOLCHAIN}/lib/golang-bin/
  rm -f ${TOOLCHAIN}/lib/golang-bin/.libreelec-*
}
