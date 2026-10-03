# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="rust-bin"
PKG_VERSION="1.95.0"
PKG_LICENSE="MIT"
PKG_SITE="https://www.rust-lang.org"
# Il compilatore Rust ufficiale gia' compilato, solo per l'host, con la
# libreria standard per aarch64. Serve a openxeenng.
#
# Perche' non cargo:host di Lakka: quello compila rustc 1.95.0 dai sorgenti
# (stage 2, su llvm:host) per avere la libreria standard della triple di
# LibreELEC, aarch64-libreelec-linux-gnu. Nessun core del set di default e'
# in Rust, quindi oggi non si costruisce: aggiungerlo per un core solo vorrebbe
# dire un'ora o piu' di compilazione e una decina di GB in piu' nella cartella
# di build. Qui invece si installano i binari ufficiali che Lakka scarica gia'
# come bootstrap (rustc-, cargo-, rust-std-snapshot: stessa versione, sha256
# gia' nei loro package.mk) piu' la libreria standard per aarch64
# (rust-std-aarch64). Il core si compila per la triple ufficiale
# aarch64-unknown-linux-gnu e si linka con il gcc del toolchain di LibreELEC:
# stessa glibc, stessa ABI.
PKG_URL=""
PKG_DEPENDS_HOST="toolchain"
PKG_DEPENDS_UNPACK="rustc-snapshot cargo-snapshot rust-std-snapshot rust-std-aarch64"
PKG_LONGDESC="Rust ${PKG_VERSION} ufficiale (binari per l'host) con la libreria standard per aarch64, per compilare openxeenng."
PKG_TOOLCHAIN="manual"

makeinstall_host() {
  # i *-snapshot seguono la versione di rust di Lakka; la libreria per aarch64
  # e' fissata qui con il suo sha256: devono coincidere
  [ "$(get_pkg_version rust)" = "${PKG_VERSION}" ] \
    || die "rust-bin: Lakka ora ha rust $(get_pkg_version rust), qui ${PKG_VERSION}: aggiornare versione e sha256 di rust-bin e rust-std-aarch64"
  local d="${TOOLCHAIN}/lib/rust-bin" p
  rm -rf "${d}"
  for p in rustc-snapshot cargo-snapshot rust-std-snapshot rust-std-aarch64; do
    "$(get_build_dir ${p})/install.sh" --prefix="${d}" --disable-ldconfig
  done
  "${d}/bin/rustc" --version
  "${d}/bin/cargo" --version
  [ -d "${d}/lib/rustlib/aarch64-unknown-linux-gnu/lib" ] \
    || die "rust-bin: manca la libreria standard per aarch64-unknown-linux-gnu"
}
