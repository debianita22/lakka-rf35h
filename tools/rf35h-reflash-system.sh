#!/bin/sh
# rf35h-reflash-system.sh - rimette in piedi una card senza toccare /storage.
#
#   sudo sh tools/rf35h-reflash-system.sh <immagine.img.gz|.img> /dev/sdX
#   sudo sh tools/rf35h-reflash-system.sh --loader /dev/sdX
#
# Con un'immagine riscrive SOLO la partizione 1 (/flash: KERNEL, SYSTEM,
# device tree, extlinux.conf, boot.scr) e svuota /storage/.update; la
# partizione 2 (/storage: ROM, salvataggi, configurazioni) resta com'e'. Serve
# quando un aggiornamento interrotto a meta' lascia KERNEL o SYSTEM scritti
# solo in parte e la console non riparte. Un aggiornamento rimasto in
# /storage/.update l'init lo riproverebbe all'avvio dopo.
#
# L'immagine puo' venire da un'altra build, anche piu' nuova di quella con cui
# e' stata scritta la card. Ogni build ha il suo UUID di /storage
# (scripts/image: UUID_STORAGE="$(uuidgen)"), che scripts/mkimage scrive in
# extlinux.conf come disk=UUID=...; la partizione 2 della card ha invece
# quello dell'immagine del primo flash (fs-resize lo conserva). Con l'UUID
# dell'immagine l'init non trova /storage e la console si ferma. Qui
# extlinux.conf prende l'UUID vero della partizione 2 PRIMA che la card venga
# toccata, e se non si puo' la card resta com'e'. boot=UUID e' il numero di
# serie della FAT dell'immagine, che arriva con lei; boot.scr non ha UUID (fa
# sysboot su extlinux.conf): se un giorno ne avesse, ci si ferma.
#
# --loader riscrive SOLO il boot loader: board/loader/known-good.bin
# (idbloader, U-Boot e trust di AURKNIX), raw da 32 KiB a 16 MiB come lo
# scrivono scripts/mkimage e bootloader/update.sh (dd bs=32k seek=1), dopo
# averne controllato lo sha256 e che la partizione 1 cominci dopo. Serve
# quando un aggiornamento o un'immagine di Lakka per RK3326 generico ha
# scritto il suo loader e la console non mostra piu' niente. Se ha installato
# anche il suo KERNEL e il suo SYSTEM, dopo --loader serve la prima forma, con
# un'immagine di questo port.
#
# I controlli sul disco sono in rf35h-card.sh: quelli di flash-sd.sh (disco
# intero, rimovibile, al massimo 512 GB, FORCE=yes per forzare) e le etichette
# di una card Lakka (LAKKA e LAKKA_DISK).
#
# Serve: util-linux (blkid, blockdev), coreutils (dd, od, stat, sha256sum,
# md5sum), gzip, mtools (mtype, mcopy, mdir: la FAT si legge e si scrive senza
# montarla). La copia di lavoro della partizione 1 (3 GB, sparsa: occupa
# quanto KERNEL e SYSTEM) va in $TMPDIR, altrimenti in /var/tmp.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "${HERE}/rf35h-card.sh" ] || { echo "manca ${HERE}/rf35h-card.sh" >&2; exit 1; }
# shellcheck source=tools/rf35h-card.sh
. "${HERE}/rf35h-card.sh"
LOADER="${HERE}/../board/loader/known-good.bin"
LOADER_SUM="${HERE}/../board/loader/known-good.sha256"
# niente controlli di geometria di mtools: sono partizioni e file, non dischetti
export MTOOLS_SKIP_CHECK=1

die() { echo "$*" >&2; exit 1; }
need() {
	for _t in "$@"; do command -v "${_t}" >/dev/null 2>&1 || die "manca ${_t} sul PC"; done
}
usage() {
	echo "uso: sudo $0 <immagine.img.gz|.img> /dev/sdX   (solo la partizione 1)" >&2
	echo "     sudo $0 --loader /dev/sdX                  (solo il boot loader)" >&2
	exit 1
}

