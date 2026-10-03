#!/bin/sh
# verify-image.sh - controlla che un'immagine COSTRUITA contenga cio' che ci
# aspettiamo, prima di scriverla sulla card.
#
#   sh verify-image.sh <Lakka-*.tar|Lakka-*.img.gz> <.../boards/rf35h>
#   sh verify-image.sh --tree <build.*/image/system>  <.../boards/rf35h>
#
# Nasce da un problema reale: durante il porting e' capitato piu' volte di
# correggere qualcosa, ricompilare, e scoprire sul device che nel SYSTEM c'era
# ancora la versione vecchia, senza modo di accorgersene prima di flashare.
#
# Il controllo piu' importante e' il primo. bootloader/update.sh, applicando un
# aggiornamento, fa
#     dd if=${SYSTEM_ROOT}/usr/share/bootloader/u-boot-rockchip.bin \
#        of=${BOOT_DISK} bs=32k seek=1
# cioe' riscrive il loader a 32K con quello che trova nel SYSTEM. Se li' dentro
# non c'e' il known-good, un aggiornamento .tar rende il device non avviabile.
#
# RF35H_GAMES="gtasa re3 openxeenng deva_adventures" (anche vuota) dice quali
# giochi devono esserci: ognuno che manca e' un NO. La mette
# build-lakka-rf35h.sh a fine build, quando sa quali giochi ha costruito. Senza,
# i giochi trovati si elencano e basta. RF35H_VERSION (la CI), se c'e', deve
# essere la VERSION di /etc/os-release.
#
# Le due modalita' NON si sostituiscono a vicenda: --tree guarda lo stato
# attuale dell'albero di build, che dopo una ricompilazione non dice piu' nulla
# su un'immagine gia' costruita. Senza un lettore squashfs lo script si rifiuta
# di controllare il .tar, invece di guardare l'albero e dire "conforme"
# parlando di un'altra cosa.
set -u

usage() {
	echo "uso:" >&2
	echo "  sh verify-image.sh <Lakka-*.tar|Lakka-*.img.gz> <.../boards/rf35h>" >&2
	echo "  sh verify-image.sh --tree <build.*/image/system>  <.../boards/rf35h>" >&2
	exit 1
}

IMG=""; USE_TREE=""; READER=""
if [ "${1:-}" = "--tree" ]; then
	[ $# -eq 3 ] || usage
	USE_TREE="$2"; BOARD="$3"
	[ -d "${USE_TREE}" ] || { echo "non trovo la cartella ${USE_TREE}" >&2; exit 1; }
else
	[ $# -eq 2 ] || usage
	IMG="$1"; BOARD="$2"
	[ -f "${IMG}" ] || { echo "non trovo ${IMG}" >&2; exit 1; }
	if command -v unsquashfs >/dev/null 2>&1; then
		READER="unsquashfs"
	elif command -v 7z >/dev/null 2>&1; then
		READER="7z"
	else
		echo "Per leggere $(basename "${IMG}") serve un lettore squashfs:" >&2
		echo "  Debian/Ubuntu:  sudo apt install squashfs-tools" >&2
		echo "  Fedora:         sudo dnf install squashfs-tools" >&2
		echo "  Arch:           sudo pacman -S squashfs-tools" >&2
		echo >&2
		echo "Non guardo l'albero di build al posto suo: e' un'altra cosa, e dopo" >&2
		echo "una ricompilazione non direbbe nulla su questo file. Se vuoi proprio" >&2
		echo "l'albero:  sh verify-image.sh --tree <build.*/image/system> <board>" >&2
		exit 2
	fi
fi
[ -d "${BOARD}" ] || { echo "non trovo la cartella ${BOARD}" >&2; exit 1; }

KNOWN="${BOARD}/loader/known-good.bin"
[ -f "${KNOWN}" ] || { echo "non trovo il loader known-good: ${KNOWN}" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
fail=0
ok()  { printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { printf '  \033[31mNO\033[0m   %s\n' "$1"; fail=1; }

if [ -n "${USE_TREE}" ]; then
	echo "Controllo l'ALBERO DI BUILD, non un'immagine:"
	echo "  ${USE_TREE}"
	echo "  vale per cio' che verrebbe costruito ORA."
	S="${USE_TREE}"
else
	echo "Controllo $(basename "${IMG}")"
	case "${IMG}" in
	*.tar)
		tar -xf "${IMG}" -C "${T}" 2>/dev/null || { echo "  tar illeggibile" >&2; exit 1; }
		SYS="$(find "${T}" -name SYSTEM -type f | head -1)"
		;;
	*.img.gz|*.img)
		case "${IMG}" in
		*.gz) zcat "${IMG}" > "${T}/disk.img" ;;
		*)    cp "${IMG}" "${T}/disk.img" ;;
		esac
		LOOP="$(losetup -f --show -P "${T}/disk.img" 2>/dev/null)" \
			|| { echo "  losetup fallito (per un .img serve sudo)" >&2; exit 1; }
		mkdir -p "${T}/p1"
		if mount -o ro "${LOOP}p1" "${T}/p1" 2>/dev/null; then
			cp "${T}/p1/SYSTEM" "${T}/SYSTEM" 2>/dev/null
			umount "${T}/p1"
		fi
		losetup -d "${LOOP}" 2>/dev/null
		SYS="${T}/SYSTEM"
		;;
	*)
		echo "  formato non riconosciuto: serve .tar o .img.gz" >&2; exit 1 ;;
	esac
	[ -n "${SYS:-}" ] && [ -f "${SYS}" ] || { echo "  SYSTEM non trovato dentro l'immagine" >&2; exit 1; }
	echo "  SYSTEM: $(du -h "${SYS}" | cut -f1)"

	if [ "${READER}" = 7z ]; then
		7z x -y -o"${T}/sq" "${SYS}" >/dev/null 2>&1 || true
	else
		unsquashfs -n -f -d "${T}/sq" "${SYS}" \
			'usr/share/bootloader' \
			'usr/lib/systemd/system/systemd-timesyncd.service.d' \
			'usr/lib/systemd/system/retroarch.service.d' \
			'usr/bin' \
			'usr/share/rf35h/update-repo' \
			'etc/os-release' \
			'usr/lib/libretro/gtasa_libretro.so' \
			'usr/lib/libretro/re3_libretro.so' \
			'usr/lib/libretro/openxeenng_libretro.so' \
			'usr/lib/libretro/deva_adventures_libretro.so' >/dev/null 2>&1 || true
	fi
	[ -d "${T}/sq" ] || { echo "  non sono riuscito ad aprire il SYSTEM" >&2; exit 1; }
	S="${T}/sq"
