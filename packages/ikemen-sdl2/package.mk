# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="ikemen-sdl2"
# stessa versione e stesso tarball di SDL2_input di Lakka
PKG_VERSION="2.32.10"
PKG_SHA256="5f5993c530f084535c65a6879e9b26ad441169b3e25d789d83287040a9ca5165"
PKG_LICENSE="ZLIB"
PKG_SITE="https://www.libsdl.org"
PKG_URL="https://www.libsdl.org/release/SDL2-${PKG_VERSION}.tar.gz"
PKG_SOURCE_DIR="SDL2-${PKG_VERSION}"
PKG_DEPENDS_TARGET="toolchain alsa-lib systemd libdrm ${OPENGLES}"
PKG_LONGDESC="SDL2 completa (Wayland, KMS/DRM, EGL/GLES, Vulkan, ALSA, joystick), statica e privata, per IKEMEN GO."
PKG_TOOLCHAIN="configure"
PKG_BUILD_FLAGS="+pic"

# Perche' un'altra SDL2. Lakka ha solo SDL2_input: compilata senza video, per
# l'input di RetroArch, e installata come /usr/lib/libSDL2-2.0.so.0. Una SDL2
# completa con lo stesso nome la sostituirebbe (o verrebbe sostituita, secondo
# l'ordine della build parallela). Questa e' statica e sta in percorsi suoi
# (/usr/lib/ikemen-sdl2, /usr/include/ikemen-sdl2, anche sdl2-config e sdl2.m4):
# finisce dentro il binario di IKEMEN e nell'immagine non aggiunge file.
#
# Video: Wayland (sway di Lakka) e KMS/DRM (build senza compositore), EGL con
# GLES e GL desktop, Vulkan; X11 no. Audio: solo ALSA, come Lakka (niente
# PulseAudio/PipeWire). Le librerie di sistema (wayland, libdrm, gbm, EGL,
# vulkan, asound, udev) SDL le apre a runtime con dlopen: qui servono solo gli
# header. Niente dbus/IME: sulla console non c'e' un desktop. Niente
# libsamplerate: se il sysroot ne ha l'header ma non la .so, SDL la
# collegherebbe direttamente e il link di IKEMEN fallirebbe (successo nella
# prova di compilazione arm64); il ricampionatore interno di SDL basta.
PKG_CONFIGURE_OPTS_TARGET="--libdir=/usr/lib/ikemen-sdl2 \
                           --includedir=/usr/include/ikemen-sdl2 \
                           --bindir=/usr/lib/ikemen-sdl2/bin \
                           --datarootdir=/usr/share/ikemen-sdl2 \
                           --disable-shared --enable-static --disable-rpath \
                           --disable-video-x11 \
                           --enable-video-kmsdrm --enable-kmsdrm-shared \
                           --enable-video-offscreen \
                           --enable-video-opengl --enable-video-opengles \
                           --enable-video-opengles1 --enable-video-opengles2 \
                           --enable-video-vulkan \
                           --disable-video-rpi --disable-video-directfb --disable-video-vivante \
                           --enable-alsa --enable-alsa-shared \
                           --disable-pulseaudio --disable-pipewire --disable-jack \
                           --disable-sndio --disable-esd --disable-arts --disable-nas \
                           --disable-oss --disable-diskaudio \
                           --disable-libsamplerate \
                           --enable-joystick --enable-haptic --enable-sensor \
                           --enable-hidapi --disable-hidapi-libusb \
                           --enable-libudev --disable-dbus --disable-ime \
                           --disable-ibus --disable-fcitx"

if [ "${DISPLAYSERVER}" = "wl" ]; then
  PKG_DEPENDS_TARGET+=" wayland wayland:host libxkbcommon"
  PKG_CONFIGURE_OPTS_TARGET+=" --enable-video-wayland --enable-wayland-shared --disable-libdecor"
else
  PKG_CONFIGURE_OPTS_TARGET+=" --disable-video-wayland"
fi

post_configure_target() {
  # configure spegne in silenzio quello per cui non trova le dipendenze (per
  # Wayland basta un wayland-scanner sbagliato): meglio fermarsi qui che
  # scoprirlo sul device con IKEMEN che non apre la finestra.
  local conf=include/SDL_config.h want="SDL_VIDEO_DRIVER_KMSDRM SDL_VIDEO_OPENGL_EGL SDL_VIDEO_OPENGL_ES2 SDL_VIDEO_VULKAN SDL_AUDIO_DRIVER_ALSA SDL_JOYSTICK_LINUX"
  [ "${DISPLAYSERVER}" = "wl" ] && want+=" SDL_VIDEO_DRIVER_WAYLAND"
  for d in ${want}; do
    grep -q "^#define ${d} 1" ${conf} || die "ikemen-sdl2: ${d} non abilitato dal configure (vedi config.log)"
  done
}

makeinstall_target() {
  # solo nel sysroot: la libreria e' statica e serve solo a compilare ikemen
  make install DESTDIR=${SYSROOT_PREFIX} -j1
  # Libs deve bastare a un link statico: cgo chiama "pkg-config --libs sdl2",
  # senza --static, quindi le dipendenze vanno qui e non in Libs.private.
  # dl e pthread stanno nella glibc dalla 2.34, ma dichiararli non costa nulla.
  sed -i 's|^Libs:.*|Libs: -L${libdir} -lSDL2 -lm -ldl -lpthread|' \
    ${SYSROOT_PREFIX}/usr/lib/ikemen-sdl2/pkgconfig/sdl2.pc
}