[ $# -eq 2 ] || usage
DEV="$2"
[ "$(id -u)" = 0 ] || die "serve root (sudo)"

# sha256 dei primi $1 blocchi da 32 KiB dopo i primi 32 KiB della card
card_loader_sum() {
	dd if="${DEV}" bs=32768 skip=1 count="$1" 2>/dev/null | sha256sum | cut -d' ' -f1
}

# --- solo il loader ----------------------------------------------------------
if [ "$1" = --loader ]; then
	need dd od sha256sum blkid blockdev
	[ -f "${LOADER}" ] && [ -f "${LOADER_SUM}" ] || die "manca ${LOADER} o ${LOADER_SUM}"
	echo "[1/4] controllo il loader known-good"
	( cd "$(dirname "${LOADER}")" && sha256sum -c --quiet known-good.sha256 ) \
		|| die "known-good.bin non corrisponde al suo sha256: non lo scrivo"
	WANT="$(cut -d' ' -f1 < "${LOADER_SUM}")"
	LSZ="$(wc -c < "${LOADER}")"
	[ "${LSZ}" -gt 0 ] && [ $(( LSZ % 32768 )) = 0 ] || die "known-good.bin di ${LSZ} byte: non e' fatto di blocchi da 32 KiB"
	BLK=$(( LSZ / 32768 ))
	echo "  ${LSZ} byte (da 32 KiB a $(( (32768 + LSZ) / 1048576 )) MiB), sha256 ${WANT}"

	echo "[2/4] controllo la card"
	card_check "${DEV}"
	P1="$(mbr_part 1 "${DEV}")" || die "non leggo la tabella delle partizioni di ${DEV}"
	P1_START="${P1%% *}"
	[ $(( P1_START * 512 )) -ge $(( 32768 + LSZ )) ] \
		|| die "la partizione 1 comincia a $(( P1_START * 512 )) byte, prima della fine del loader ($(( 32768 + LSZ ))): non scrivo"
	if [ "$(card_loader_sum "${BLK}")" = "${WANT}" ]; then
		echo
		echo "Il loader sulla card e' gia' il known-good: niente da scrivere."
		exit 0
	fi

	echo "[3/4] scrivo il loader a 32 KiB (le partizioni non si toccano)"
	dd if="${LOADER}" of="${DEV}" bs=32768 seek=1 conv=fsync,notrunc status=none || die "scrittura fallita"
	sync

	echo "[4/4] rileggo dalla card"
	blockdev --flushbufs "${DEV}" 2>/dev/null
	[ "$(card_loader_sum "${BLK}")" = "${WANT}" ] \
		|| die "la card riletta non ha il known-good: riprova; se si ripete, la card e' da cambiare"
	echo
	echo "Fatto: loader known-good a 32 KiB. /flash e /storage non sono state toccate."
	exit 0
fi

# --- la partizione 1 da un'immagine --------------------------------------------
IMG="$1"
case "${IMG}" in -*) usage ;; esac
[ -f "${IMG}" ] || die "immagine non trovata: ${IMG}"
need dd od stat blkid blockdev sha256sum md5sum gzip mtype mcopy mdir
case "${IMG}" in
	*.gz) img_cat() { gzip -dc "${IMG}"; } ;;
	*)    img_cat() { cat "${IMG}"; } ;;
esac

