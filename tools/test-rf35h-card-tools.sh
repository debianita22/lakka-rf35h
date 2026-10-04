#!/bin/bash
# test-rf35h-card-tools.sh - prove degli strumenti per la card sul PC:
# rf35h-card.sh (i controlli comuni), rf35h-reflash-system.sh, rf35h-rescue.sh.
#
#   ./tools/test-rf35h-card-tools.sh
#   sudo RF35H_TEST_DEVICES=1 ./tools/test-rf35h-card-tools.sh
#
# Sempre: la logica pura (dischi accettati, /sys finto, MBR, extlinux.conf),
# con la sh di sistema come la usano gli strumenti. Con RF35H_TEST_DEVICES=1,
# da root, anche gli strumenti veri su una card finta: un file con MBR, p1 FAT
# e p2 ext4, attaccato a tre loop device (il disco intero e le due partizioni
# con offset) e i nodi /dev/loopNp1 e p2 fatti con mknod, perche' i loop con
# le partizioni (losetup -P) non ci sono dappertutto. Servono losetup, sfdisk,
# mtools, mkfs.ext4. Le verifiche sono stringhe che ok() esegue con eval.
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
CARD="${O}/tools/rf35h-card.sh"
REFLASH="${O}/tools/rf35h-reflash-system.sh"
RESCUE="${O}/tools/rf35h-rescue.sh"
T="$(mktemp -d)"
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
# una funzione di rf35h-card.sh, con sh come gli strumenti
cs() { sh -c '. "$0"; "$@"' "${CARD}" "$@"; }

echo "rf35h-card.sh: ${CARD}"
for d in /dev/sdb /dev/sdab /dev/mmcblk0 /dev/mmcblk10 /dev/loop0 /dev/loop12; do
	ok "disco intero: ${d}" 'cs card_is_disk "${d}"'
done
for d in /dev/sdb1 /dev/mmcblk0p1 /dev/loop0p1 /dev/nvme0n1 /dev/sd /dev/sdb/ sdb ""; do
	ok "non un disco intero: '${d}'" '! cs card_is_disk "${d}"'
done
ok "partizioni: sdb1, mmcblk0p1, loop1p1" '[ "$(cs card_part_prefix /dev/sdb)" = /dev/sdb ] && [ "$(cs card_part_prefix /dev/mmcblk0)" = /dev/mmcblk0p ] && [ "$(cs card_part_prefix /dev/loop1)" = /dev/loop1p ]'

# /sys finto
mkdir -p "${T}/sys/block/sdc" "${T}/sys/block/sdd" "${T}/sys/block/sde"
echo 1 > "${T}/sys/block/sdc/removable"; echo 31116288 > "${T}/sys/block/sdc/size"     # 16 GB
echo 0 > "${T}/sys/block/sdd/removable"; echo 31116288 > "${T}/sys/block/sdd/size"
echo 1 > "${T}/sys/block/sde/removable"; echo 1300000000 > "${T}/sys/block/sde/size"  # 665 GB
sysok() { RF35H_SYSFS="${T}/sys" cs card_sysfs_ok "$@" >/dev/null 2>"${T}/err"; }
ok "/sys: rimovibile, 16 GB: va" 'sysok sdc'
ok "/sys: non rimovibile: no, e dice FORCE=yes" '! sysok sdd && grep -q "FORCE=yes" "${T}/err"'
ok "  ...con FORCE=yes: va" 'FORCE=yes sysok sdd'
ok "/sys: 665 GB: no" '! sysok sde && grep -q "troppo per una card" "${T}/err"'
ok "  ...con FORCE=yes: va" 'FORCE=yes sysok sde'
ok "/sys: un disco che non c'e': no" '! sysok sdz'

