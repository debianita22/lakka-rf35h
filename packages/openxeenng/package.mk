# SPDX-License-Identifier: GPL-3.0-or-later
# devaOS / Lakka RF35H port
#
# OpenXeenNG: motore aperto di Might and Magic IV/V (World of Xeen), riscritto in
# Rust, come core libretro. Si carica XEEN.CC o DARK.CC della propria copia
# (GOG, "Might and Magic 6-pack"); senza contenuto gira la demo. Nessun dato del
# gioco nell'immagine.
#
# Il sorgente arriva dal suo repository, al commit afe41a1 (milestone 0,
# rinominato OpenXeenNG): l'albero provato finora con i nomi nuovi.
#
# Rust: rust-bin:host, il compilatore ufficiale gia' compilato (perche' non
# cargo:host di Lakka: vedi rust-bin/package.mk). Il core dipende solo da
# openxeenng-engine e openxeenng-formats, nessun crate esterno; ma cargo risolve
# l'intero workspace anche con -p, e gli altri membri (frontend SDL, web,
# xeentool) vogliono crate da crates.io. La patch 0001 lascia nel workspace
# solo i tre crate del core (e Cargo.lock di conseguenza): cosi' la build va
# con --offline --locked, senza rete e senza crate da scaricare.

PKG_NAME="openxeenng"
PKG_VERSION="afe41a19bb74e7dc81984f00504c40758efee5b2"
PKG_ARCH="aarch64"
PKG_LICENSE="GPL-3.0-or-later"
# il progetto da cui riparte (Java, 2016-2017): https://github.com/busyDuckman/OpenXeen
PKG_SITE="https://github.com/debianita22/OpenXeenNG"
PKG_URL="${PKG_SITE}.git"
PKG_DEPENDS_TARGET="toolchain rust-bin:host"
PKG_LONGDESC="OpenXeenNG (milestone 0): motore di World of Xeen in Rust come core libretro; carica XEEN.CC/DARK.CC della propria copia."
PKG_TOOLCHAIN="manual"

make_target() {
  local rust="${TOOLCHAIN}/lib/rust-bin"
  # Triple ufficiale di Rust, non quella di LibreELEC (aarch64-libreelec-linux-
  # gnu): la libreria standard gia' compilata esiste solo per questa. Il link lo
  # fa il gcc del toolchain di LibreELEC, con il suo sysroot: stessa glibc
  # dell'immagine.
  local triple="aarch64-unknown-linux-gnu"
  export PATH="${rust}/bin:${PATH}"
  # una CARGO_HOME propria: quella che LibreELEC esporta e' dentro la cartella di
  # build del pacchetto rust, che qui non si costruisce
  export CARGO_HOME="${PKG_BUILD}/.cargo-home"
  export CARGO_TARGET_DIR="${PKG_BUILD}/.target"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER="${CC}"
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=cortex-a35"
  export CARGO_TERM_PROGRESS_WHEN="never"
  cd "${PKG_BUILD}"
  cargo build --release --offline --locked -p openxeenng-libretro --target "${triple}"
  cp "${CARGO_TARGET_DIR}/${triple}/release/libopenxeenng_libretro.so" "${PKG_BUILD}/openxeenng_libretro.so"
  ${STRIP} --strip-unneeded "${PKG_BUILD}/openxeenng_libretro.so"
}

makeinstall_target() {
  mkdir -p ${INSTALL}/usr/lib/libretro
  cp -v ${PKG_BUILD}/openxeenng_libretro.so ${PKG_BUILD}/crates/libretro/openxeenng_libretro.info \
    ${INSTALL}/usr/lib/libretro/
}
