# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="ikemen-go"
# tag v1.0.0 (11/9/2026). Sorgente git, fissato per commit.
PKG_VERSION="81c6da71d689625e20db79586815b695da00dd6d"
PKG_LICENSE="MIT"
PKG_SITE="https://github.com/ikemen-engine/Ikemen-GO"
PKG_URL="https://github.com/ikemen-engine/Ikemen-GO.git"
PKG_GIT_SKIP_SUBMODULE="yes"
# retroarch: il suo libretro.h per il core lanciatore (launcher/)
PKG_DEPENDS_TARGET="toolchain golang-bin:host ikemen-sdl2 libxmp ffmpeg ${OPENGLES} ikemen-screenpack retroarch"
# ...letto dalla cartella di build di RetroArch: con AUTOREMOVE=yes (la CI)
# quella cartella sparisce appena RetroArch e' fatto, a meno che qualcuno la
# dichiari qui. Senza, il lanciatore non compila e --keep-going toglie IKEMEN.
PKG_DEPENDS_UNPACK="retroarch"
PKG_LONGDESC="IKEMEN GO 1.0, motore di picchiaduro compatibile MUGEN, con renderer OpenGL ES 3.2 (predefinito) e OpenGL 3.3."
PKG_TOOLCHAIN="manual"

# Il renderer Vulkan resta compilato ma e' spento: rf35h-ikemen esporta
# IKEMEN_DISABLE_VULKAN (patch 0003), perche' PanVK sul Mali-G31 espone Vulkan
# 1.0 e il renderer di IKEMEN, forzato a 1.3, lascia lo schermo nero. La
# dipendenza resta com'era: non cambia cosa si compila.
if [ "${VULKAN_SUPPORT}" = "yes" ]; then
  PKG_DEPENDS_TARGET+=" ${VULKAN}"
fi

# Le patch (patches/, applicate da LibreELEC):
#  0001 OpenGL ES 3.2 anche su Linux (tag "gles": prima esisteva solo per
#       Android) e dialoghi senza GTK (tag "nodialog"); il menu di IKEMEN
#       mostra solo i renderer compilati.
#  0002 correzioni ai renderer GLES e Vulkan trovate provando questa build:
#       framebuffer di post-processing incompleti su GLES, shader esterni che
#       su GLES non compilavano e facevano crashare l'avvio, limiti Vulkan non
#       letti sulle GPU integrate, scissor fuori misura.
#  0003 IKEMEN_DISABLE_VULKAN: toglie Vulkan dal menu Opzioni > Video e fa
#       tornare un RenderMode Vulkan a OpenGL (ES se compilato).

make_target() {
  # Go ufficiale (golang-bin:host): il perche' e' nel suo package.mk
  export GOROOT=${TOOLCHAIN}/lib/golang-bin
  export PATH=${GOROOT}/bin:${PATH}
  export GOOS=linux
  case ${TARGET_ARCH} in
    aarch64) export GOARCH=arm64 GOARM64=v8.0 ;;
    arm)     export GOARCH=arm GOARM=7 ;;
    x86_64)  export GOARCH=amd64 ;;
  esac
  export CGO_ENABLED=1
  export CGO_CFLAGS="${CFLAGS}"
  export CGO_LDFLAGS="${LDFLAGS}"
  # GOEXPERIMENT=arenas: IKEMEN lo usa per il rollback del netplay, e lo
  # impostano anche i rilasci ufficiali (build/build.sh)
  export GOEXPERIMENT=arenas GOTOOLCHAIN=local
  export GOPATH=${PKG_BUILD}/.gopath GOCACHE=${PKG_BUILD}/.gocache
  export GOFLAGS="-modcacherw -trimpath -buildvcs=false"
  # la SDL2 completa e statica di ikemen-sdl2, non SDL2_input di Lakka
  export PKG_CONFIG_PATH=${SYSROOT_PREFIX}/usr/lib/ikemen-sdl2/pkgconfig

  # Tag: egl  -> go-gl prende le funzioni GL da EGL (Wayland/KMS, niente GLX)
  #      gles -> renderer OpenGL ES 3.2 (patch 0001)
  #      nodialog -> niente GTK (patch 0001)
  # I moduli Go li scarica go build (proxy.golang.org), verificati da go.sum.
  cd ${PKG_BUILD}
  go build -tags "egl gles nodialog" \
    -ldflags "-s -w -X 'main.Version=v1.0.0 (devaOS RF35H)'" \
    -o ${PKG_BUILD}/ikemen ./src

  # Il core lanciatore per "Core senza contenuto" (launcher/ikemen_libretro.c):
  # C puro, compilato col libretro.h dello stesso RetroArch che lo carichera'.
  # Esporta solo le funzioni retro_* (RETRO_API), il resto e' nascosto.
  ${CC} ${CFLAGS} -std=gnu99 -fPIC -fvisibility=hidden -Wall -Wextra -shared \
    -I$(get_build_dir retroarch)/libretro-common/include \
    -o ${PKG_BUILD}/ikemen_libretro.so ${PKG_DIR}/launcher/ikemen_libretro.c ${LDFLAGS}
}

