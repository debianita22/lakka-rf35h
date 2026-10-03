# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="rust-std-aarch64"
# La libreria standard di Rust gia' compilata per aarch64-unknown-linux-gnu,
# la stessa versione dei pacchetti *-snapshot di Lakka. Serve a rust-bin per
# compilare per la console da un host x86_64 (su un host aarch64 coincide con
# rust-std-snapshot, e installarla due volte non cambia niente).
#
# sha256 dal manifest ufficiale del canale 1.95.0 (static.rust-lang.org,
# dist/2026-04-16, quello che rustup verifica): e' anche il valore che Lakka
# usa per rust-std-snapshot quando l'host e' aarch64.
PKG_VERSION="1.95.0"
PKG_SHA256="3a21b271b1ff973b94d69b25e7a39992f9fbcae1ab6d9475844a23e6ad3908ac"
PKG_LICENSE="MIT"
PKG_SITE="https://www.rust-lang.org"
PKG_URL="https://static.rust-lang.org/dist/rust-std-${PKG_VERSION}-aarch64-unknown-linux-gnu.tar.xz"
PKG_SOURCE_NAME="rust-std-aarch64_${PKG_VERSION}.tar.xz"
PKG_LONGDESC="Libreria standard di Rust ${PKG_VERSION} per aarch64-unknown-linux-gnu (binario ufficiale), per rust-bin."
PKG_TOOLCHAIN="manual"
