#!/bin/sh
# flash-sd.sh - scrive l'immagine sulla SD nel modo che non la corrompe.
#
#   sudo ./flash-sd.sh <immagine.img.gz> /dev/sdX
#
# Perche' esiste: una card che ha gia' bootato ha STORAGE ridimensionata a
# tutta la card e piena di file. Reinserita nel PC, il desktop la monta da
# solo. Un dd su una partizione montata sembra riuscire, ma il kernel ha
# ancora in cache blocchi della vecchia partizione e li riscrive sopra la
# nuova immagine quando la smonta: la FAT parte, la ext4 no. Sul device
# l'init di LibreELEC non riesce a montare /storage, chiama error() e si ferma
# in debug_shell; sul PC la partizione "non si apre". Sembra un guasto, e' un
# dd fatto con la card montata.
#
# Cosa fa, in ordine:
#   1. rifiuta dischi che non sembrano card rimovibili (niente dd su /dev/sda)
#   2. smonta tutto quello che c'e' montato dalla card
#   3. wipefs: toglie le firme delle vecchie partizioni, cosi' il desktop non
#      le rimonta a meta' scrittura
#   4. dd con conv=fsync, poi sync
#   5. fsck su entrambe le partizioni PRIMA di darla per buona
#   6. abilita ssh creando /storage/.cache/services/sshd.conf, il flag che il
#      menu di Lakka legge, via /flash/firstboot.sh (non dentro /storage:
#      bloccherebbe l'espansione della partizione al primo avvio)

set -eu
[ $# -eq 2 ] || { echo "Uso: sudo $0 <immagine.img.gz> /dev/sdX"; exit 1; }
IMG="$1"; DEV="$2"
[ "$(id -u)" = "0" ] || { echo "Serve root (sudo)."; exit 1; }
[ -f "${IMG}" ] || { echo "Immagine non trovata: ${IMG}"; exit 1; }
[ -b "${DEV}" ] || { echo "Non e' un device a blocchi: ${DEV}"; exit 1; }
# Il disco intero, non una partizione. Whitelist perche' "finisce con una
# cifra" non basta: /dev/mmcblk0 e /dev/loop0 sono dischi interi.
case "${DEV}" in
	/dev/sd[a-z]|/dev/sd[a-z][a-z]) ;;
	/dev/mmcblk[0-9]|/dev/mmcblk[0-9][0-9]) ;;
	/dev/loop[0-9]|/dev/loop[0-9][0-9]) ;;
	*) echo "${DEV} non e' un disco intero che riconosco (sd?, mmcblk?, loop?)"; echo "Una partizione (sdb1, mmcblk0p1) non va bene: serve il disco."; exit 1 ;;
esac

name="$(basename "${DEV}")"
removable="$(cat "/sys/block/${name}/removable" 2>/dev/null || echo 0)"
size_mb=$(( $(cat "/sys/block/${name}/size" 2>/dev/null || echo 0) * 512 / 1000000 ))
size_gb=$(( size_mb / 1000 ))
echo "Disco: ${DEV}  ${size_mb} MB  rimovibile=${removable}"
if [ "${removable}" != "1" ] && [ "${FORCE:-}" != "yes" ]; then
	echo "Non risulta rimovibile. Se e' davvero la card (alcuni lettori USB lo"
	echo "dichiarano male), rilancia con FORCE=yes davanti al comando."
	exit 1
fi
if [ "${size_gb}" -gt 512 ] && [ "${FORCE:-}" != "yes" ]; then
	echo "${size_gb} GB e' troppo per una card. Se e' quella giusta, FORCE=yes."
	exit 1
fi

echo
echo "Sto per CANCELLARE ${DEV}. Hai 5 secondi per Ctrl-C."
sleep 5

echo "[1/6] smonto le partizioni della card"
for p in "${DEV}"*; do
	[ "${p}" = "${DEV}" ] && continue
	umount "${p}" 2>/dev/null && echo "  smontata ${p}" || true
done

echo "[2/6] tolgo le vecchie firme (wipefs)"
wipefs -a -q "${DEV}"
udevadm settle 2>/dev/null || true

echo "[3/6] scrivo l'immagine"
case "${IMG}" in
	*.gz) zcat "${IMG}" | dd of="${DEV}" bs=4M conv=fsync status=progress ;;
	*)    dd if="${IMG}" of="${DEV}" bs=4M conv=fsync status=progress ;;
esac
sync
# far comparire le nuove partizioni: udev ci pensa da solo sui desktop, ma
# senza udev (o su un loop device) servono partprobe o partx.
partprobe "${DEV}" 2>/dev/null || partx -a "${DEV}" 2>/dev/null || true
udevadm settle 2>/dev/null || sleep 2

# le partizioni si chiamano sdX1/sdX2 oppure mmcblk0p1/p2
if [ -b "${DEV}p1" ]; then P1="${DEV}p1"; P2="${DEV}p2"; else P1="${DEV}1"; P2="${DEV}2"; fi

echo "[4/6] verifico i filesystem appena scritti"
fsck.fat -n "${P1}" >/dev/null 2>&1 && echo "  ${P1} (FAT, SYSTEM):   ok" || { echo "  ${P1}: fsck.fat NON pulito"; exit 1; }
fsck.ext4 -n "${P2}" >/dev/null 2>&1 && echo "  ${P2} (ext4, STORAGE): ok" || { echo "  ${P2}: fsck.ext4 NON pulito"; exit 1; }

