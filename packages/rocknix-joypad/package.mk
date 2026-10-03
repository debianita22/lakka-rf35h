# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="rocknix-joypad"
PKG_VERSION="7f3272ff6bd002c718291465ae5e5d752ccb24b8"
PKG_SHA256="3f8a48e4be159d5c1ee5018849a9a0d0bdfcfad3797320d7983313b773098d48"
PKG_ARCH="aarch64"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://github.com/AveyondFly/rocknix-joypad"
PKG_URL="https://github.com/AveyondFly/rocknix-joypad/archive/${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain linux"
PKG_NEED_UNPACK="${LINUX_DEPENDS}"
PKG_LONGDESC="Joypad driver for RK3326 handhelds whose four analog axes are multiplexed onto a single SARADC channel."

PKG_IS_KERNEL_PKG="yes"

# The upstream Makefile branches on DEVICE, not on CONFIG_* symbols. RK3326 is
# not one of the names it special-cases, so it falls through to the default
# branch and builds both variants; patch 0001 adds an explicit RK3326 branch
# that builds only rocknix-singleadc-joypad, which is what the RF35H device
# tree binds. Verified against the driver Makefile, not assumed.
make_target() {
# kernel_make, non "make": il wrapper di LibreELEC azzera LDFLAGS (quelli del
# target userspace rompono una build di moduli), e passa HOSTCC/HOSTCXX e
# DEPMOD della toolchain host di LibreELEC invece di quelli di sistema. Con
# make a mano il modulo puo' compilare e poi non caricarsi.
# ARCH e CROSS_COMPILE li mette gia' kernel_make.
  # Niente -DROCKNIX_OF_GPIO_LEGACY_PRESENT: con il kernel 7.2.7 la pila e'
  # snella e non c'e' 0002-add-input-polldev di Lakka, che reintroduceva
  # l'API legacy di <linux/of_gpio.h>. Nella 7.2 quell'header non esiste piu':
  # of_gpio_compat.h (patch 0003) ricostruisce of_get_named_gpio con le
  # primitive gpio_device, ed e' quella strada che il flag disattiverebbe.
  kernel_make -C $(kernel_path) M="${PKG_BUILD}" DEVICE=RK3326 modules
}

makeinstall_target() {
  mkdir -p ${INSTALL}/$(get_full_module_dir)/rocknix
    cp -P rocknix-singleadc-joypad.ko ${INSTALL}/$(get_full_module_dir)/rocknix

  # Come per rk915: in sysinit invece che al coldplug di udev (+20 s). Il pad
  # c'e' da subito, non dopo che RetroArch e' gia' partito. Se SARADC o GPIO
  # non fossero ancora pronti, il probe rientra con EPROBE_DEFER e riprova.
  mkdir -p ${INSTALL}/usr/lib/modules-load.d
    echo "rocknix-singleadc-joypad" > ${INSTALL}/usr/lib/modules-load.d/rocknix-joypad.conf
}
