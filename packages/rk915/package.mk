# SPDX-License-Identifier: GPL-2.0
# devaOS / Lakka RF35H port

PKG_NAME="rk915"
PKG_VERSION="e2fd61651c272aab7bd7e76ba05e5682d7c1d211"
PKG_SHA256="5d3ad6fe0a0323e3fc93c6f8a2d6553c23a25288a21a4b73cdfb3557c273848e"
PKG_ARCH="aarch64"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://github.com/AveyondFly/rk915"
PKG_URL="https://github.com/AveyondFly/rk915/archive/${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain linux"
PKG_NEED_UNPACK="${LINUX_DEPENDS}"
PKG_LONGDESC="Rockchip RK915 SDIO WLAN driver. The only Wi-Fi hardware on the XiFan RF35H."

PKG_IS_KERNEL_PKG="yes"

# patches/0001  upstream kbuild fixes (EXTRA_CFLAGS -> ccflags-y, 6.15 compat)
# patches/0002  Linux 7.0 port: wakeup_source_{add,remove} went static, syscore
#               was reworked, mac80211 gained radio_idx, from_timer() renamed.
#               Every change is version-guarded, so 6.15 still builds.
make_target() {
# kernel_make, non "make": il wrapper di LibreELEC azzera LDFLAGS (quelli del
# target userspace rompono una build di moduli), e passa HOSTCC/HOSTCXX e
# DEPMOD della toolchain host di LibreELEC invece di quelli di sistema. Con
# make a mano il modulo puo' compilare e poi non caricarsi.
# ARCH e CROSS_COMPILE li mette gia' kernel_make.
  kernel_make -C $(kernel_path) M="${PKG_BUILD}" CONFIG_RK915=m modules
}

makeinstall_target() {
  mkdir -p ${INSTALL}/$(get_full_module_dir)/rk915
    cp -P rk915.ko ${INSTALL}/$(get_full_module_dir)/rk915

  # The driver will not associate without both blobs present.
  mkdir -p ${INSTALL}/$(get_full_firmware_dir)
    cp -P firmware/rk915_fw.bin    ${INSTALL}/$(get_full_firmware_dir)
    cp -P firmware/rk915_patch.bin ${INSTALL}/$(get_full_firmware_dir)

  # Caricato da systemd-modules-load nella fase sysinit, non dal coldplug di
  # udev: su Lakka il coldplug arriva a +20 s, con la scheda SDIO pronta da
  # +4 s. Sono sedici secondi di Wi-Fi (e ssh) in meno a ogni boot. Il driver
  # si aggancia al bus SDIO e trova la scheda gia' li'. Stesso posto di joycond.
  mkdir -p ${INSTALL}/usr/lib/modules-load.d
    echo "rk915" > ${INSTALL}/usr/lib/modules-load.d/rk915.conf
}
