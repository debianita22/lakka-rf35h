#!/bin/sh
# rf35h-reflash-system.sh - riscrive SOLO la partizione 1 (/flash: KERNEL,
# SYSTEM, DTB, extlinux) da un'immagine, lasciando intatta la partizione 2
# (/storage: ROM, salvataggi, configurazioni).
#
#   sudo sh rf35h-reflash-system.sh <immagine.img.gz> /dev/sdX
#
# Quando serve: un aggiornamento via /storage/.update interrotto a meta' lascia
# KERNEL o SYSTEM scritti solo in parte e il device non riparte. La partizione 2
# non c'entra nulla: si rifa' la 1 e basta.
#
# Cosa NON tocca:
#   - la partizione 2 (/storage). Mai. C'e' un controllo esplicito.
#   - il bootloader raw a 32K (u-boot/idbloader): resta il known-good scritto
#     al primo flash. L'aggiornamento LibreELEC non lo tocca, e nemmeno noi.
#
# Cosa fa in piu': svuota /storage/.update sulla card. Se il .tar fallito
# restasse li', l'init lo riproverebbe al boot successivo e rifallirebbe -
# l'init lo cancella solo a fine corsa riuscita.
set -u

if [ $# -ne 2 ]; then
	echo "uso: sudo $0 <immagine.img.gz|.img> /dev/sdX" >&2
	exit 1
fi
IMG="$1"; DEV="$2"
[ "$(id -u)" = 0 ] || { echo "serve root (sudo)" >&2; exit 1; }
[ -f "${IMG}" ]    || { echo "immagine non trovata: ${IMG}" >&2; exit 1; }
[ -b "${DEV}" ]    || { echo "${DEV} non risulta un device a blocchi" >&2; exit 1; }
for t in losetup parted blockdev dd; do
	command -v "$t" >/dev/null 2>&1 || { echo "manca ${t}" >&2; exit 1; }
done

if [ -b "${DEV}p1" ]; then CP1="${DEV}p1"; CP2="${DEV}p2"; else CP1="${DEV}1"; CP2="${DEV}2"; fi
[ -b "${CP1}" ] && [ -b "${CP2}" ] || { echo "servono due partizioni su ${DEV} (trovate: $(ls ${DEV}* 2>/dev/null | tr '\n' ' '))" >&2; exit 1; }

echo "[1/6] smonto tutto e controllo la card"
for p in "${DEV}"*; do [ "$p" = "${DEV}" ] || umount "$p" 2>/dev/null; done
udevadm settle 2>/dev/null || true
if grep -q "^${DEV}" /proc/mounts 2>/dev/null; then
	echo "  ${DEV} ha ancora partizioni montate: chiudi il file manager e rilancia" >&2
	exit 1
fi
# la p2 deve essere ext4 e contenere qualcosa: e' la prova che e' la card giusta
M2="$(mktemp -d)"
if mount -t ext4 "${CP2}" "${M2}" 2>/dev/null; then
	echo "  /storage: $(df -h "${M2}" | tail -1 | awk '{print $2" totali, "$3" usati"}')"
	[ -d "${M2}/roms" ] && echo "  roms/: $(find "${M2}/roms" -type f 2>/dev/null | wc -l) file - NON verranno toccati"
	echo "[2/6] svuoto /storage/.update (il .tar fallito verrebbe riprovato al boot)"
	if [ -d "${M2}/.update" ]; then
		ls -la "${M2}/.update" 2>/dev/null | tail -n +4 | awk '{print "  rimuovo: "$NF" ("$5" byte)"}'
		rm -rf "${M2}"/.update/* "${M2}"/.update/.[!.]* 2>/dev/null
	else
		echo "  (gia' vuota)"
	fi
	sync; umount "${M2}"
else
	echo "  ATTENZIONE: non riesco a montare ${CP2} come ext4." >&2
	echo "  Se questa non e' la card del device, FERMATI ora (Ctrl-C)." >&2
	echo "  Proseguo fra 10 s..." >&2
	sleep 10
fi
rmdir "${M2}" 2>/dev/null

echo "[3/6] apro l'immagine"
TMPIMG=""
case "${IMG}" in
	*.gz) TMPIMG="$(mktemp --suffix=.img)"; echo "  decomprimo..."; zcat "${IMG}" > "${TMPIMG}"; SRC="${TMPIMG}" ;;
	*)    SRC="${IMG}" ;;
esac
LOOP="$(losetup -f --show -P "${SRC}")" || { echo "losetup fallito" >&2; rm -f "${TMPIMG}"; exit 1; }
partprobe "${LOOP}" >/dev/null 2>&1 || true
sleep 1
IP1="${LOOP}p1"
[ -b "${IP1}" ] || { echo "l'immagine non espone ${IP1}" >&2; losetup -d "${LOOP}"; rm -f "${TMPIMG}"; exit 1; }

echo "[4/6] confronto le dimensioni"
SZ_IMG="$(blockdev --getsize64 "${IP1}")"
SZ_CARD="$(blockdev --getsize64 "${CP1}")"
echo "  partizione 1 dell'immagine: $((SZ_IMG / 1024 / 1024)) MB"
echo "  partizione 1 della card:    $((SZ_CARD / 1024 / 1024)) MB"
if [ "${SZ_IMG}" -gt "${SZ_CARD}" ]; then
	echo "  La partizione 1 della card e' piu' piccola di quella dell'immagine." >&2
	echo "  Riscriverla troncherebbe il filesystem: serve una scrittura completa" >&2
	echo "  con flash-sd.sh (e in quel caso /storage va salvata prima)." >&2
	losetup -d "${LOOP}"; rm -f "${TMPIMG}"; exit 1
fi

echo "[5/6] scrivo la partizione 1 (la 2 non viene toccata)"
dd if="${IP1}" of="${CP1}" bs=4M conv=fsync status=progress
sync
losetup -d "${LOOP}"; rm -f "${TMPIMG}"

echo "[6/6] verifico"
if command -v fsck.fat >/dev/null 2>&1; then
	fsck.fat -n "${CP1}" >/dev/null 2>&1 && echo "  ${CP1} (FAT): pulita" || echo "  ${CP1}: fsck.fat NON pulita" >&2
fi
M1="$(mktemp -d)"
if mount -t vfat "${CP1}" "${M1}" 2>/dev/null; then
	for f in KERNEL SYSTEM; do
		[ -f "${M1}/${f}" ] && echo "  ${f}: $(du -h "${M1}/${f}" | cut -f1)" || echo "  ${f}: MANCANTE" >&2
	done
	ls "${M1}"/*.dtb >/dev/null 2>&1 && echo "  dtb: $(basename "$(ls "${M1}"/*.dtb | head -1)")"
	umount "${M1}"
else
	echo "  (non posso montare vfat per verificare: fsck sopra e' l'indicazione buona)"
fi
rmdir "${M1}" 2>/dev/null
sync
echo
echo "Fatto. /storage non e' stata toccata. Rimetti la card e accendi."
