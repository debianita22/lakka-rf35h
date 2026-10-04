# Lakka for the XiFan RF35H

An overlay that adds the `rf35h` device to the
[Lakka-LibreELEC](https://github.com/libretro/Lakka-LibreELEC) tree (`devel`
branch, pinned commit) for the XiFan RF35H handheld: Rockchip RK3326, Mali-G31,
640×480 panel at 60 Hz. Mainline Linux 7.2.7, Mesa with Panfrost, Wayland and
sway; RetroArch uses OpenGL ES by default, with Vulkan (PanVK) selectable.

It takes the hardware pieces of devaOS (device tree, kernel patches, the two
out-of-tree drivers, the boot loader) and builds them with LibreELEC's build
system. Ready-made images are in the
[releases](https://github.com/debianita22/lakka-rf35h/releases), built by
GitHub Actions.

*Italian documentation and the full development log:
[`docs/diario.md`](docs/diario.md).*

## What the image has

- **RetroArch** with a curated set of 30 cores, a main one and a fallback for
  each system (`--all-cores` for all of Lakka's RK3326 cores), and integer
  scaling by default for the handheld systems (Game Boy, GBA, Neo Geo Pocket,
  WonderSwan, Lynx).
- **Device Settings** in RetroArch: speaker volume, audio output, brightness,
  sleep timer, status and joystick LEDs, rumble, compressed RAM (zram), USB-C
  port mode, network time, a thumbnail scraper, and System Update from the
  GitHub releases.
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

You need an x86_64 Linux host and a few hours. On Arch or CachyOS build in
the container: the host compiler is too new for LibreELEC.

```sh
git clone https://github.com/debianita22/lakka-rf35h.git
./lakka-rf35h/build-lakka-rf35h.sh --dry-run
./lakka-rf35h/build-lakka-rf35h.sh

# Arch, CachyOS: the same options, inside Ubuntu 24.04 (Docker or Podman)
./lakka-rf35h/build-in-docker.sh
```

The boot loader is the one the RF35H is known to boot with, in
[`board/loader`](board/loader) (sha256-checked, the same file as devaOS);
`--deva <dir>` takes another one.

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

- First time: `sudo ./lakka-rf35h/flash-sd.sh <image>.img.gz /dev/sdX`
  (refuses non-removable disks, unmounts, checks both partitions after
  writing, enables ssh), with an image you built or one from the releases.
- **From the console**: *Settings > Device Settings > System Update* checks
  the latest release, downloads its `.tar` (resuming if stopped), checks
  size and SHA-256 against the release's `update.txt`, and asks to restart:
  LibreELEC's init installs it at boot. ROMs, saves and settings stay. It
  needs the network, the right time (Network Time) and 30% battery or the
  charger. Over ssh: `rf35h-update run`.
- By hand: copy the `.tar` to `/storage/.update` and reboot.

Lakka's own *Update Lakka* entry is hidden on this console, and `lakka-update`
hands over to `rf35h-update`: Lakka's images are for a generic RK3326 and
would leave this one unable to boot. `/storage/.config/rf35h/update.conf` can
point the updater elsewhere: `TAG=v1.2.0` (a specific release, also a
pre-release or an older one), `REPO=user/repository`, or
`URL=https://.../update.txt`.

To update the overlay, `git pull` and run the same command again. If what
goes into the Lakka tree changed, the build stops with "overlay disallineato"
and prints three commands that re-apply it, keeping downloaded sources and
built packages.

## Releases (CI)

[`.github/workflows`](.github/workflows):

- **Check**, on every push and pull request: shellcheck, the patches, the
  test scripts (`tools/ci-check.sh`, the same locally), and a dry run on the
  pinned Lakka commit with the build plan. A few minutes.
- **Build**: the whole image in the Ubuntu 24.04 container, on GitHub's free
  runners. A job lasts at most 6 hours and a build from scratch takes
  longer, so it runs in up to four parts: each one builds until shortly
  before its limit and hands its state to the next (`tools/ci-build.sh`);
  ccache is kept between builds. Triggers:
  - a tag `v*` (`git tag v1.0.0 && git push origin v1.0.0`): build and
    release;
  - *Actions > Build > Run workflow*: with a version, build and release
    (the tag is created at the end); without, a test build whose image
    stays in the run's artifacts for 14 days;
  - a push to a `ci-test/...` branch: test build, never a release;
  - *Run workflow* with `resume_run`, the ID of a failed build: a test build
    that starts from the state the failed part saved (kept 3 days, the ID is
    in its summary) and rebuilds only the packages whose files changed. To
    check a fix in an hour instead of a day; never for a release, since the
    image mixes packages built from two commits.

A release has the image (`.img.gz`), the update (`.tar`), `update.txt`
(version, name, size and SHA-256 of the `.tar`: what System Update reads,
always from the latest release) and `SHA256SUMS`. Tags with a dash
(`v1.1.0-rc1`) and "pre-release" runs are published as pre-releases, which
the consoles do not install unless `update.conf` names them.

## GTA III (re3)

re3 is a reverse-engineered GTA III with no license: Take-Two had it removed
from GitHub in 2021. It is not in this repository and never in a release.
With its package, kept privately, `--re3 <dir>` adds it to the image
(`build-in-docker.sh` mounts the folder). An image that contains re3 is for
personal use only. On a console running such an image, System Update first
copies the core and its files to `/storage/cores` and `/storage/system/re3`,
so GTA III survives an update to a release; the copy is removed again when a
personal image brings its own re3.

## License

The overlay's own files are GPL-2.0, like LibreELEC ([`LICENSE`](LICENSE)).
The boot loader in `board/loader` is AURKNIX's, unmodified: U-Boot (GPL-2.0+)
and Rockchip's binaries, see [its README](board/loader/README.md).
Patches keep the license of what they patch (Linux and LibreELEC GPL-2.0,
RetroArch GPL-3.0, IKEMEN GO MIT); files with their own SPDX header keep
theirs (the OpenXeenNG package GPL-3.0-or-later, the Deva package MIT). The
software fetched at build time keeps its own license.
