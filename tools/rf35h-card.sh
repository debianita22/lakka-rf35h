#!/bin/sh
# rf35h-card.sh - i controlli sulla card in comune fra gli strumenti per il PC
# (rf35h-reflash-system.sh, rf35h-rescue.sh). Da solo non fa niente: lo si
# include con ". tools/rf35h-card.sh" e poi card_check /dev/sdX.
#
# Le regole sul disco sono quelle di flash-sd.sh: un disco intero (sd?,
# mmcblk?, loop?; una partizione no), che si dichiara rimovibile, al massimo
# 512 GB; FORCE=yes per un lettore che si dichiara male o una card enorme. In
# piu' le due partizioni di una card Lakka con le etichette che scrive
# scripts/mkimage, LAKKA (FAT, /flash) e LAKKA_DISK (ext4, /storage): un
# /dev/sdX sbagliato si ferma qui invece di finire scritto.
#
# RF35H_SYSFS al posto di /sys: solo per le prove.

CARD_SYSFS="${RF35H_SYSFS:-/sys}"

card_die() { echo "$*" >&2; exit 1; }

# un disco intero che si riconosce: la stessa lista di flash-sd.sh (non basta
# "finisce con una cifra": /dev/mmcblk0 e /dev/loop0 sono dischi interi)
card_is_disk() {
	case "$1" in
		/dev/sd[a-z]|/dev/sd[a-z][a-z]) ;;
		/dev/mmcblk[0-9]|/dev/mmcblk[0-9][0-9]) ;;
		/dev/loop[0-9]|/dev/loop[0-9][0-9]) ;;
		*) return 1 ;;
	esac
}

# il prefisso delle partizioni: sdb1, ma mmcblk0p1 e loop0p1
card_part_prefix() {
	case "$1" in
		*[0-9]) echo "$1p" ;;
		*)      echo "$1" ;;
	esac
}

# rimovibile e non troppo grande, da /sys/block/<nome>; FORCE=yes passa
card_sysfs_ok() {
	_rem="$(cat "${CARD_SYSFS}/block/$1/removable" 2>/dev/null || echo 0)"
	_sec="$(cat "${CARD_SYSFS}/block/$1/size" 2>/dev/null || echo 0)"
	case "${_sec}" in ''|*[!0-9]*) _sec=0 ;; esac
	_mb=$(( _sec * 512 / 1000000 ))
	echo "Disco: /dev/$1  ${_mb} MB  rimovibile=${_rem}"
	[ "${FORCE:-}" = yes ] && return 0
	if [ "${_rem}" != 1 ]; then
		echo "Non risulta rimovibile. Se e' davvero la card (alcuni lettori USB lo" >&2
		echo "dichiarano male), rilancia con FORCE=yes davanti al comando." >&2
		return 1
	fi
	if [ $(( _mb / 1000 )) -gt 512 ]; then
		echo "$(( _mb / 1000 )) GB e' troppo per una card. Se e' quella giusta, FORCE=yes." >&2
		return 1
	fi
	return 0
}

# le due partizioni sono quelle di Lakka (blkid -p: legge il disco, non la
# sua cache)
card_lakka_parts() {
	_l1="$(blkid -p -s LABEL -o value "$1" 2>/dev/null)"; _t1="$(blkid -p -s TYPE -o value "$1" 2>/dev/null)"
	_l2="$(blkid -p -s LABEL -o value "$2" 2>/dev/null)"; _t2="$(blkid -p -s TYPE -o value "$2" 2>/dev/null)"
	if [ "${_l1}" = LAKKA ] && [ "${_t1}" = vfat ] && [ "${_l2}" = LAKKA_DISK ] && [ "${_t2}" = ext4 ]; then
		return 0
	fi
	echo "Non e' una card Lakka: $1 e' '${_l1:-?}' (${_t1:-?}), $2 e' '${_l2:-?}' (${_t2:-?});" >&2
	echo "una card Lakka ha LAKKA (vfat) e LAKKA_DISK (ext4). Disco sbagliato?" >&2
	return 1
}

# card_check /dev/sdX: tutto quanto sopra, oppure esce. Imposta CP1 e CP2.
card_check() {
	[ -b "$1" ] || card_die "$1 non risulta un device a blocchi"
	card_is_disk "$1" || card_die "$1 non e' un disco intero che riconosco (sd?, mmcblk?, loop?): una partizione (sdb1, mmcblk0p1) non va bene, serve il disco"
	card_sysfs_ok "${1##*/}" || exit 1
	_pp="$(card_part_prefix "$1")"
	CP1="${_pp}1"; CP2="${_pp}2"
	if [ ! -b "${CP1}" ] || [ ! -b "${CP2}" ]; then
		card_die "su $1 servono le due partizioni di Lakka, ${CP1} e ${CP2}"
	fi
	card_lakka_parts "${CP1}" "${CP2}" || exit 1
}

# Smonta le partizioni della card, solo le sue (/dev/loop1 non e' /dev/loop10,
# /dev/sdb non e' /dev/sdba), ed esce se ne resta una montata: un file
# manager, o l'automount del desktop.
card_umount() {
	_pp="$(card_part_prefix "$1")"
	for _p in "${_pp}"[0-9]*; do
		[ -b "${_p}" ] && umount "${_p}" 2>/dev/null
	done
	if command -v udevadm >/dev/null 2>&1; then udevadm settle 2>/dev/null; fi
	_m="$(awk -v d="$1" -v p="${_pp}" '$1 == d || (index($1, p) == 1 && substr($1, length(p) + 1) ~ /^[0-9]+$/) { printf "%s ", $1 }' /proc/mounts)"
	[ -z "${_m}" ] || card_die "${_m}ancora montata: chiudi il file manager e rilancia"
}

# "start settori tipo" della partizione $1 (1-4) nell'MBR di $2 (un file o un
# device). od byte per byte: il risultato non dipende dall'endianness del PC.
mbr_part() {
	_o=$(( 446 + ($1 - 1) * 16 ))
	# shellcheck disable=SC2046  # i numeri di od, uno per parametro
	set -- $(od -An -tu1 -j510 -N2 "$2" 2>/dev/null) $(od -An -tu1 -j"${_o}" -N16 "$2" 2>/dev/null)
	[ $# -eq 18 ] && [ "$1" = 85 ] && [ "$2" = 170 ] || return 1
	_ty="$7"
	_st=$(( ${11} + ${12} * 256 + ${13} * 65536 + ${14} * 16777216 ))
	_sz=$(( ${15} + ${16} * 256 + ${17} * 65536 + ${18} * 16777216 ))
	# vuota, o GPT (0xee): le immagini di Lakka per u-boot sono msdos
	[ "${_ty}" != 0 ] && [ "${_ty}" != 238 ] && [ "${_sz}" -gt 0 ] || return 1
	echo "${_st} ${_sz} ${_ty}"
}

# disk=UUID=... della riga APPEND di un extlinux.conf (da stdin)
extlinux_disk_uuid() {
	sed -n 's/^[[:space:]]*APPEND.*[[:space:]]disk=UUID=\([^[:space:]]*\).*$/\1/p' | head -n 1
}
# boot=UUID=... della stessa riga
extlinux_boot_uuid() {
	sed -n 's/^[[:space:]]*APPEND.*[[:space:]]boot=UUID=\([^[:space:]]*\).*$/\1/p' | head -n 1
}
# un UUID come lo scrivono uuidgen e mformat (cifre esadecimali e trattini)
is_uuid() {
	case "$1" in ''|*[!0-9A-Fa-f-]*) return 1 ;; esac
}