W=""; M2=""
cleanup() {
	# prima smontare: la cartella di lavoro si cancella con rm -rf
	if [ -n "${M2}" ]; then umount "${M2}" 2>/dev/null; rmdir "${M2}" 2>/dev/null; fi
	if [ -n "${W}" ]; then rm -rf "${W}"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

echo "[1/6] controllo la card"
card_check "${DEV}"
card_umount "${DEV}"
CARD_UUID="$(blkid -p -s UUID -o value "${CP2}" 2>/dev/null)"
is_uuid "${CARD_UUID}" || die "non leggo l'UUID di ${CP2}"
echo "  /storage: ${CP2}, UUID ${CARD_UUID}"

echo "[2/6] apro l'immagine"
W="$(mktemp -d "${TMPDIR:-/var/tmp}/rf35h-reflash.XXXXXX")" || die "non posso lavorare in ${TMPDIR:-/var/tmp}"
img_cat 2>/dev/null | dd of="${W}/mbr" bs=512 count=1 iflag=fullblock status=none
P1="$(mbr_part 1 "${W}/mbr")" || die "${IMG}: nessuna partizione 1 valida: e' un'immagine di Lakka?"
START="${P1%% *}"; P1="${P1#* }"; SECT="${P1%% *}"
echo "  partizione 1: dal settore ${START}, $(( SECT / 2048 )) MB; la estraggo in ${W}"
img_cat 2>/dev/null | dd of="${W}/p1.fat" bs=4M iflag=skip_bytes,count_bytes,fullblock \
	skip=$(( START * 512 )) count=$(( SECT * 512 )) conv=sparse status=none \
	|| die "estrazione fallita: spazio in ${TMPDIR:-/var/tmp}?"
P1F="${W}/p1.fat"
[ "$(stat -c %s "${P1F}")" = $(( SECT * 512 )) ] || die "${IMG} finisce prima della sua partizione 1: scaricata a meta'?"
if [ "$(blkid -p -s TYPE -o value "${P1F}" 2>/dev/null)" != vfat ] \
		|| [ "$(blkid -p -s LABEL -o value "${P1F}" 2>/dev/null)" != LAKKA ]; then
	die "${IMG}: la partizione 1 non e' la FAT LAKKA di un'immagine di Lakka"
fi
mtype -i "${P1F}" ::/extlinux/extlinux.conf > "${W}/extlinux.conf" 2>/dev/null \
	|| die "${IMG}: manca extlinux/extlinux.conf"
# un'immagine di questo port: boot.scr (il suo U-Boot cerca solo quello) e il
# device tree dell'RF35H. Una di Lakka generico non partirebbe.
if ! grep -q '^[[:space:]]*FDT[[:space:]].*rf35h' "${W}/extlinux.conf" \
		|| ! mtype -i "${P1F}" ::/boot.scr >/dev/null 2>&1; then
	die "${IMG}: non e' un'immagine per l'RF35H (niente boot.scr o device tree rf35h)"
fi
for f in KERNEL SYSTEM; do
	want="$(mtype -i "${P1F}" "::/${f}.md5" 2>/dev/null | cut -d' ' -f1)"
	have="$(mtype -i "${P1F}" "::/${f}" 2>/dev/null | md5sum | cut -d' ' -f1)"
	[ -n "${want}" ] && [ "${have}" = "${want}" ] || die "${IMG}: ${f} non corrisponde al suo .md5: immagine rovinata"
	echo "  ${f}: md5 ok"
done

echo "[3/6] l'UUID di /storage in extlinux.conf"
IMG_UUID="$(extlinux_disk_uuid < "${W}/extlinux.conf")"
is_uuid "${IMG_UUID}" || die "${IMG}: extlinux.conf senza disk=UUID=: non so dove cerca /storage"
for f in boot.scr boot.ini cmdline.txt uEnv.txt; do
	if mtype -i "${P1F}" "::/${f}" 2>/dev/null | grep -q -F -e "${IMG_UUID}"; then
		die "${IMG}: anche ${f} ha l'UUID di /storage dell'immagine, e non so correggerlo: la card non e' stata toccata"
	fi
done
if [ "${IMG_UUID}" = "${CARD_UUID}" ]; then
	echo "  lo stesso della card: l'immagine e' quella del primo flash"
else
	echo "  immagine ${IMG_UUID}, card ${CARD_UUID}: extlinux.conf punta alla card"
	sed "s/disk=UUID=${IMG_UUID}/disk=UUID=${CARD_UUID}/g" "${W}/extlinux.conf" > "${W}/extlinux.new"
	mcopy -o -i "${P1F}" "${W}/extlinux.new" ::/extlinux/extlinux.conf 2>/dev/null \
		|| die "non riesco a correggere extlinux.conf: la card non e' stata toccata"
	mtype -i "${P1F}" ::/extlinux/extlinux.conf > "${W}/extlinux.check" 2>/dev/null
	if [ "$(extlinux_disk_uuid < "${W}/extlinux.check")" != "${CARD_UUID}" ] \
			|| grep -q -F -e "${IMG_UUID}" "${W}/extlinux.check"; then
		die "extlinux.conf corretto non torna: la card non e' stata toccata"
	fi
fi

echo "[4/6] confronto le dimensioni"
SZ_IMG=$(( SECT * 512 ))
SZ_CARD="$(blockdev --getsize64 "${CP1}")"
echo "  partizione 1 dell'immagine: $(( SZ_IMG / 1048576 )) MB"
echo "  partizione 1 della card:    $(( SZ_CARD / 1048576 )) MB"
if [ "${SZ_IMG}" -gt "${SZ_CARD}" ]; then
	echo "  La partizione 1 della card e' piu' piccola di quella dell'immagine." >&2
	echo "  Riscriverla troncherebbe il filesystem: serve una scrittura completa" >&2
	echo "  con flash-sd.sh (e in quel caso /storage va salvata prima)." >&2
	exit 1
fi

echo "[5/6] svuoto /storage/.update e scrivo la partizione 1 (la 2 non si tocca)"
M2="$(mktemp -d)"
if mount -t ext4 "${CP2}" "${M2}" 2>/dev/null; then
	echo "  /storage: $(df -h "${M2}" | tail -1 | awk '{print $2" totali, "$3" usati"}')"
	[ -d "${M2}/roms" ] && echo "  roms/: $(find "${M2}/roms" -type f 2>/dev/null | wc -l) file, non vengono toccati"
	if [ -d "${M2}/.update" ]; then
		find "${M2}/.update" -mindepth 1 -maxdepth 2 2>/dev/null | sed "s|^${M2}|  rimuovo: /storage|"
		rm -rf "${M2}"/.update/* "${M2}"/.update/.[!.]* 2>/dev/null
	fi
	sync
	umount "${M2}" || die "non riesco a smontare ${CP2}: non scrivo"
else
	echo "  ATTENZIONE: non riesco a montare ${CP2}, /storage/.update resta com'e'." >&2
	echo "  Proseguo fra 10 s (Ctrl-C per fermarti)..." >&2
	sleep 10
fi
rmdir "${M2}" 2>/dev/null; M2=""
dd if="${P1F}" of="${CP1}" bs=4M conv=fsync status=progress \
	|| die "scrittura della partizione 1 fallita: finche' non riesce la console non parte, rilancia"
sync

echo "[6/6] verifico"
blockdev --flushbufs "${CP1}" 2>/dev/null
bad=0
if command -v fsck.fat >/dev/null 2>&1; then
	if fsck.fat -n "${CP1}" >/dev/null 2>&1; then echo "  ${CP1} (FAT): pulita"; else echo "  ${CP1}: fsck.fat NON pulita" >&2; bad=1; fi
fi
for f in KERNEL SYSTEM; do
	if mdir -i "${CP1}" "::/${f}" >/dev/null 2>&1; then echo "  ${f}: c'e'"; else echo "  ${f}: MANCANTE" >&2; bad=1; fi
done
mtype -i "${CP1}" ::/extlinux/extlinux.conf > "${W}/extlinux.card" 2>/dev/null
P1_UUID="$(blkid -p -s UUID -o value "${CP1}" 2>/dev/null)"
if [ "$(extlinux_disk_uuid < "${W}/extlinux.card")" = "${CARD_UUID}" ]; then
	echo "  disk=UUID=${CARD_UUID}: la /storage della card"
else
	echo "  extlinux.conf: disk=UUID NON e' quello di ${CP2} (${CARD_UUID})" >&2; bad=1
fi
if [ -n "${P1_UUID}" ] && [ "$(extlinux_boot_uuid < "${W}/extlinux.card")" = "${P1_UUID}" ]; then
	echo "  boot=UUID=${P1_UUID}: la FAT appena scritta"
else
	echo "  extlinux.conf: boot=UUID NON e' quello di ${CP1} (${P1_UUID:-?})" >&2; bad=1
fi
if [ -f "${LOADER}" ] && [ -f "${LOADER_SUM}" ]; then
	if [ "$(card_loader_sum $(( $(wc -c < "${LOADER}") / 32768 )))" = "$(cut -d' ' -f1 < "${LOADER_SUM}")" ]; then
		echo "  loader a 32 KiB: il known-good"
	else
		echo "  ATTENZIONE: il loader a 32 KiB non e' il known-good. Se la console non" >&2
		echo "  mostra niente all'accensione: sudo sh $0 --loader ${DEV}" >&2
	fi
fi
sync
[ "${bad}" = 0 ] || die "La partizione 1 non e' come deve: rilancia. Se si ripete, flash-sd.sh (salvando prima /storage)."
echo
echo "Fatto. /storage non e' stata toccata (a parte .update). Rimetti la card e accendi."
