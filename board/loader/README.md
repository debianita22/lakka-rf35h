# board/loader: the boot loader the RF35H is known to boot with

`known-good.bin` is bytes 32 KiB to 16 MiB of the official AURKNIX-RK3326
20260809 SD card image, unmodified: idbloader (Rockchip's DDR init, rewritten
by AURKNIX to bring the RAM up at 786 MHz instead of 333, plus the
miniloader), `uboot.img` (U-Boot 2025.10) and `trust.img` (BL31), in
Rockchip's legacy layout. A U-Boot built from the same source and defconfig
still came out about 2 KB different (toolchain), and a loader that does not
start shows nothing at all, so the image takes this one as it is.

Where it goes:

- `apply.sh` copies it into the Lakka tree;
- the image writes it raw to the card at 32 KiB;
- it is also in the SYSTEM as `usr/share/bootloader/u-boot-rockchip.bin`,
  because `bootloader/update.sh` rewrites the loader from there on every
  `.tar` update: anything else there makes the device unbootable after an
  update. `tools/verify-image.sh` checks that it is this file.

`known-good.sha256` is checked by `apply.sh` and `build-lakka-rf35h.sh`
before anything is touched. sha256
`52850532f1e1ab8bd96d8557533d6cffe72c0ec920b55eb8cdb2eb1b4de71321`,
16,744,448 bytes: the same file as devaOS's `boards/rf35h/loader/`.

Another loader: `build-lakka-rf35h.sh --deva <folder>`, where the folder
holds `loader/known-good.bin` and `loader/known-good.sha256`. To capture one
from a card that boots:

    dd if=/dev/sdX of=known-good.bin bs=32768 skip=1 count=511
    sha256sum known-good.bin > known-good.sha256

## Licenses

U-Boot is GPL-2.0-or-later; this binary is AURKNIX's build of it, and its
corresponding source is the AURKNIX distribution
(https://github.com/lcdyk0517/distribution_aurknix, U-Boot 2025.10 with its
RK3326 patches). The DDR init, miniloader and BL31 are Rockchip binaries from
rkbin, redistributed under Rockchip's license as every RK3326 distribution
does.
