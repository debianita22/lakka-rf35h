# Lakka RF35H guide

Installation, daily use, updates and troubleshooting on the console, then
building the image and porting it to another RK3326 handheld.

- [Overview](#overview)
- [Installation](#installation)
- [Using the console](#using-the-console)
- [Updating](#updating)
- [Troubleshooting](#troubleshooting)
- [Building from source](#building-from-source)
- [Releases and CI](#releases-and-ci)
- [Porting to another RK3326 handheld](#porting-to-another-rk3326-handheld)
- [Repository layout](#repository-layout)

## Overview

| | |
|---|---|
| Base | Lakka-LibreELEC `devel` at a pinned commit; RetroArch from Lakka, with this repository's patches |
| Kernel | mainline Linux 7.2.7 with a short board patch set |
| Graphics | Mesa: Panfrost (OpenGL ES, default) and PanVK (Vulkan, optional); sway as compositor |
| Boot | AURKNIX loader with U-Boot 2025.10 at 32 KiB, then `boot.scr`, then `/extlinux/extlinux.conf` |
| Build target | `PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 UBOOT_SYSTEM=rf35h` |

The microSD card:

| Area | Label | Mounted at | Contents |
|---|---|---|---|
| raw, 32 KiB to 16 MiB | | | boot loader |
| partition 1, FAT, 3 GiB | `LAKKA` | `/flash`, read-only | kernel, `SYSTEM` (squashfs), device tree, boot files |
| partition 2, ext4, rest of the card | `LAKKA_DISK` | `/storage` | ROMs, saves, settings, logs |

Updates rewrite partition 1 and the boot loader area (with the same loader);
`/storage` is never touched by them.

### XiFan RF35H hardware status

| Component | Status |
|---|---|
| Display, 3.5" 640x480 MIPI DSI, 60 Hz | Supported |
| OpenGL ES (Panfrost) | Supported, default |
| Vulkan (PanVK) | Optional; Mesa marks it non-conformant on the Mali-G31 (Vulkan 1.0) |
| D-pad, ABXY, L1/L2/R1/R2, Select, Start, two sticks with L3/R3 | Supported |
| Volume keys, power key | Supported |
| Speakers, headphone jack, USB-C audio | Supported |
| Wi-Fi (RK915) | Supported, WPA2/WPA3 |
| Bluetooth | Not present on the board |
| Rumble | Supported, on/off only (the motor is on a GPIO) |
| Stick RGB rings, red and blue status LEDs | Supported |
| Battery and charging | Supported |
| Suspend and resume | Supported |
| USB-C | Host mode (default) or USB network gadget |
| Internal eMMC | Not used; the factory firmware is left untouched |
| CPU boost to 1416 MHz | Present, off by default (see [Performance](#performance)) |

## Installation

### What you need

- A microSD card: 4 GB minimum (the uncompressed image is about 3.3 GB),
  16 GB or more for a real game library. GTA: San Andreas alone needs about
  3 GB free to install.
- A card reader.
- On Linux, `git` and the tools `flash-sd.sh` uses. `util-linux`, `coreutils`
  and `gzip` are part of every base system; install the rest:

  | Package | Provides | Used for |
  |---|---|---|
  | `dosfstools` | `fsck.fat` | checking the FAT partition (required) |
  | `e2fsprogs` | `fsck.ext4`, `e2fsck`, `resize2fs` | checking and expanding `/storage` (required) |
  | `parted` | `parted`, `partprobe` | expanding `/storage` from the PC |
  | `mtools` | `mcopy` | enabling SSH when `/storage` is expanded on the console |

  **Debian, Ubuntu**

  ```sh
  sudo apt-get update
  sudo apt-get install -y git dosfstools e2fsprogs parted mtools
  ```

  **Arch, CachyOS, Manjaro, EndeavourOS** (with paru, `paru -Syu --needed`
  and the same list)

  ```sh
  sudo pacman -Syu --needed git dosfstools e2fsprogs parted mtools
  ```

  **Fedora**

  ```sh
  sudo dnf install -y git dosfstools e2fsprogs parted mtools
  ```

- On Windows or macOS: [balenaEtcher](https://etcher.balena.io), which writes
  `.img.gz` files directly. On Arch it is also in the AUR: `paru -S etcher-bin`.

### Download

Each [release](https://github.com/debianita22/lakka-rf35h/releases) has:

| File | Use |
|---|---|
| `Lakka-RK3326.aarch64-Next-<version>-rf35h.img.gz` | first installation: replaces everything on the card |
| `Lakka-RK3326.aarch64-Next-<version>-rf35h.tar` | update: ROMs, saves and settings stay |
| `update.txt` | what the console's updater reads |
| `SHA256SUMS` | checksums of the `.img.gz` and the `.tar` |

To check what you downloaded, in the folder that holds it:

```sh
sha256sum -c SHA256SUMS --ignore-missing
```

### Write the card

**Linux, with `flash-sd.sh`** (recommended):

```sh
git clone https://github.com/debianita22/lakka-rf35h.git
sudo ./lakka-rf35h/flash-sd.sh Lakka-RK3326.aarch64-Next-<version>-rf35h.img.gz /dev/sdX
```

The script:

1. accepts only whole disks (`/dev/sdX`, `/dev/mmcblkN`, `/dev/loopN`) that
   report themselves as removable and are 512 GB or smaller; for a card reader
   that misreports, run it as `sudo env FORCE=yes ./lakka-rf35h/flash-sd.sh …`;
2. waits 5 seconds (Ctrl-C to abort), unmounts the card's partitions and
   removes old filesystem signatures;
3. writes the image with `dd conv=fsync` and checks both filesystems;
4. expands `/storage` to the whole card;
5. enables SSH (see [SSH](#ssh) for the default password).

Without `parted` the console expands `/storage` at first boot; without
`mtools` SSH then stays off (see [What you need](#what-you-need)).

**Any other system**: a raw image writer that accepts `.img.gz` files, such as
balenaEtcher, or:

```sh
zcat Lakka-RK3326.aarch64-Next-<version>-rf35h.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

Unmount the card's partitions first: writing over a mounted card can leave
the new `/storage` corrupted. With these methods SSH stays off and the console
expands `/storage` at first boot.

### First boot

Insert the card and press the power button. On a card written without
`flash-sd.sh`, the first boot also expands `/storage`, so it takes longer.
Then:

- connect to Wi-Fi in *Settings > Wi-Fi*;
- copy games and BIOS files (see [Games and BIOS files](#games-and-bios-files)).

## Using the console

### Controls

The hotkey is **Select**: hold it and press the second button.

| Buttons | Action |
|---|---|
| Select + Start | RetroArch menu (opens when Start is released) |
| Select + R1 / Select + L1 | save state / load state |
| Select + D-pad right / left | next / previous state slot |
| Select + R2, held | fast-forward |
| Select + L2 | rewind, once enabled in *Settings > Frame Throttle > Rewind* |
| Select + X | screenshot |
| Select + R3 | quit RetroArch (press twice); Lakka restarts it |
| Volume up / down | volume |
| L1 + Volume up / down | screen brightness |
| Power, short press | suspend; press again to wake |
| Power, held 5 seconds | power off |

A quick press of Select still reaches the game: RetroArch blocks game input
only when Select is held longer than a few frames.

### Device Settings

*Settings > Device Settings*. Every entry applies immediately and is restored
at boot.

| Entry | Values (default) | Notes |
|---|---|---|
| Sleep Timer | 0 (off), 5 to 60 minutes (10) | suspend after this many minutes without input |
| Screen Brightness | 5 to 100 % (60) | also L1 + Volume, from anywhere |
| LED Settings > Joystick LEDs | the 17 modes of the ring controller (colours, `flow`, breathing, `off`), plus `battery`, `charging`, `alert`, `rainbow`, `strobe` (`blue`) | the rings turn off while the console sleeps |
| LED Settings > Status LEDs | `charge`, `battery`, `heartbeat`, `activity`, `red`, `blue`, `both`, `off` (`charge`) | the red and blue LEDs |
| LED Settings > LED Effect Speed | `slow`, `normal`, `fast` (`normal`) | for `rainbow` and `strobe` |
| USB-C Port | `host`, `transfer` (`host`) | see [USB-C port](#usb-c-port) |
| Audio Output | `speakers`, `usb` (`speakers`) | `speakers` covers the headphone jack too; `usb` is USB-C headphones or a USB DAC, in host mode |
| Speaker Volume | 0 to 100 % (28) | sound chip level before the amplifier, separate from RetroArch's volume |
| Rumble | on/off (on) | no intensity control: *Rumble Gain* has no effect on this device |
| Compressed RAM (zram) | on/off (on) | half the RAM as LZ4-compressed swap; keeps large cores from running out of memory |
| Thumbnail Scraper | *Scrape Thumbnails*, *Scrape Only Missing Thumbnails* (on), *Scraper Region* (`eu`) | see [Thumbnails](#thumbnails) |
| Network Time | *Network Time (NTP)* (on), *Time Server* (`it.pool.ntp.org`; also `pool.ntp.org`, `time.cloudflare.com`, `time.google.com`) | the console has no battery-backed clock |
| System Update | action | see [Updating](#updating) |

The Bluetooth menus are hidden (there is no Bluetooth hardware), and so is
Lakka's *Update Lakka* entry.

### Games and BIOS files

| What | Network share | On the card |
|---|---|---|
| Games | `ROMs` | `/storage/roms` |
| BIOS files | `System` | `/storage/system` |
| Saves / save states | `Savefiles` / `Savestates` | `/storage/savefiles` / `/storage/savestates` |
| Update files | `Update` | `/storage/.update` |

From Windows the shares are at `\\LAKKA\`. After copying games, create the
playlists with *Import Content > Scan Directory*. USB drives, NTFS included,
are mounted under `/media`.

### Cores

The default image has 30 libretro cores: a main core and, where one exists, a
fallback for each system. Names are the ones `--cores` takes.

| System | Main | Fallback |
|---|---|---|
| SNES / Super Famicom | `snes9x2010` | `snes9x` (accurate), `snes9x2005` (light) |
| Game Boy / Color | `gambatte` | `sameboy`, `tgbdual` |
| NES / Famicom | `fceumm` | `nestopia` |
| Mega Drive / Genesis | `genesis_plus_gx` | `picodrive` |
| Master System, Game Gear, SG-1000 | `genesis_plus_gx` | `gearsystem` |
| Sega 32X | `picodrive` | none |
| Game Boy Advance | `mgba` | `gpsp` |
| PC Engine / SuperGrafx | `beetle_pce_fast` | `beetle_pce` |
| Neo Geo, CPS1/2/3 | `fbneo` | `fbalpha2012`, `mame2010` |
| MAME (0.139 romset) | `mame2010` | `mame2015` (0.160; many 0.139 sets load) |
| Nintendo 64 | `mupen64plus_next` | `parallel_n64` |
| Neo Geo Pocket | `beetle_ngp` | `race` |
| Atari 2600 | `stella2014` | `stella` |
| Nintendo DS | `melonds` | `melondsds` |
| Amstrad CPC | `cap32` | `crocods` |
| Dreamcast | `flycast` | none |

Other systems (PlayStation, WonderSwan, Lynx and more) need an image built
with `--cores` or `--all-cores` (see [Build options](#build-options)).

Per-core defaults, copied to `/storage/.config/retroarch/config/` only when
missing (delete a file to get the default back):

- integer scaling for Game Boy, Game Boy Advance, Neo Geo Pocket, WonderSwan
  and Lynx cores: on the 4:3 panel every pixel gets the same size, with black
  borders around the picture;
- Mupen64Plus-Next renders at 320x240, the native resolution of most N64
  games, upscaled 2x.

### Video

OpenGL ES is the default driver. To try Vulkan: *Settings > Drivers > Video >
vulkan*, then restart RetroArch. If RetroArch dies twice in a row within 30
seconds of starting with Vulkan, the console puts `gl` back and writes
`vulkan-fallback-*.txt` to `/storage/rf35h-logs`.

The panel runs at 60 Hz (640x480).

### Performance

- *Settings > Power Management* has RetroArch's CPU performance settings.
- The CPU tops out at 1296 MHz; the 1416 MHz boost exists but is off. To try
  it until the next reboot: `echo 1 > /sys/devices/system/cpu/cpufreq/boost`.
- Compressed RAM (zram) is on by default: half the RAM, LZ4. Size and
  algorithm can be changed in `/storage/.config/rf35h/zram.conf`, with
  `PCT=` (1 to 150, percent of RAM) and `ALGO=` (`lz4`, `lzo-rle` or `zstd`).

### Network

- **Wi-Fi**: *Settings > Wi-Fi*.
- **Access point**: *Settings > Services > Wi-Fi Access Point*. Each console
  gets its own random 12-character password, shown on screen for 10 seconds
  when the access point starts; `rf35h-ap status` shows it over SSH.
- **Samba**: on by default, *Settings > Services > Samba*.

#### SSH

*Settings > Services > SSH*. The login is `root` with Lakka's default password
`root`, on every network the console joins. To use a key instead:

```sh
# on the PC
ssh-copy-id root@<console-ip>
# on the console
echo 'SSH_ARGS="-o PasswordAuthentication=no"' > /storage/.cache/services/sshd.conf
systemctl restart sshd
```

That file is also SSH's on/off switch. Turning SSH off in the menu renames it
to `sshd.disabled` and turning it back on restores it, so the line stays. If
you lock yourself out, delete the line from `.cache/services/sshd.conf` on the
card's second partition, from a PC.

### USB-C port

- **host** (default): gamepads (Xbox, PlayStation, Switch and Steam
  controllers), USB drives, keyboards, USB-C headphones and DACs.
- **transfer**: the console shows up on the PC as a USB network card (RNDIS
  for Windows, ECM for Linux and macOS). It takes 192.168.7.1 and gives the PC
  an address by DHCP; Samba is switched on for the session if it was off. Then
  open `\\lakka.local` or `smb://192.168.7.1`, or `ssh root@192.168.7.1`.

Switch in *Device Settings > USB-C Port*, or `rf35h-usb host|transfer` over
SSH.

### Thumbnails

*Device Settings > Thumbnail Scraper* downloads box art, screenshots and title
screens for every playlist from ScreenScraper, with ArcadeDB as fallback for
arcade games. ScreenScraper needs credentials:

```sh
rf35h-scrape --init    # writes /storage/.config/rf35h/scraper.conf
```

Fill in `DEVID` and `DEVPASSWORD` (ScreenScraper API credentials) and,
optionally, `SSID` and `SSPASSWORD` (your ScreenScraper account, for a higher
daily quota). Selecting *Scrape Thumbnails* again stops a running scrape.

### Bundled extras

**IKEMEN GO**, in the *Contentless Cores* tab.

- After selecting it there are 2 seconds to open the Quick Menu (Select +
  Start) and pick the renderer in the core options: OpenGL ES (default) or
  OpenGL. Then RetroArch closes and IKEMEN starts; leaving IKEMEN's main menu
  brings RetroArch back.
- Game folder: `ROMs/ikemen` (`chars/`, `stages/`, `data/select.def`,
  `save/config.ini`). The official screenpack ships no menu music: put
  `Title.mp3`, `Select.mp3`, `Versus.mp3`, `Winner.mp3` and `Continue.mp3` in
  `ROMs/ikemen/sound/`.
- It runs well below 60 fps on this SoC: the game loop is bound to one CPU
  core. Log: `/storage/rf35h-logs/ikemen.log`.

**GTA: San Andreas**, in *Contentless Cores*.

- Needs the Android release **2.11.311 for arm64-v8a**: the APK (`base.apk`,
  plus `split_config.arm64_v8a.apk` if present) and the OBB
  (`main.*.obb`, plus `patch.*.obb` if present). Other versions are refused.
- Copy them to `ROMs/gtasa`. The first start installs the game (a few
  minutes, about 3 GB free); then the copied files can be deleted from
  `ROMs/gtasa/import/originali`.
- Each start leaves 2 seconds to open the Quick Menu options (frame rate 30 or
  60, render resolution, CPU/GPU governor, swap A/B, FPS counter, statistics);
  more settings in `ROMs/gtasa/gtasa_nx.cfg`.
- In game: Start pauses, Select opens the map, Select + Start held for one
  second quits.
- Saves, settings and logs stay in `ROMs/gtasa`; errors are in
  `last-error.txt` and `gtasa.log`. Over SSH, `rf35h-gtasa slim --yes` removes
  the texture variants this GPU does not use (hundreds of MB).
- Full notes (Italian): `/usr/share/gtasa/LEGGIMI.md` on the console.

**OpenXeenNG** (Might and Magic IV/V).

- *Load Content*, then `XEEN.CC` or `DARK.CC` from your copy (for example the
  GOG release); the other `.CC` files in the same folder are found
  automatically.
- Without game files: *Load Core > OpenXeenNG*, then *Start Core*, runs a
  demo. It is not listed in *Contentless Cores* with RetroArch's default
  filter.

**Deva's Awesome Adventures**, in *Contentless Cores*.

- Educational game for young children, Italian voice.
- Child-proof controls: options, saves and exit open only while L and R are
  held; pause by holding Start.

### Command-line tools

Over SSH, as root. Their messages are in Italian.

| Command | Does |
|---|---|
| `rf35h-diag [--full]` | state of everything the port relies on; `--full` adds raw dumps |
| `rf35h-update run\|check\|status\|cancel` | system update (see [Updating](#updating)) |
| `rf35h-usb [host\|transfer]` | USB-C mode; without an argument, the current one |
| `rf35h-ap on\|off\|status` | Wi-Fi access point; `status` shows its name and password |
| `rf35h-brightness [N\|+N\|-N]` | backlight in %; without an argument, the current value |
| `rf35h-led [mode]` | stick LEDs; without an argument, the current mode and the list |
| `rf35h-statusled [mode]` | red and blue LEDs |
| `rf35h-dac-volume [0-100]` | speaker volume (sound chip level) |
| `rf35h-vibra on\|off\|status` | rumble on or off |
| `rf35h-rumble [ms]` | runs the motor (500 ms by default), to test it |
| `rf35h-zram on\|off\|status` | compressed RAM |
| `rf35h-ntp on\|off\|status`, `rf35h-ntp server <host>` | network time |
| `rf35h-scrape --init`, `rf35h-scrape [--all] [--region eu\|us\|jp\|wor]` | thumbnail scraper |
| `rf35h-bench [boot\|clocks\|zram\|thermal\|audio]` | measurements; `--save` writes them to `/storage` |

## Updating

### From the console

*Settings > Device Settings > System Update*:

1. checks the latest release (pre-releases excluded);
2. downloads its `.tar` to `/storage/.update` in the background, resuming
   after interruptions; selecting the entry again stops the download, and
   once more resumes it;
3. checks size and SHA-256 against the release's `update.txt`;
4. shows *ready*: select the entry again to restart. The update is installed
   during boot, with the progress on screen.

It needs the network, a correct clock (keep *Network Time* on: the download
is HTTPS), 30 % battery or the charger, and free space for twice the `.tar`
plus 100 MB. The same over SSH:

```sh
rf35h-update run       # check and download
rf35h-update check     # exit 0: update available, 1: none, 2: could not check
rf35h-update status    # the status line the menu shows
rf35h-update cancel    # remove a downloaded or partial update
```

`lakka-update` runs `rf35h-update run` on this console.

### Choosing what to install

`/storage/.config/rf35h/update.conf`, one `KEY=value` per line, no comments
on the same line:

| Key | Effect |
|---|---|
| `TAG=v1.2.0` | that release instead of the latest: also a pre-release, or an older one to go back |
| `REPO=owner/repository` | releases of another repository (can be combined with `TAG`) |
| `URL=https://…/update.txt` | that `update.txt`; overrides the other two |

### By hand

Copy the `.tar` to the `Update` share (`/storage/.update`) and restart:

```sh
scp Lakka-RK3326.aarch64-Next-<version>-rf35h.tar root@<console-ip>:/storage/.update/
ssh root@<console-ip> reboot
```

Never install Lakka's own RK3326 updates: they carry a different kernel and
boot loader, and the console would no longer start.

### What an update keeps

Everything in `/storage`. `retroarch.cfg` keeps your values: a new default
for a setting that already exists in your file is not applied.

## Troubleshooting

### Logs

| Where | What |
|---|---|
| `/storage/rf35h-logs/boot.log` (and `boot.1.log` to `boot.5.log`) | full diagnostics at every boot, with `dmesg-boot.log` |
| `/storage/rf35h-logs/shutdown.log` | the same at shutdown, including frequency and thermal history |
| `/storage/rf35h-logs/` | RetroArch crash snapshots, `vulkan-fallback-*.txt`, `ikemen.log` |
| `rf35h-diag` (`--full` for raw dumps) | the state of everything the port relies on |

`/storage` is ext4: a Linux PC reads the logs straight from the card when the
console does not start.

The serial console is **ttyS1** at 1500000 8N1. Never use ttyS2: on this board
it drives the stick LED controller.

### Common problems

| Symptom | What to do |
|---|---|
| Black screen at boot | Read `boot.log` from a PC. If it is missing, boot stopped before the system started: use the serial console. |
| `/storage` stays at about 25 MB | The first-boot expansion did not run. From a PC, card unmounted: `sudo parted -s -f /dev/sdX resizepart 2 100%`, `sudo e2fsck -f -p /dev/sdX2`, `sudo resize2fs /dev/sdX2` (data is kept). |
| Console does not start after an update | `sudo sh tools/rf35h-reflash-system.sh <image>.img.gz /dev/sdX` rewrites partition 1 from an image and removes the failed update; ROMs, saves and settings stay. |
| No network access to the console | `sudo sh tools/rf35h-rescue.sh /dev/sdX "<ssid>" "<password>"` from a PC (details below). |
| Buttons wrong or missing | `cat /proc/bus/input/devices \| grep -A8 retrogame_joypad`: the `B: KEY=` line shows the buttons the driver reports. The mapping is in `autoconfig/retrogame_joypad.cfg`. |
| No Wi-Fi networks | `ls /lib/firmware/rk915_*`, then `dmesg \| grep -i rk915`. |
| Power key does nothing | `cat /proc/bus/input/devices \| grep "rk805 pwrkey"` and `cat /etc/systemd/logind.conf \| grep HandlePowerKey`. |
| L1 + Volume does not change brightness | `systemctl status rf35h-volkeys` |
| Stick LEDs off | `cat /sys/class/leds/joyled-power/brightness` must be `1`; then `rf35h-led blue`. |
| Console hangs on resume | Hold the power key for 5 seconds: it powers off regardless. |

`tools/rf35h-rescue.sh`, run on a PC with the card inserted:

- copies the existing logs to the PC;
- adds the Wi-Fi network as a connman provisioning file, valid whatever the
  console's MAC address, so the console connects at the next boot;
- enables SSH;
- installs a one-shot `/storage/.config/autostart.sh` (replacing yours, if
  any) that saves the journal and a verbose RetroArch run to
  `/storage/rescue/` 45 seconds after boot.

The menu cannot forget a network added this way; once the console is
reachable, remove it over SSH with
`rm /storage/.cache/connman/rf35hrescue.config`.

## Building from source

### Requirements

- x86_64 Linux. An aarch64 host also needs qemu-user, because Rockchip's
  tools are x86 binaries.
- About 100 GB free and a network connection for the whole build.
- Time: about four hours from scratch on a 4-core, 16 GB machine; rebuilds
  are incremental.
- The build scripts print their messages in Italian.

Two ways to build:

| Host | Container build | Native build |
|---|---|---|
| Ubuntu 24.04 | yes | yes: the reference system |
| Debian 12, Debian 13 | yes | the same packages install; not tested (gcc 12 and 14) |
| gcc 15 or newer (`gcc --version`): Arch, CachyOS, Fedora, recent Ubuntu releases | yes | no: the compiler is too recent for LibreELEC's host tools |
| Windows | | in WSL2 with Ubuntu 24.04 |

#### Container build

The container is Ubuntu 24.04 with every build dependency; the host needs
only `git` and Docker or Podman. `build-in-docker.sh` refuses to run as root,
so Docker must work for your user: add yourself to the `docker` group (which
is equivalent to root access on that machine), then log out and back in.

**Ubuntu 24.04 or newer, Debian 13**

```sh
sudo apt-get update
sudo apt-get install -y git docker.io docker-buildx
sudo usermod -aG docker "$USER"
```

**Debian 12** (`docker-buildx` is not packaged; Docker 20.10 builds without
it)

```sh
sudo apt-get update
sudo apt-get install -y git docker.io
sudo usermod -aG docker "$USER"
```

**Arch, CachyOS, Manjaro, EndeavourOS** (with paru, `paru -Syu --needed` and
the same list; nothing comes from the AUR)

```sh
sudo pacman -Syu --needed git docker docker-buildx
sudo systemctl enable --now docker.service
sudo usermod -aG docker "$USER"
```

Use `-Syu`, not `-Sy` alone: installing after refreshing the databases
without upgrading is a partial upgrade, which Arch does not support.

**Fedora**

```sh
sudo dnf install -y git moby-engine docker-buildx
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"
```

After logging back in, `docker run --rm hello-world` must work without
`sudo`.

**Podman** works as well, rootless included, and needs no group: the script
uses it when there is no `docker` command, or when `docker` is Podman's
compatibility wrapper, and runs the container with `--userns=keep-id`, so the
build writes to your folder with your own UID. CI builds with Docker.

| Distribution | Podman instead of Docker |
|---|---|
| Debian, Ubuntu | `sudo apt-get update && sudo apt-get install -y git podman uidmap` |
| Arch, CachyOS, Manjaro, EndeavourOS | `sudo pacman -Syu --needed git podman` |
| Fedora | `sudo dnf install -y git podman` (usually preinstalled) |

Rootless Podman needs subordinate ID ranges for your user. Most
distributions create them with the user; check with
`cat /etc/subuid /etc/subgid | grep "^$USER:"`, and if nothing comes out:

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
podman system migrate
```

#### Native build (Ubuntu 24.04)

The same packages the container installs:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential git wget curl cpio unzip zip rsync bc file \
  bison flex texinfo gawk gperf lzop patchutils rdfind diffutils bzip2 \
  xz-utils zstd xsltproc ca-certificates \
  python3 python3-setuptools libssl-dev libncurses-dev xfonts-utils \
  libjson-perl libparse-yapp-perl libxml-parser-perl perl \
  default-jre-headless ccache u-boot-tools squashfs-tools
```

Beyond LibreELEC's own build dependencies: `u-boot-tools` provides `mkimage`,
needed for the board's `boot.scr`; `squashfs-tools` lets the build check the
finished image; `ccache` speeds up rebuilds. LibreELEC's `scripts/checkdeps`
runs again at the start of every build and offers to install anything still
missing. Build as a normal user: LibreELEC refuses to build as root.

On Windows, follow the same steps in WSL2 with Ubuntu 24.04, with the working
directory in the Linux filesystem (`~/lakka`) rather than under `/mnt/c`.
Write the card from Windows, with balenaEtcher.

### Layout

```text
~/lakka/                 working directory, not your home itself
├── lakka-rf35h/         this repository; keep the folder name
└── lakka-rf35h-build/   the Lakka tree: toolchain, sources, packages, images
```

`build-in-docker.sh` mounts the working directory as `/work` and runs
`./lakka-rf35h/build-lakka-rf35h.sh` there, hence the fixed name.

### Build

```sh
mkdir -p ~/lakka && cd ~/lakka
git clone https://github.com/debianita22/lakka-rf35h.git

./lakka-rf35h/build-in-docker.sh --dry-run   # apply and check everything, no build
./lakka-rf35h/build-in-docker.sh             # full build
```

Natively, run `./lakka-rf35h/build-lakka-rf35h.sh` with the same options from
`~/lakka`. Use `tmux` or `screen`: an interrupted build resumes when the same
command is run again.

`build-in-docker.sh` extras: `--sh 'command'` runs a command in the container
(in `/work`); `--deva` and `--re3` folders are mounted read-only;
`--workdir` must stay relative.

What `build-lakka-rf35h.sh` does:

1. checks the host, the disk space and the boot loader checksum;
2. clones Lakka-LibreELEC `devel` at the pinned commit into
   `lakka-rf35h-build/`;
3. applies the overlay (`apply.sh`) once, and records its signature in
   `lakka-rf35h-build/.rf35h-applied`;
4. checks that every change landed (`tools/verify-claims.sh` and its own
   checks), pre-fetches sources whose upstream copies are gone
   (`seed-sources.sh`) and validates the core names;
5. with `--dry-run`, computes the build plan
   (`lakka-rf35h-build/build-rf35h-plan.txt`) and stops;
6. runs `make image`, logging to `lakka-rf35h-build/build-rf35h-<date>.log`;
7. checks the kernel patches (`verify-kernel.sh`) and the image
   (`tools/verify-image.sh`: boot loader inside `SYSTEM`, device tree, game
   cores).

Output in `lakka-rf35h-build/target/`: the `.img.gz` and the `.tar`, named
`Lakka-RK3326.aarch64-Next-<version>-rf35h`. Without `RF35H_VERSION` the
version is Lakka's `devel-<date>-<commit>`.

### Build options

| Option | Effect |
|---|---|
| `--cores "a b c"` | build only these cores (folder names in `lakka-rf35h-build/packages/lakka/libretro_cores/`) |
| `--all-cores` | all of Lakka's RK3326 cores (about 120); many are too heavy for this SoC |
| `--skip-core NAME` | leave a core out; repeatable, works with `--cores` and `--all-cores` |
| `--keep-going` | when a core or an extra fails, drop it and continue; the list ends up in `build-rf35h-<date>-core-saltati.txt` |
| `--keep-going-max N` | at most N restarts (25) |
| `--no-vulkan` | no Vulkan: Mesa without PanVK, RetroArch without its vulkan driver |
| `--no-ikemen` | without IKEMEN GO |
| `--no-gtasa`, `--no-openxeenng`, `--no-deva-adventures` | without that game |
| `--re3 <dir>`, `--no-re3` | with or without GTA III (re3), from a package you provide (see below) |
| `--kms` | experimental: RetroArch on KMS without sway; currently fails at EGL initialisation |
| `--no-core-lto` | drop the LTO flag the overlay adds to some cores (currently without effect) |
| `--deva <dir>` | another boot loader: a folder with `loader/known-good.bin` and `loader/known-good.sha256` |
| `--overlay <dir or tar.gz>` | the overlay (default: the script's own folder) |
| `--workdir <dir>` | the Lakka tree (default `./lakka-rf35h-build`) |
| `--jobs N` | `make -j` inside each package (2) |
| `--pkg-jobs N` | packages built in parallel (the smaller of CPU count and RAM/2 GB); multiplies with `--jobs` |
| `--skip-deps` | do not run LibreELEC's `checkdeps` |
| `--dry-run` | apply and check, compute the build plan, do not build |
| `--verify-only` | check the last image and the kernel source, build nothing |
| `--no-pin` | use the tip of Lakka `devel` instead of the pinned commit |
| `--help` | every option, in Italian |

re3 has no license: its package is not in this repository, an image that
contains it is for personal use only, and releases never include it. On a
console running such an image, System Update first copies re3 to `/storage`,
so it survives an update to a release.

Environment variables:

| Variable | Effect |
|---|---|
| `RF35H_VERSION` | image version: file names and `VERSION` in `/etc/os-release` (letters, digits, `. _ + -`) |
| `RF35H_UPDATE_REPO` | `owner/repository` whose releases the console updates from (default `debianita22/lakka-rf35h`) |
| `RF35H_ALL_CORES=1` | with `--all-cores`, also try `lr_moonlight` and `vitaquake3`, which Lakka excludes everywhere |
| `RF35H_LTO_CORES` | the cores that get the LTO flag (currently without effect, like `--no-core-lto`) |
| `DEVA_ADVENTURES_SRC` | build Deva's Awesome Adventures from a local source tree |
| `RE3_PGO` | profile-guided optimisation for re3: `generate`, or a profile folder |

The container passes on only `RF35H_VERSION`, `RF35H_UPDATE_REPO` and
`RE3_PGO` (plus `AUTOREMOVE` and two ccache settings used by CI); the others
work in native builds.

### Updating the overlay

```sh
cd ~/lakka/lakka-rf35h && git pull && cd ..
./lakka-rf35h/build-in-docker.sh
```

If the files the overlay puts into the Lakka tree changed, the build stops
with `overlay disallineato` and prints three commands that reset the tree
while keeping sources, built packages and logs. Run them, then the build
again: only what changed is rebuilt.

LibreELEC decides what to rebuild from each package's own files, not from its
dependencies or the device options: after changes to the kernel or to the
options, some packages may not be rebuilt. Only a build from scratch proves
the tree builds, which is why CI always starts from scratch.

### When the build fails

| Problem | What to do |
|---|---|
| `Cannot get <package> sources` | `./lakka-rf35h/check-sources.sh lakka-rf35h-build` tests every source URL and its mirror and lists the dead ones; add them to `seed-sources.sh` (the Ubuntu pool keeps old tarballs). |
| A core or an extra does not compile | `--keep-going`, or `--skip-core` / `--no-...`. |
| A system package fails | The build stops; its own log is copied to `build-rf35h-<date>-<package>-fallito.log`. |
| Host compiler errors on a rolling distribution | Build in the container. |
| Slow build under WSL | Keep the working directory inside the Linux filesystem, not under `/mnt/c`. |

Check only, without building: `--verify-only`.

## Releases and CI

Workflows in [`.github/workflows`](../.github/workflows):

| Workflow | Runs on | Does |
|---|---|---|
| Check (`check.yml`) | push to `main`, pull requests, manual | `tools/ci-check.sh` (shellcheck, actionlint, Python syntax, patch hunk counts, `tools/test-*.sh`) and a dry run on the pinned Lakka commit |
| Build (`build.yml`) | tag `v*`, *Run workflow*, push to `ci-test/**` | the full image in the same Ubuntu 24.04 container, in up to four jobs of at most 6 hours each |

- **Release**: `git tag v1.0.0 && git push origin v1.0.0`, or *Run workflow*
  with a version (the tag is created at the end; from a branch other than the
  default one, only as a pre-release).
- **Pre-release**: tags with a dash (`v1.1.0-rc1`) or *Run workflow* with
  *prerelease*. Consoles ignore pre-releases unless `update.conf` names them.
- **Test build**: *Run workflow* without a version, or a push to a
  `ci-test/...` branch. The image stays in the run's artifacts for 14 days.
- **Resume**: *Run workflow* with `resume_run` set to the ID of a failed test
  build restarts from its saved state (kept 3 days) and rebuilds only the
  changed packages. Test builds only: the image mixes packages from two
  commits.

A release contains the `.img.gz`, the `.tar`, `update.txt` (version, file
name, URL, SHA-256 and size of the `.tar`) and `SHA256SUMS`. Before
publishing, CI checks that re3 is not in the image.

In a fork, CI sets `RF35H_UPDATE_REPO` to the fork, so its images update from
the fork's own releases.

## Porting to another RK3326 handheld

Release images carry one device tree and one boot loader, both for the RF35H.
Another handheld needs its own build. This section maps what is
device-specific; it is not a turnkey procedure, so keep a serial console at
hand.

### What is device-specific

| Piece | On the RF35H | In this repository |
|---|---|---|
| Boot loader | AURKNIX RK3326 loader, U-Boot 2025.10 | `board/loader/` (`--deva <dir>` for another) |
| Device tree | `rk3326-xifan-rf35h.dts`, built on AURKNIX's `rk3326-xifan-xf35h.dts` | `patches/linux/z-010-add-rf35h-dts.patch` |
| Board entry | `'rf35h'`: DTB, `odroidgoa_defconfig`, legacy Rockchip boot | `uboot_helper` snippet in `apply.sh` |
| Board name | `UBOOT_SYSTEM=rf35h` | `build-lakka-rf35h.sh` (`build_env`, `find_image`), `integration/*.patch` |
| Panel | ROCKNIX generic DSI driver, panel described in the device tree | `patches/linux/z-002-panel-generic-dsi.patch` |
| Controls | `rocknix-singleadc-joypad` (sticks multiplexed on one ADC channel) | `packages/rocknix-joypad/`, `autoconfig/retrogame_joypad.cfg` |
| Volume keys and brightness | `adc-keys` on SARADC, L1 as modifier | `packages/rf35h-utils/system.d/rf35h-volkeys.service` |
| Wi-Fi | RK915 on SDIO, out-of-tree driver | `packages/rk915/`, `patches/linux/r-024-*.patch` |
| Audio | RK817 codec, `simple-audio-card` | device tree, `integration/kconfig-audio-aurknix-rf35h.patch` |
| Power key | RK817 PMIC key (`rk805 pwrkey`) | `integration/kconfig-pwrkey-rf35h.patch`, `integration/logind-powerkey-rf35h.patch` |
| LEDs | stick LED controller on UART2 (`ttyS2`), red and blue GPIO LEDs | `rf35h-led`, `rf35h-statusled`, `rf35h-ledd` in `packages/rf35h-utils/` |
| Serial console | `ttyS1`, 1500000 baud | `EXTRA_CMDLINE` in `integration/options-rf35h.patch` |
| Device Settings menu | shown only when `/usr/bin/rf35h-led` exists | `patches/retroarch/retroarch-1003-rf35h-settings-menu.patch` |

### Steps

1. **Reference system.** Keep a card with an OS that already runs on the
   device (AURKNIX, ROCKNIX, ArkOS or the vendor's): it provides the device
   tree, the boot loader and register values to compare against.
2. **Boot loader.** The bundled loader comes from AURKNIX's RK3326 image,
   which AURKNIX boots on many RK3326 handhelds: try it first. Otherwise
   capture the loader from a card that boots the device:

   ```sh
   dd if=/dev/sdX of=known-good.bin bs=32768 skip=1 count=511
   sha256sum known-good.bin > known-good.sha256
   ```

   Put both files in `<dir>/loader/` and build with `--deva <dir>`. The loader
   also initialises the RAM: a loader made for another board may show nothing
   at all. The image boots through `boot.scr`, so the loader's U-Boot must run
   it, as AURKNIX's U-Boot 2025.10 does; a U-Boot that only reads `boot.ini`
   will not start it.
3. **Device tree.** Add the board's DTS, with its line in
   `arch/arm64/boot/dts/rockchip/Makefile`, as a patch in `patches/linux/`
   named `z-NNN-*.patch`: `apply.sh` keeps only `r-*` and `z-*` patches plus
   two of Lakka's. Add a board entry for its DTB to the `uboot_helper` snippet
   in `apply.sh`.
4. **Board name.** Give the board its own `UBOOT_SYSTEM` and extend the
   `UBOOT_SYSTEM = rf35h` conditions it needs: `integration/options-rf35h.patch`,
   `options-vulkan-ikemen-rf35h.patch`, `release-rf35h.patch`,
   `bootloader-install-rf35h.patch`, `mkimage-rf35h.patch`,
   `logind-powerkey-rf35h.patch`, `odroidgo2-utils-rf35h.patch`,
   `retroarch-no-go2-rf35h.patch`, `wlroots-no-vulkan-rf35h.patch`;
   `build_env` and `find_image` in `build-lakka-rf35h.sh`; the image lookup
   in `tools/ci-build.sh` for CI. The checks in `build-lakka-rf35h.sh`,
   `tools/verify-claims.sh`, `verify-kernel.sh` and `tools/verify-image.sh`
   assert RF35H specifics (strings in `z-010`, the `rk3326-xifan-rf35h.dtb`
   name, the `rf35h` branches): adapt them too.
5. **Drivers.** The Wi-Fi package is for the RK915; another chip needs its
   own driver and firmware. The `rocknix-joypad` package builds only the
   single-ADC variant on RK3326 (its patch `0001`). The generic DSI driver
   handles panels described the ROCKNIX way.
6. **Controls.** Write an autoconfig for the board; the comments in
   `autoconfig/retrogame_joypad.cfg` explain how RetroArch numbers the
   buttons. RetroArch matches it on the joypad name, vendor and product set
   in the device tree (`retrogame_joypad`, `0x484B:0x1101` here): if your
   device tree uses the same identity, as ROCKNIX-derived ones often do,
   replace the file instead of adding a second one.
7. **Userspace.** `rf35h-utils` assumes RF35H hardware: the LED controller on
   `ttyS2`, volume keys on `adc-keys`, the RK915 loader. Keep what applies,
   remove the rest from the board's `ADDITIONAL_PACKAGES`, and check what a
   UART is connected to before writing to it.
8. **Updates.** Build with `RF35H_UPDATE_REPO=<owner>/<repository>` (CI does
   it automatically in a fork), or the console's updater would install RF35H
   releases.
9. **Debugging.**
   - Find the board's debug UART: on the RF35H the console is on `ttyS1`
     because UART2 drives the LED controller.
   - `rf35h-diag --full` and `/storage/rf35h-logs/boot.log`, readable from a
     PC.
   - `hwdump.sh` dumps GPIO, GRF and PMIC registers: run it on Lakka and on
     the reference system, then `diff` the two files.
   - `tools/arkos-collect.sh` records audio and rumble state on ArkOS for the
     same comparison.

The kernel patch set is trimmed to what the RF35H needs: `apply.sh` drops
Lakka's patches for the ODROID-GO, Anbernic and GameForce boards. Those boards
are not built or tested from this tree; if yours needs one of those patches,
port it to 7.2 and add it to the keep list in `apply.sh`.

## Repository layout

| Path | Contents |
|---|---|
| `build-lakka-rf35h.sh` | the build script |
| `build-in-docker.sh` | the same build in an Ubuntu 24.04 container |
| `apply.sh` | applies the overlay to a Lakka tree (called by the build script) |
| `flash-sd.sh` | writes an image to a microSD card |
| `board/loader/` | boot loader and its checksum |
| `patches/linux/`, `patches/linux-default/` | kernel patches: device tree, panel, Wi-Fi, suspend |
| `patches/retroarch/` | RetroArch patches: Device Settings menu and fixes |
| `integration/` | patches to the Lakka tree: options, kernel configuration, boot, packages |
| `packages/` | device packages: drivers, `rf35h-utils`, `wpa_supplicant`, IKEMEN GO and the bundled games |
| `autoconfig/` | RetroArch autoconfig for the built-in controls |
| `optional/` | patches not applied by default |
| `check-sources.sh`, `seed-sources.sh` | find and pre-fetch sources whose upstream copies are gone |
| `verify-kernel.sh` | checks that the kernel patches landed in the source |
| `verify-tarball.sh` | tells whether a tarball with a changed checksum still matches its git tag |
| `hwdump.sh` | GPIO, GRF and PMIC register dump, for comparison with another OS |
| `tools/` | verification, CI, rescue and diagnostic scripts; generators of the RetroArch patches |
| `docs/diario.md` | development log (Italian) |