makeinstall_target() {
  local share=${INSTALL}/usr/share/ikemen
  mkdir -p ${INSTALL}/usr/bin ${share} ${INSTALL}/usr/lib/systemd/system
  cp ${PKG_BUILD}/ikemen ${INSTALL}/usr/bin/ikemen
  cp ${PKG_DIR}/scripts/rf35h-ikemen ${INSTALL}/usr/bin/rf35h-ikemen
  chmod 0755 ${INSTALL}/usr/bin/ikemen ${INSTALL}/usr/bin/rf35h-ikemen
  cp ${PKG_DIR}/system.d/rf35h-ikemen.service ${INSTALL}/usr/lib/systemd/system/

  # "Core senza contenuto" di RetroArch: core e .info accanto agli altri
  # (/usr/lib/libretro, sotto /tmp/cores), come fa ScummVM col suo .info.
  # L'icona ha il nome del "database" del .info, nel tema monochrome di XMB
  # (quello predefinito, e lo stesso che usa Ozone); gli altri temi usano
  # l'icona generica.
  mkdir -p ${INSTALL}/usr/lib/libretro ${INSTALL}/usr/share/retroarch/assets/xmb/monochrome/png
  cp ${PKG_BUILD}/ikemen_libretro.so ${PKG_DIR}/launcher/ikemen_libretro.info ${INSTALL}/usr/lib/libretro/
  cp ${PKG_DIR}/launcher/ikemen-icon.png \
    "${INSTALL}/usr/share/retroarch/assets/xmb/monochrome/png/IKEMEN GO.png"

  # File del motore: stati comuni (data/*.zss, common.*), script Lua e shader
  # (external/), font di sistema (font/). Le icone PNG servono: senza, IKEMEN
  # va in panic all'avvio ("Icon file can not be found"). Gli .ico e gli SVG no.
  cp -a ${PKG_BUILD}/data ${PKG_BUILD}/external ${PKG_BUILD}/font ${share}/
  rm -rf ${share}/external/icons/icon-src
  rm -f ${share}/external/icons/*.ico
  cp ${PKG_DIR}/config/gamecontrollerdb.txt ${share}/external/gamecontrollerdb.txt
  cp ${PKG_DIR}/config/rf35h-default-config.ini ${share}/rf35h-default-config.ini
  cp ${PKG_BUILD}/LICENCE.txt ${share}/LICENCE-ikemen.txt

  # Elenco per rf35h-ikemen: questi file si sovrascrivono nella cartella di
  # gioco quando cambia engine.version (binario e script Lua vanno insieme).
  # La versione include le patch e la mappatura del joypad.
  (cd ${share} && find data external font -type f | LC_ALL=C sort) > ${share}/engine.list
  echo "${PKG_VERSION:0:12}-$(cat ${PKG_DIR}/patches/*.patch ${PKG_DIR}/config/gamecontrollerdb.txt | sha256sum | cut -c1-12)" \
    > ${share}/engine.version
}