fi

echo "controlli"

# 1. il loader nel SYSTEM: l'unico che puo' rendere il device non avviabile
UB="${S}/usr/share/bootloader/u-boot-rockchip.bin"
if [ ! -f "${UB}" ]; then
	bad "u-boot-rockchip.bin assente: update.sh non riscrivera' il loader"
elif [ "$(sha256sum "${UB}" | cut -d' ' -f1)" = "$(sha256sum "${KNOWN}" | cut -d' ' -f1)" ]; then
	ok "loader identico al known-good: un aggiornamento .tar non puo' rompere il boot"
else
	bad "loader DIVERSO dal known-good ($(du -h "${UB}" | cut -f1) contro $(du -h "${KNOWN}" | cut -f1)): un aggiornamento .tar rende il device non avviabile"
fi

# 2. il device tree, che update.sh copia in /flash
if [ -f "${S}/usr/share/bootloader/rk3326-xifan-rf35h.dtb" ]; then
	ok "device tree presente (update.sh lo copiera' in /flash)"
else
	bad "device tree assente: un aggiornamento lascerebbe in /flash quello vecchio"
fi

# 3. il drop-in timesyncd non deve ordinare dopo la rete
TS="${S}/usr/lib/systemd/system/systemd-timesyncd.service.d/rf35h-timesyncd.conf"
if [ ! -f "${TS}" ]; then
	bad "drop-in timesyncd assente"
elif grep -qE "^(After|Wants|Requires)=.*(network|multi-user|graphical)" "${TS}"; then
	bad "drop-in timesyncd ordina dopo la rete: ciclo, D-Bus cancellato, Wi-Fi morto"
else
	ok "drop-in timesyncd senza ordinamenti verso la rete"
fi

# 4. il crash logger agganciato a retroarch
if [ -f "${S}/usr/lib/systemd/system/retroarch.service.d/rf35h-crashlog.conf" ]; then
	ok "drop-in OnFailure su retroarch.service presente"
else
	bad "drop-in OnFailure assente: un crash di RetroArch non lascerebbe log"
fi

# 5. i nostri script
n="$(find "${S}/usr/bin" -name 'rf35h-*' 2>/dev/null | wc -l)"
if [ "${n}" -ge 14 ]; then
	ok "script rf35h-* presenti: ${n}"
else
	bad "solo ${n} script rf35h-* (attesi almeno 14): il pacchetto non si e' ricostruito"
fi

# 6. i giochi: un core atteso che manca vuol dire un'immagine vecchia (di prima
# dei giochi) o costruita senza quel gioco
LR="${S}/usr/lib/libretro"
if [ -n "${RF35H_GAMES+x}" ]; then
	for g in ${RF35H_GAMES}; do
		if [ -f "${LR}/${g}_libretro.so" ]; then
			ok "gioco ${g}: ${g}_libretro.so presente"
		else
			bad "gioco ${g}: ${g}_libretro.so assente (immagine vecchia o costruita senza ${g})"
		fi
	done
	[ -n "${RF35H_GAMES}" ] || ok "nessun gioco atteso (tutti esclusi alla build)"
else
	found=""
	for g in gtasa re3 openxeenng deva_adventures; do
		[ -f "${LR}/${g}_libretro.so" ] && found="${found} ${g}"
	done
	printf '  --   giochi nell'"'"'immagine:%s\n' "${found:- nessuno}"
fi

# 7. gli aggiornamenti dalle release: rf35h-update deve sapere da quale
# repository, e la versione in os-release e' quella che confronta. Con
# RF35H_VERSION (la CI) deve essere proprio quella.
if [ -f "${S}/usr/bin/rf35h-update" ]; then
	repo="$(cat "${S}/usr/share/rf35h/update-repo" 2>/dev/null)"
	ver="$(sed -n 's/^VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "${S}/etc/os-release" 2>/dev/null | head -1)"
	if [ -n "${repo}" ]; then
		ok "aggiornamenti: rf35h-update dalle release di ${repo}, versione ${ver:-?}"
	else
		bad "rf35h-update senza repository (usr/share/rf35h/update-repo)"
	fi
	if [ -n "${RF35H_VERSION:-}" ] && [ "${ver}" != "${RF35H_VERSION}" ]; then
		bad "versione in os-release ${ver:-assente}, attesa ${RF35H_VERSION}: gli aggiornamenti la confronterebbero male"
	fi
fi

echo
if [ -n "${USE_TREE}" ]; then
	subj="albero di build"
else
	subj="$(basename "${IMG}")"
fi
if [ "${fail}" = 0 ]; then
	echo "Conforme: ${subj}"
else
	echo "NON conforme: ${subj} - vedi le righe NO qui sopra." >&2
fi
exit "${fail}"
