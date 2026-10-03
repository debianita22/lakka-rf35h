# SPDX-License-Identifier: MIT
# devaOS / Lakka RF35H port
#
# Deva's Awesome Adventures: gioco didattico per bambini di 5 anni, core
# libretro senza contenuto. Deriva da packaging/lakka/deva_adventures del suo
# sorgente.
#
# Il sorgente arriva dal suo repository, al commit della 1.0.0 (tag v1.0.0):
# lo stesso albero del tarball deva-adventures-1.0.0-src.tar.gz consegnato
# (sha256 042943f4...). Per un albero di sviluppo invece del repository:
# DEVA_ADVENTURES_SRC=/percorso/deva-adventures nell'ambiente della build (lo
# stamp di LibreELEC non lo vede: dopo un cambio di sorgente,
# scripts/clean deva_adventures).

PKG_NAME="deva_adventures"
# v1.0.0
PKG_VERSION="1e93ae98d9cd2cb0b8f6039e48e92aa362460424"
PKG_LICENSE="MIT"
PKG_SITE="https://github.com/debianita22/deva-adventures"
PKG_URL="${PKG_SITE}.git"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="Deva's Awesome Adventures: gioco didattico per bambini (voce italiana), core libretro senza contenuto: 18 giochi e 4 storie."
PKG_TOOLCHAIN="make"

PKG_MAKE_OPTS_TARGET="BUILDDIR=build/target DATA_DIR=/usr/share/deva_adventures"

if [ -n "${DEVA_ADVENTURES_SRC:-}" ]; then
  PKG_URL=""
  unpack() {
    mkdir -p "${PKG_BUILD}"
    [ -f "${DEVA_ADVENTURES_SRC}/src/libretro.c" ] || die "deva_adventures: nessun sorgente in ${DEVA_ADVENTURES_SRC}"
    # tutto tranne le uscite di build e i pacchetti di rilascio dello sviluppatore
    tar -C "${DEVA_ADVENTURES_SRC}" --exclude=./build --exclude=./release --exclude=./.git -cf - . \
      | tar -C "${PKG_BUILD}" -xf -
  }
fi

# -O2 col vettorizzatore completo (i cicli degli sprite e delle dissolvenze
# sono scritti per lui: stessi pixel, NEON), sezioni inutili tolte al link.
# Il -O2 di LibreELEC e' gia' quello del progetto: lo si ripete per chiarezza.
pre_make_target() {
  export CFLAGS="${CFLAGS} -O2 -ftree-vectorize -fvect-cost-model=dynamic -ffunction-sections -fdata-sections"
  export LDFLAGS="${LDFLAGS} -Wl,--gc-sections"
}

makeinstall_target() {
  mkdir -p ${INSTALL}/usr/lib/libretro ${INSTALL}/usr/share/deva_adventures
  cp -v build/target/deva_adventures_libretro.so ${INSTALL}/usr/lib/libretro/
  cp -v deva_adventures_libretro.info ${INSTALL}/usr/lib/libretro/
  # dati del gioco (~16,5 MB): la cartella di riserva del core (DATA_DIR) se
  # in system/ di RetroArch non c'e' una deva_adventures
  cp -PR data/deva_adventures/. ${INSTALL}/usr/share/deva_adventures/
}