# MBR fatti a mano: voce N = boot tipo start size
mbr() {   # file voce...  (voce: "boot tipo start settori"), firma 55 aa
	head -c 512 /dev/zero > "$1"; f="$1"; shift; i=0
	for e in "$@"; do
		# shellcheck disable=SC2086
		set -- ${e}
		le() { printf '\\x%02x\\x%02x\\x%02x\\x%02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 24) & 255 )); }
		# shellcheck disable=SC2059
		printf "\\x$(printf %02x "$1")\\x00\\x00\\x00\\x$(printf %02x "$2")\\x00\\x00\\x00$(le "$3")$(le "$4")" \
			| dd of="${f}" bs=1 seek=$(( 446 + i * 16 )) conv=notrunc status=none
		i=$((i + 1))
	done
	printf '\x55\xaa' | dd of="${f}" bs=1 seek=510 conv=notrunc status=none
}
mbr "${T}/mbr" "128 12 32768 6291456" "0 131 6324224 65536"
ok "MBR: la partizione 1 di un'immagine di Lakka" '[ "$(cs mbr_part 1 "${T}/mbr")" = "32768 6291456 12" ]'
ok "MBR: la partizione 2" '[ "$(cs mbr_part 2 "${T}/mbr")" = "6324224 65536 131" ]'
ok "MBR: la 3, vuota: no" '! cs mbr_part 3 "${T}/mbr"'
mbr "${T}/mbr2" "0 12 16909060 4278190081"
ok "MBR: i quattro byte in ordine (little endian)" '[ "$(cs mbr_part 1 "${T}/mbr2")" = "16909060 4278190081 12" ]'
mbr "${T}/mbr3" "0 238 1 4294967295"
ok "MBR: GPT protettivo (0xee): no" '! cs mbr_part 1 "${T}/mbr3"'
head -c 512 /dev/zero > "${T}/mbr4"
ok "MBR: senza la firma 55 aa: no" '! cs mbr_part 1 "${T}/mbr4"'
ok "MBR: file corto: no" 'head -c 300 "${T}/mbr" > "${T}/mbr5" && ! cs mbr_part 1 "${T}/mbr5"'

# extlinux.conf com'e' nella v1.0.0
cat > "${T}/ext.conf" <<'EOF'
LABEL Lakka
  LINUX /KERNEL
  FDT /rk3326-xifan-rf35h.dtb
  APPEND boot=UUID=0410-3400 disk=UUID=304a6f99-f5c5-44af-9357-efee95c148be quiet quiet console=tty0 console=ttyS1,1500000n8 net.ifnames=0 ipv6.disable=1
EOF
ok "extlinux.conf: disk=UUID" '[ "$(cs extlinux_disk_uuid < "${T}/ext.conf")" = 304a6f99-f5c5-44af-9357-efee95c148be ]'
ok "extlinux.conf: boot=UUID" '[ "$(cs extlinux_boot_uuid < "${T}/ext.conf")" = 0410-3400 ]'
ok "extlinux.conf: disk= prima di boot=" '[ "$(echo "  APPEND disk=UUID=aa-bb boot=UUID=cc-dd quiet" | cs extlinux_disk_uuid)" = aa-bb ] && [ "$(echo "  APPEND disk=UUID=aa-bb boot=UUID=cc-dd" | cs extlinux_boot_uuid)" = cc-dd ]'
ok "extlinux.conf: senza disk=: vuoto" '[ -z "$(echo "  APPEND boot=UUID=0410-3400 quiet" | cs extlinux_disk_uuid)" ]'
ok "UUID: validi e no" 'cs is_uuid 304a6f99-f5c5-44af-9357-efee95c148be && cs is_uuid 0410-3400 && ! cs is_uuid "" && ! cs is_uuid "x;rm" && ! cs is_uuid ../a'
# le stesse regole di flash-sd.sh: la lista dei dischi non deve divergere
disks() { grep -E '^[[:space:]]*/dev/(sd|mmcblk|loop)\[' "$1" | sed 's/[[:space:]]//g; s/;;.*//'; }
ok "lista dei dischi uguale a quella di flash-sd.sh" '[ -n "$(disks "${CARD}")" ] && [ "$(disks "${CARD}")" = "$(disks "${O}/flash-sd.sh")" ]'

if [ "${RF35H_TEST_DEVICES:-}" != 1 ]; then
	echo "  (strumenti su una card finta: salto, servono root e RF35H_TEST_DEVICES=1)"
	rm -rf "${T}"
	echo "--- ${pass} ok, ${fail} falliti"
	[ "${fail}" = 0 ]; exit
fi
for t in losetup sfdisk mformat mcopy mtype mmd mkfs.ext4 blkid gzip mknod; do
	command -v "${t}" >/dev/null || { echo "manca ${t}: non posso provare sui device" >&2; exit 1; }
done
[ "$(id -u)" = 0 ] || { echo "serve root per i loop device" >&2; exit 1; }

# --- strumenti veri su una card finta -----------------------------------------
LOOPS=""; NODES=""
cleanup() {
	for n in ${NODES}; do rm -f "${n}"; done
	for l in ${LOOPS}; do losetup -d "${l}" 2>/dev/null; done
	grep -q " ${T}/" /proc/mounts && awk -v t="${T}/" 'index($2, t) == 1 { print $2 }' /proc/mounts | xargs -r umount
	rm -rf "${T}"
}
trap cleanup EXIT
export MTOOLS_SKIP_CHECK=1 TMPDIR="${T}/tmp"
mkdir -p "${TMPDIR}"
# la geometria della card: p1 dal settore 32768 (16 MiB, come mkimage), 64 MiB
P1S=32768; P1N=131072; P2S=163840; P2N=32768
KG="${O}/board/loader/known-good.bin"

# la FAT di una partizione 1: mkfat file seriale uuid-storage [generic|scruuid] [settori]
mkfat() {
	local f="$1" ser="$2" uuid="$3" kind="${4:-}" d="${T}/fatsrc"
	rm -rf "${d}" "${f}"; mkdir -p "${d}"
	truncate -s $(( ${5:-${P1N}} * 512 )) "${f}"
	mformat -i "${f}" -v LAKKA -N "${ser/-/}" :: || return 1
	head -c 300000 /dev/urandom > "${d}/KERNEL"; head -c 900000 /dev/urandom > "${d}/SYSTEM"
	(cd "${d}" && md5sum KERNEL | sed 's|KERNEL|target/KERNEL|' > KERNEL.md5 && md5sum SYSTEM | sed 's|SYSTEM|target/SYSTEM|' > SYSTEM.md5)
	local dtb=rk3326-xifan-rf35h.dtb; [ "${kind}" = generic ] && dtb=rk3326-odroid-go2.dtb
	printf 'LABEL Lakka\n  LINUX /KERNEL\n  FDT /%s\n  APPEND boot=UUID=%s disk=UUID=%s quiet console=ttyS1,1500000n8\n' "${dtb}" "${ser}" "${uuid}" > "${d}/extlinux.conf"
	printf 'Lakka RF35H\nsysboot ${devtype} ${devnum}:${distro_bootpart} any 0x100000 /extlinux/extlinux.conf\n%s\n' \
		"$([ "${kind}" = scruuid ] && echo "setenv bootargs disk=UUID=${uuid}")" > "${d}/boot.scr"
	head -c 1000 /dev/urandom > "${d}/${dtb}"
	mmd -i "${f}" ::/extlinux && mcopy -i "${f}" "${d}/extlinux.conf" ::/extlinux/ \
		&& mcopy -i "${f}" "${d}/KERNEL" "${d}/SYSTEM" "${d}/KERNEL.md5" "${d}/SYSTEM.md5" "${d}/${dtb}" :: || return 1
	[ "${kind}" = generic ] || mcopy -i "${f}" "${d}/boot.scr" :: || return 1
}
# un'immagine: mkimg file seriale uuid-storage [generic|scruuid|badmd5]
mkimg() {
	local f="$1"
	rm -f "${f}"; truncate -s $(( (P2S + 16384) * 512 )) "${f}"
	printf 'label: dos\nstart=%s, size=%s, type=c, bootable\nstart=%s, size=16384, type=83\n' "${P1S}" "${P1N}" "${P2S}" | sfdisk -q "${f}"
	mkfat "${T}/img-p1.fat" "$2" "$3" "${4:-}" || return 1
	if [ "${4:-}" = badmd5 ]; then echo 0123456789abcdef0123456789abcdef > "${T}/bad.md5"; mcopy -o -i "${T}/img-p1.fat" "${T}/bad.md5" ::/SYSTEM.md5; fi
	dd if="${T}/img-p1.fat" of="${f}" bs=512 seek="${P1S}" conv=notrunc status=none
	truncate -s $(( 16384 * 512 )) "${T}/img-p2.ext4"; mkfs.ext4 -q -F -L LAKKA_DISK -U "$3" "${T}/img-p2.ext4"
	dd if="${T}/img-p2.ext4" of="${f}" bs=512 seek="${P2S}" conv=notrunc status=none
	rm -f "${T}/img-p1.fat" "${T}/img-p2.ext4"
}
# una card scritta da un'altra build, con /storage piena: mkcard file uuid [p2-label] [p1-start]
mkcard() {
	local f="$1" s1="${4:-${P1S}}"
	rm -f "${f}"; truncate -s $(( (P2S + P2N) * 512 )) "${f}"
	printf 'label: dos\nstart=%s, size=%s, type=c, bootable\nstart=%s, size=%s, type=83\n' "${s1}" "$(( P2S - s1 ))" "${P2S}" "${P2N}" | sfdisk -q "${f}"
	head -c $(( 16 * 1048576 - 32768 )) /dev/urandom | dd of="${f}" bs=32768 seek=1 conv=notrunc status=none 2>/dev/null
	mkfat "${T}/card-p1.fat" 1111-2222 "$2" "" $(( P2S - s1 )) && dd if="${T}/card-p1.fat" of="${f}" bs=512 seek="${s1}" conv=notrunc status=none
	rm -f "${T}/card-p1.fat"
	truncate -s $(( P2N * 512 )) "${T}/card-p2.ext4"; mkfs.ext4 -q -F -L "${3:-LAKKA_DISK}" -U "$2" "${T}/card-p2.ext4"
	mkdir -p "${T}/m"; mount -o loop "${T}/card-p2.ext4" "${T}/m"
	mkdir -p "${T}/m/roms/gba" "${T}/m/.update/.rf35h-staged" "${T}/m/.config"
	echo rom > "${T}/m/roms/gba/gioco.gba"; echo vecchio > "${T}/m/.update/Lakka-fallito.tar"
	echo x > "${T}/m/.update/.rf35h-staged/Lakka-v9.tar"
	printf '#!/bin/sh\n# il mio\nconnmanctl enable wifi\n' > "${T}/m/.config/autostart.sh"
	umount "${T}/m"
	dd if="${T}/card-p2.ext4" of="${f}" bs=512 seek="${P2S}" conv=notrunc status=none
	rm -f "${T}/card-p2.ext4"
}
# la card nei loop: DEV (disco intero) con i nodi ${DEV}p1 e ${DEV}p2
attach() {   # file [p1-start]
	local s1="${2:-${P1S}}" a b
	DEV="$(losetup -f --show "$1")"; LOOPS="${LOOPS} ${DEV}"
	a="$(losetup -f --show -o $(( s1 * 512 )) --sizelimit $(( (P2S - s1) * 512 )) "$1")"; LOOPS="${LOOPS} ${a}"
	b="$(losetup -f --show -o $(( P2S * 512 )) --sizelimit $(( P2N * 512 )) "$1")"; LOOPS="${LOOPS} ${b}"
	mknod "${DEV}p1" b 7 "${a#/dev/loop}"; mknod "${DEV}p2" b 7 "${b#/dev/loop}"; NODES="${NODES} ${DEV}p1 ${DEV}p2"
}
detach() {
	sync
	for n in ${NODES}; do rm -f "${n}"; done; NODES=""
	for l in ${LOOPS}; do losetup -d "${l}" 2>/dev/null; done; LOOPS=""
}
# cosa c'e' sulla card (file): la regione di p1, l'MBR, la p2
p1sum() { dd if="$1" bs=512 skip="${2:-${P1S}}" count=$(( P2S - ${2:-${P1S}} )) status=none | md5sum | cut -d' ' -f1; }
regsum() { dd if="$1" bs=512 skip="$2" count="$3" status=none | md5sum | cut -d' ' -f1; }
p1type() { mtype -i "$1@@$(( P1S * 512 ))" "$2" 2>/dev/null; }
p2look() {   # file: comandi su /storage della card in ${T}/m
	dd if="$1" of="${T}/p2.ext4" bs=512 skip="${P2S}" count="${P2N}" status=none
	mkdir -p "${T}/m"; mount -o loop,ro "${T}/p2.ext4" "${T}/m"
}
p2done() { umount "${T}/m"; rm -f "${T}/p2.ext4"; }
reflash() { (cd "${T}" && sh "${REFLASH}" "$@") > "${T}/out" 2>&1; }

CU=aaaaaaaa-0000-4000-8000-00000000000c    # /storage della card
IU=bbbbbbbb-0000-4000-8000-00000000000b    # /storage dell'immagine nuova
echo "-- rf35h-reflash-system.sh su una card finta"
mkimg "${T}/new.img" 0410-3400 "${IU}"; gzip -c "${T}/new.img" > "${T}/new.img.gz"
mkcard "${T}/card.img" "${CU}"; MBR0="$(regsum "${T}/card.img" 0 1)"
attach "${T}/card.img"
FORCE=yes reflash "${T}/new.img.gz" "${DEV}"; rc=$?
detach
ok "un'altra build (.img.gz): esce 0" '[ ${rc} = 0 ]'
ok "  ...la partizione 1 e' quella dell'immagine (KERNEL)" '[ "$(p1type "${T}/card.img" ::/KERNEL | md5sum)" = "$(mtype -i "${T}/new.img@@$(( P1S * 512 ))" ::/KERNEL | md5sum)" ]'
ok "  ...extlinux.conf: disk=UUID della card, non dell'immagine" 'p1type "${T}/card.img" ::/extlinux/extlinux.conf | grep -q "disk=UUID=${CU} " && ! p1type "${T}/card.img" ::/extlinux/extlinux.conf | grep -q "${IU}"'
ok "  ...boot=UUID: la FAT scritta" 'p1type "${T}/card.img" ::/extlinux/extlinux.conf | grep -q "boot=UUID=0410-3400 " && [ "$(blkid -p -O $(( P1S * 512 )) -s UUID -o value "${T}/card.img")" = 0410-3400 ]'
ok "  ...l'MBR non si tocca" '[ "$(regsum "${T}/card.img" 0 1)" = "${MBR0}" ]'
p2look "${T}/card.img"
ok "  .../storage: ROM e autostart.sh restano, .update vuota (anche .rf35h-staged)" '[ -f "${T}/m/roms/gba/gioco.gba" ] && grep -q "il mio" "${T}/m/.config/autostart.sh" && [ -z "$(ls -A "${T}/m/.update")" ]'
p2done
ok "  ...l'UUID di /storage non cambia" '[ "$(blkid -p -O $(( P2S * 512 )) -s UUID -o value "${T}/card.img")" = "${CU}" ]'
ok "  ...e lo dice" 'grep -q "extlinux.conf punta alla card" "${T}/out" && grep -q "disk=UUID=${CU}: la /storage della card" "${T}/out"'

mkcard "${T}/card.img" "${IU}"; attach "${T}/card.img"
FORCE=yes reflash "${T}/new.img" "${DEV}"; rc=$?
detach
ok "la stessa build (.img): esce 0, niente da correggere" '[ ${rc} = 0 ] && grep -q "lo stesso della card" "${T}/out" && p1type "${T}/card.img" ::/extlinux/extlinux.conf | grep -q "disk=UUID=${IU} "'

mkcard "${T}/card.img" "${CU}"; S0="$(p1sum "${T}/card.img")"; attach "${T}/card.img"
reflash "${T}/new.img.gz" "${DEV}"; rc=$?
ok "loop non rimovibile senza FORCE=yes: no, card intatta" '[ ${rc} != 0 ] && grep -q "FORCE=yes" "${T}/out" && [ "$(p1sum "${T}/card.img")" = "${S0}" ]'
FORCE=yes reflash "${T}/new.img.gz" "${DEV}p1"; rc=$?
ok "una partizione invece del disco: no" '[ ${rc} != 0 ] && grep -q "non e. un disco intero" "${T}/out"'
mkimg "${T}/gen.img" 0410-3400 "${IU}" generic
FORCE=yes reflash "${T}/gen.img" "${DEV}"; rc=$?
ok "immagine di Lakka generico (niente boot.scr, dtb non rf35h): no, card intatta" '[ ${rc} != 0 ] && grep -q "non e. un.immagine per l.RF35H" "${T}/out" && [ "$(p1sum "${T}/card.img")" = "${S0}" ]'
mkimg "${T}/scr.img" 0410-3400 "${IU}" scruuid
FORCE=yes reflash "${T}/scr.img" "${DEV}"; rc=$?
ok "UUID anche in boot.scr: no, card intatta" '[ ${rc} != 0 ] && grep -q "boot.scr ha l.UUID" "${T}/out" && [ "$(p1sum "${T}/card.img")" = "${S0}" ]'
mkimg "${T}/md5.img" 0410-3400 "${IU}" badmd5
FORCE=yes reflash "${T}/md5.img" "${DEV}"; rc=$?
ok "SYSTEM diverso dal suo .md5: no, card intatta" '[ ${rc} != 0 ] && grep -q "SYSTEM non corrisponde" "${T}/out" && [ "$(p1sum "${T}/card.img")" = "${S0}" ]'
head -c $(( $(stat -c %s "${T}/new.img.gz") / 2 )) "${T}/new.img.gz" > "${T}/half.img.gz"
FORCE=yes reflash "${T}/half.img.gz" "${DEV}"; rc=$?
ok ".img.gz scaricato a meta': no, card intatta" '[ ${rc} != 0 ] && [ "$(p1sum "${T}/card.img")" = "${S0}" ]'
detach
mkcard "${T}/other.img" "${CU}" STORAGE; attach "${T}/other.img"
S1="$(p1sum "${T}/other.img")"
FORCE=yes reflash "${T}/new.img.gz" "${DEV}"; rc=$?
detach
ok "p2 senza l'etichetta LAKKA_DISK (un altro disco): no, intatto" '[ ${rc} != 0 ] && grep -q "Non e. una card Lakka" "${T}/out" && [ "$(p1sum "${T}/other.img")" = "${S1}" ]'

echo "-- rf35h-reflash-system.sh --loader"
mkcard "${T}/card.img" "${CU}"; S0="$(p1sum "${T}/card.img")"; MBR0="$(regsum "${T}/card.img" 0 1)"
P2SUM="$(regsum "${T}/card.img" "${P2S}" "${P2N}")"
attach "${T}/card.img"
FORCE=yes reflash --loader "${DEV}"; rc=$?
detach
ok "--loader: esce 0, il known-good a 32 KiB" '[ ${rc} = 0 ] && cmp -s <(dd if="${T}/card.img" bs=32768 skip=1 count=511 status=none) "${KG}"'
ok "  ...MBR, partizione 1 e /storage non toccate" '[ "$(regsum "${T}/card.img" 0 1)" = "${MBR0}" ] && [ "$(p1sum "${T}/card.img")" = "${S0}" ] && [ "$(regsum "${T}/card.img" "${P2S}" "${P2N}")" = "${P2SUM}" ]'
attach "${T}/card.img"
FORCE=yes reflash --loader "${DEV}"; rc=$?
detach
ok "  ...di nuovo: c'e' gia', niente da scrivere" '[ ${rc} = 0 ] && grep -q "gia. il known-good" "${T}/out"'
mkcard "${T}/early.img" "${CU}" LAKKA_DISK 2048
S2="$(regsum "${T}/early.img" 0 32768)"
attach "${T}/early.img" 2048
FORCE=yes reflash --loader "${DEV}"; rc=$?
detach
ok "--loader con la partizione 1 dentro i 16 MiB: no, niente scritto" '[ ${rc} != 0 ] && grep -q "prima della fine del loader" "${T}/out" && [ "$(regsum "${T}/early.img" 0 32768)" = "${S2}" ]'

echo "-- rf35h-rescue.sh"
mkcard "${T}/card.img" "${CU}"; attach "${T}/card.img"
(cd "${T}" && FORCE=yes sh "${RESCUE}" "${DEV}" "Rete" "pw") > "${T}/out" 2>&1; rc=$?
(cd "${T}" && FORCE=yes sh "${RESCUE}" "${DEV}" "Rete" "pw") > "${T}/out2" 2>&1; rc2=$?
detach
p2look "${T}/card.img"
ok "rescue: esce 0, autostart.sh e' quello di raccolta" '[ ${rc} = 0 ] && [ ${rc2} = 0 ] && grep -q "^# rf35h rescue:" "${T}/m/.config/autostart.sh"'
ok "  ...il tuo da parte, anche dopo un secondo giro" 'grep -q "il mio" "${T}/m/.config/autostart.sh.rf35h-rescue"'
# la fine dello script di raccolta, su questa /storage, con systemctl & C. finti
cp -a "${T}/m" "${T}/st"; p2done
mkdir -p "${T}/stub"; for c in sleep journalctl systemctl dmesg retroarch; do printf '#!/bin/sh\nexit 0\n' > "${T}/stub/${c}"; chmod +x "${T}/stub/${c}"; done
sed "s|/storage|${T}/st|g" "${T}/st/.config/autostart.sh" > "${T}/as.sh"
PATH="${T}/stub:${PATH}" sh "${T}/as.sh"; for _ in 1 2 3 4 5; do [ -e "${T}/st/.config/autostart.sh.rf35h-rescue" ] || break; sleep 1; done
ok "  ...finita la raccolta torna il tuo autostart.sh" 'grep -q "il mio" "${T}/st/.config/autostart.sh" && [ ! -e "${T}/st/.config/autostart.sh.rf35h-rescue" ]'
rm -f "${T}/st/.config/autostart.sh"; cp "${T}/as.sh" "${T}/st/.config/autostart.sh"
PATH="${T}/stub:${PATH}" sh "${T}/st/.config/autostart.sh"; for _ in 1 2 3 4 5; do [ -e "${T}/st/.config/autostart.sh" ] || break; sleep 1; done
ok "  ...senza un autostart.sh prima: si toglie e basta" '[ ! -e "${T}/st/.config/autostart.sh" ]'
mkcard "${T}/card.img" "${CU}"; attach "${T}/card.img"
(cd "${T}" && sh "${RESCUE}" "${DEV}" "Rete" "pw") > "${T}/out" 2>&1; rc=$?
detach
ok "rescue senza FORCE=yes su un disco non rimovibile: no" '[ ${rc} != 0 ] && grep -q "FORCE=yes" "${T}/out"'

echo "--- ${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
