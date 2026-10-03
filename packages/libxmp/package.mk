# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="libxmp"
# tag libxmp-4.6.3 (11/5/2025). Sorgente git, fissato per commit: il tarball
# dei rilasci sta su GitHub/SourceForge, il contenuto del tag no.
PKG_VERSION="bed660f8e530d399c38f27a5a7732f4e79740585"
PKG_LICENSE="MIT"
PKG_SITE="https://github.com/libxmp/libxmp"
PKG_URL="https://github.com/libxmp/libxmp.git"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="libxmp 4.6.3, libreria statica per la musica a moduli (MOD, XM, IT, S3M...) di IKEMEN GO."
PKG_TOOLCHAIN="cmake"
PKG_BUILD_FLAGS="+pic"

# Statica: la usa solo IKEMEN (cgo, -lxmp) e finisce dentro il suo binario.
# Non si tocca libxmp-lite di Lakka (easyrpg): header e librerie hanno nomi
# diversi (libxmp-lite/xmp.h, libxmp-lite.so).
PKG_CMAKE_OPTS_TARGET="-DBUILD_STATIC=ON \
                       -DBUILD_SHARED=OFF \
                       -DBUILD_LITE=OFF \
                       -DLIBXMP_PIC=ON \
                       -DWITH_UNIT_TESTS=OFF"

makeinstall_target() {
  # solo nel sysroot: nell'immagine non serve niente
  DESTDIR=${SYSROOT_PREFIX} ninja install
}
