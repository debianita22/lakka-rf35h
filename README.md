# Lakka for the XiFan RF35H

An overlay that adds the `rf35h` device to the
[Lakka-LibreELEC](https://github.com/libretro/Lakka-LibreELEC) tree (`devel`
branch, pinned commit) for the XiFan RF35H handheld: Rockchip RK3326, Mali-G31,
640×480 panel at 60 Hz. Mainline Linux 7.2.7, Mesa with Panfrost, Wayland and
sway; RetroArch uses OpenGL ES by default, with Vulkan (PanVK) selectable.

It takes the hardware pieces of devaOS (device tree, kernel patches, the two
out-of-tree drivers, the boot loader) and builds them with LibreELEC's build
system.

*Italian documentation and the full development log:
[`docs/diario.md`](docs/diario.md).*

## What the image has

- **RetroArch** with a curated set of 30 cores, a main one and a fallback for
  each system (`--all-cores` for all of Lakka's RK3326 cores), and integer
  scaling by default for the handheld systems (Game Boy, GBA, Neo Geo Pocket,
  WonderSwan, Lynx).
- **Device Settings** in RetroArch: speaker volume, audio output, brightness,
  sleep timer, status and joystick LEDs, rumble, compressed RAM (zram), USB-C
  port mode, network time, a thumbnail scraper.
- **Hardware support**: Wi-Fi (RK915, WPA3), the analog joypad, rumble,
  volume and power keys, battery, suspend.
- **IKEMEN GO** (fighting game engine) with its official screenpack and Kung
  Fu Man, in *Contentless Cores*.
- **Games made for this console**, all in *Contentless Cores*, none with game
  data:
  - GTA: San Andreas, from your own Android 2.11.311 APK and OBB:
    [gtasa-rf35h](https://github.com/debianita22/gtasa-rf35h);
  - OpenXeenNG, the World of Xeen engine in Rust, with your GOG archives:
    [OpenXeenNG](https://github.com/debianita22/OpenXeenNG);
  - Deva's Awesome Adventures, an educational game for five-year-olds
    (Italian): [deva-adventures](https://github.com/debianita22/deva-adventures);
  - GTA III (re3), optional and not distributed: see below.

## Build

You need an x86_64 Linux host, the RF35H board folder of devaOS
(`boards/rf35h`, for the boot loader the device starts with) and a few hours.
On Arch or CachyOS build in the container: the host compiler is too new for
LibreELEC.

```sh
git clone https://github.com/debianita22/lakka-rf35h.git
./lakka-rf35h/build-lakka-rf35h.sh --deva ../devaOS/boards/rf35h --dry-run
./lakka-rf35h/build-lakka-rf35h.sh --deva ../devaOS/boards/rf35h

# Arch, CachyOS: the same options, inside Ubuntu 24.04 (Docker or Podman)
./lakka-rf35h/build-in-docker.sh --deva ../devaOS/boards/rf35h
```

The script clones Lakka at the pinned commit next to the overlay
(`lakka-rf35h-build/`), applies the overlay, checks that every change landed
(`tools/verify-claims.sh`), builds, and checks the image before you flash it
(`tools/verify-image.sh`: the boot loader, the device tree, the game cores).
Useful options (`--help` for all):

| | |
|---|---|
| `--cores "a b c"`, `--all-cores` | a smaller or larger set of cores |
| `--keep-going` | skip a core or a game that doesn't compile, and say which |
| `--no-vulkan`, `--no-ikemen` | without Vulkan, without IKEMEN GO |
| `--no-gtasa`, `--no-openxeenng`, `--no-deva-adventures` | without that game |
| `--re3 <dir>` | with GTA III (re3), from its package |
| `--verify-only` | check the last image and the kernel source, build nothing |

## Install and update

- First time: `sudo ./lakka-rf35h/flash-sd.sh target/<image>.img.gz /dev/sdX`
  (refuses non-removable disks, unmounts, checks both partitions after
  writing, enables ssh).
- Updates without rewriting the card: copy `target/<image>.tar` to
  `/storage/.update` and reboot; ROMs, saves and settings stay.

To update the overlay, `git pull` and run the same command again. If what
goes into the Lakka tree changed, the build stops with "overlay disallineato"
and prints three commands that re-apply it, keeping downloaded sources and
built packages.

## GTA III (re3)

re3 is a reverse-engineered GTA III with no license: Take-Two had it removed
from GitHub in 2021. It is not in this repository. With its package, kept
privately, `--re3 <dir>` adds it to the image (`build-in-docker.sh` mounts
the folder). An image that contains re3 is for personal use only.

## License

The overlay's own files are GPL-2.0, like LibreELEC ([`LICENSE`](LICENSE)).
Patches keep the license of what they patch (Linux and LibreELEC GPL-2.0,
RetroArch GPL-3.0, IKEMEN GO MIT); files with their own SPDX header keep
theirs (the OpenXeenNG package GPL-3.0-or-later, the Deva package MIT). The
software fetched at build time keeps its own license.
