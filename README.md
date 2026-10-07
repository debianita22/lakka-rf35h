# Lakka RF35H

[![Latest release](https://img.shields.io/github/v/release/debianita22/lakka-rf35h?style=flat-square&label=latest%20release)](https://github.com/debianita22/lakka-rf35h/releases/latest)
[![Check](https://img.shields.io/github/actions/workflow/status/debianita22/lakka-rf35h/check.yml?branch=main&style=flat-square&label=check)](https://github.com/debianita22/lakka-rf35h/actions/workflows/check.yml)
[![License](https://img.shields.io/github/license/debianita22/lakka-rf35h?style=flat-square)](LICENSE)

---

**Lakka RF35H** is an unofficial port of [Lakka](https://www.lakka.tv), the
RetroArch-based retro gaming distribution built on LibreELEC, to handheld
consoles based on the Rockchip RK3326. It runs a mainline Linux kernel with the
open-source Panfrost graphics stack and adds what a handheld needs on top of
Lakka: built-in controls, battery and LEDs, suspend, Wi-Fi, a *Device Settings*
menu in RetroArch and over-the-air updates.

Development and testing happen on the **XiFan RF35H**. Other RK3326 handhelds
need a port (device tree, boot loader, controls): see
[Porting](docs/guide.md#porting-to-another-rk3326-handheld).

## About this port

- **Unofficial.** Not affiliated with or supported by the Lakka or libretro
  teams: report problems here, not upstream.
- **Built from** [Lakka-LibreELEC](https://github.com/libretro/Lakka-LibreELEC)
  (`devel` branch, pinned commit) plus the overlay in this repository: device
  tree, kernel and RetroArch patches, drivers and device packages.
- **Differences from Lakka's own RK3326 images:**
  - Linux 7.2 with a reduced patch set, instead of Lakka's 7.0;
  - boot through a U-Boot 2025.10 loader from AURKNIX (`boot.scr` and
    `extlinux.conf`) instead of Hardkernel U-Boot and `boot.ini`;
  - `wpa_supplicant` instead of `iwd`, which the RK915 Wi-Fi driver needs;
  - updates come from this repository's releases: Lakka's online updater is
    disabled, because its generic RK3326 images do not boot on this device.

## Features

- RetroArch with a curated set of 34 libretro cores: a main core and, where
  one exists, a fallback for each system, chosen for the Cortex-A35; 22
  interpreter cores, RetroArch and Mesa are built with link-time
  optimization. All of Lakka's RK3326 cores are available as a build option.
- Mesa Panfrost with OpenGL ES by default; Vulkan (PanVK) selectable in
  RetroArch.
- *Device Settings* in RetroArch: brightness, sleep timer, stick and status
  LEDs, rumble, speaker volume and audio output, USB-C mode, compressed RAM
  (zram), network time, thumbnail scraper and system update.
- System updates from the console: the latest release is downloaded (resuming
  if interrupted), checked against its SHA-256 and installed at restart. ROMs,
  saves and settings are kept.
- Wi-Fi with WPA2/WPA3, Samba shares and SSH.
- USB-C host mode for gamepads (Xbox, PlayStation, Nintendo Switch and Steam
  controllers), USB drives (NTFS included), keyboards and USB-C audio; a USB
  network mode to copy files from a PC.
- Suspend on the power button and after a configurable idle time.
- Integer scaling by default for handheld-console cores; Nintendo 64
  (Mupen64Plus-Next) rendered at 320x240.

### Bundled extras

All launched from RetroArch. No commercial game data is included: GTA: San
Andreas and OpenXeenNG use the files from your own copy.

- **IKEMEN GO**: MUGEN-compatible fighting game engine, with the official
  screenpack and Kung Fu Man.
- **GTA: San Andreas**: runs the Android 2.11.311 (arm64-v8a) release from your
  own APK and OBB ([gtasa-rf35h](https://github.com/debianita22/gtasa-rf35h)).
- **OpenXeenNG**: open engine for Might and Magic IV/V (World of Xeen); uses
  the data files of your copy, runs a demo without them
  ([OpenXeenNG](https://github.com/debianita22/OpenXeenNG)).
- **Deva's Awesome Adventures**: educational game for young children, Italian
  voice ([deva-adventures](https://github.com/debianita22/deva-adventures)).

Each one can be left out at build time.

## Supported devices

| Brand | Model | SoC | Status |
|---|---|---|---|
| XiFan | RF35H | RK3326 | Supported, reference device |
| XiFan | XF35H | RK3326 | Untested; the RF35H device tree is built on the XF35H one |

Release images contain the RF35H device tree and boot loader only. Devices that
Lakka already supports (ODROID-GO Advance and Super, Anbernic RG351M/V) should
use the official Lakka images; for anything else see
[Porting](docs/guide.md#porting-to-another-rk3326-handheld).

## Installation

1. Download the `.img.gz` from the
   [latest release](https://github.com/debianita22/lakka-rf35h/releases/latest),
   or [build it](#building).
2. Write it to a microSD card (4 GB minimum, 16 GB or more recommended). On
   Linux, install the tools the script uses: on Debian or Ubuntu
   `sudo apt-get update && sudo apt-get install -y git dosfstools e2fsprogs parted mtools`,
   on Arch or CachyOS
   `sudo pacman -Syu --needed git dosfstools e2fsprogs parted mtools`. Then:

   ```sh
   git clone https://github.com/debianita22/lakka-rf35h.git
   sudo ./lakka-rf35h/flash-sd.sh Lakka-RK3326.aarch64-Next-<version>-rf35h.img.gz /dev/sdX
   ```

   Any raw image writer works too (balenaEtcher, or `zcat` piped into `dd`).
3. Insert the card and power on. The internal eMMC and its factory firmware
   are not touched.
4. Copy your games to the **ROMs** network share (or from a PC over USB-C, in
   *transfer* mode) and add them with *Import Content > Scan Directory*.

Updates: *Settings > Device Settings > System Update*.

## Documentation

- [Guide](docs/guide.md): installation, controls, Device Settings, updates,
  troubleshooting, building and porting.
- [Development log](docs/diario.md) (Italian).

## Building

An x86_64 Linux host with about 100 GB free; the first build takes hours. The
build runs in an Ubuntu 24.04 container, so the host needs only `git` and
Docker (or Podman). These lines also install the tools `flash-sd.sh` uses.

**Ubuntu 24.04 or newer, Debian 13** (on Debian 12 leave out `docker-buildx`):

```sh
sudo apt-get update
sudo apt-get install -y git docker.io docker-buildx dosfstools e2fsprogs parted mtools
sudo usermod -aG docker "$USER"
```

**Arch, CachyOS** (with paru: `paru -Syu --needed` and the same list; nothing
comes from the AUR):

```sh
sudo pacman -Syu --needed git docker docker-buildx dosfstools e2fsprogs parted mtools
sudo systemctl enable --now docker.service
sudo usermod -aG docker "$USER"
```

Log out and back in, so that Docker runs as your user, then:

```sh
mkdir -p ~/lakka && cd ~/lakka
git clone https://github.com/debianita22/lakka-rf35h.git
./lakka-rf35h/build-in-docker.sh
```

The image and the update file end up in `lakka-rf35h-build/target/`. Podman,
rootless included, can replace Docker; on Ubuntu 24.04 the build can also run
natively, with `./lakka-rf35h/build-lakka-rf35h.sh`. Install commands for
Podman and Fedora, the native package list, options and CI releases:
[Building from source](docs/guide.md#building-from-source).

## Contributing

Issues and pull requests are welcome. Run `./tools/ci-check.sh` before pushing:
CI runs the same checks, plus a dry run on the pinned Lakka commit, on every
pull request.

## Licenses

The overlay's own files are licensed under the
[GNU GPL version 2](LICENSE), like LibreELEC.

### Bundled works

- Patches keep the license of what they patch (Linux and LibreELEC GPL-2.0,
  RetroArch GPL-3.0, IKEMEN GO MIT); files with their own SPDX header keep
  theirs.
- The boot loader in `board/loader` is AURKNIX's build of U-Boot
  (GPL-2.0-or-later) with Rockchip's binaries: see its
  [README](board/loader/README.md).
- The IKEMEN GO screenpack is CC BY 3.0, its Elecbyte fonts CC BY-NC 3.0
  (non-commercial use).
- Software fetched at build time keeps its own license. Commercial games are
  not included and belong to their owners.

## Credits

This port stands on the work of many projects:

- [Lakka](https://www.lakka.tv) and [libretro](https://www.libretro.com), with
  RetroArch and its cores, and [LibreELEC](https://libreelec.tv) underneath.
- [ROCKNIX](https://github.com/ROCKNIX/distribution): the joypad driver and the
  generic DSI panel driver.
- [AURKNIX](https://github.com/lcdyk0517/distribution_aurknix) and
  [AveyondFly](https://github.com/AveyondFly): the XF35H device tree, the boot
  loader, and the RK915 Wi-Fi and joypad driver sources.
- The [Mesa](https://mesa3d.org) Panfrost developers and the mainline Linux
  Rockchip maintainers.
- [IKEMEN GO](https://github.com/ikemen-engine/Ikemen-GO), and the gtasa_nx
  authors for the GTA: San Andreas loader.
- ArkOS4Clone, used as the reference for vendor hardware settings.