echo "[5/6] espando la partizione STORAGE su tutta la card"
# Lo facciamo qui invece di lasciarlo al primo avvio. LibreELEC avrebbe il suo
# meccanismo - libreelec-target-generator vede /storage/.please_resize_me e
# dirotta il boot su fs-resize.target - ma e' fragile: fs-resize si rifiuta di
# procedere se trova /storage/.config, .cache o .kodi, e in quel caso TOGLIE il
# marcatore, quindi non ci riprova mai piu' e la card resta di 25 MB per sempre.
# Farlo da qui e' anche piu' veloce: niente ciclo ridimensiona-riavvia al primo
# accensione. Gli stessi comandi che userebbe fs-resize, ma con resize2fs al
# posto di mke2fs: allarga conservando invece di ricreare.
RESIZED="no"
# Fra il dd e questo punto sono passati partprobe e udevadm settle: su un
# desktop con automount, GNOME o KDE hanno avuto tutto il tempo di montare le
# partizioni appena scritte. Con la p2 montata, e2fsck -f -p si rifiuta di
# lavorare e il kernel non puo' rileggere la tabella. Si smonta di nuovo qui,
# e se resta montata non si tocca niente: meglio saltare il resize che
# eseguire e2fsck su un filesystem in uso.
for p in "${DEV}"*; do
	[ "${p}" = "${DEV}" ] && continue
	umount "${p}" 2>/dev/null || true
done
udevadm settle 2>/dev/null || true
if grep -q "^${DEV}" /proc/mounts 2>/dev/null; then
	echo "  ${DEV} ha ancora partizioni montate: salto il resize" >&2
	echo "  (chiudi il file manager e rilancia, oppure lo fara' il device)" >&2
elif command -v parted >/dev/null 2>&1 && command -v resize2fs >/dev/null 2>&1 \
   && command -v e2fsck >/dev/null 2>&1; then
	before="$(blockdev --getsize64 "${P2}" 2>/dev/null || echo 0)"
	if parted -s -f "${DEV}" resizepart 2 100% >/dev/null 2>&1; then
		# il kernel deve rileggere la tabella prima di toccare il filesystem
		partprobe "${DEV}" >/dev/null 2>&1 || blockdev --rereadpt "${DEV}" >/dev/null 2>&1 || true
		sleep 1
		udevadm settle >/dev/null 2>&1 || true
		after="$(blockdev --getsize64 "${P2}" 2>/dev/null || echo 0)"
		# Se il kernel non ha riletto la tabella, il device e' ancora quello
		# vecchio: resize2fs "riuscirebbe" sulla dimensione di prima e noi
		# toglieremmo il marcatore lasciando la card piccola per sempre - la
		# rottura che stiamo evitando. Si procede solo se e' cresciuta davvero.
		if [ "${after}" -le "${before}" ]; then
			echo "  il kernel non ha riletto la tabella: lascio fare al device" >&2
		else
			# e2fsck -p esce 1 quando ha corretto qualcosa: e' successo, non
			# errore. Solo da 2 in su c'e' davvero un problema.
			e2fsck -f -p "${P2}" >/dev/null 2>&1; fsck_rc=$?
			if [ "${fsck_rc}" -le 1 ] && resize2fs "${P2}" >/dev/null 2>&1; then
				RESIZED="si"
				echo "  ${P2}: da $((before / 1024 / 1024)) MB a $((after / 1024 / 1024)) MB"
			else
				echo "  ATTENZIONE: partizione allargata ma il filesystem no (e2fsck=${fsck_rc})." >&2
			fi
		fi
	else
		echo "  parted non e' riuscito a spostare la fine della partizione 2." >&2
	fi
else
	echo "  mancano parted / resize2fs / e2fsck sul PC: lo fara' il device al primo avvio"
fi

echo "[6/6] abilito ssh"
# Due strade, secondo che il resize sia gia' fatto o no.
M="$(mktemp -d)"
if [ "${RESIZED}" = "si" ] && mount -t ext4 "${P2}" "${M}" 2>/dev/null; then
	# Resize fatto: il marcatore non serve piu' e va tolto, altrimenti al primo
	# avvio il generatore dirotta su fs-resize.target, che trovando .cache si
	# rifiuta, riavvia e ci fa perdere un giro per niente.
	rm -f "${M}/.please_resize_me"
	mkdir -p "${M}/.cache/services"
	touch "${M}/.cache/services/sshd.conf"
	sync
	umount "${M}"
	echo "  flag ssh scritto in /storage, marcatore di resize rimosso"
else
	# Resize non fatto: NON si tocca /storage (bloccherebbe fs-resize). Si usa
	# /flash/firstboot.sh, che fs-resize esegue DOPO aver ridimensionato.
	T="$(mktemp)"
	cat > "${T}" <<'FIRSTBOOT'
#!/bin/sh
# devaOS RF35H: eseguito una volta da fs-resize, dopo il ridimensionamento,
# con /storage montata. Accende ssh con il flag che il menu di Lakka legge.
mkdir -p /storage/.cache/services
touch /storage/.cache/services/sshd.conf
FIRSTBOOT
	if mcopy -o -i "${P1}" "${T}" ::/firstboot.sh 2>/dev/null; then
		echo "  /flash/firstboot.sh scritto: ssh acceso dopo il resize del primo avvio"
	else
		echo "  ATTENZIONE: non riesco a scrivere firstboot.sh sulla FAT" >&2
		echo "  ssh restera' spento; si accende da Settings > Services" >&2
	fi
	rm -f "${T}"
fi
rmdir "${M}" 2>/dev/null
sync

echo
echo "Fatto. Estrai la card solo dopo che il LED del lettore ha smesso."
