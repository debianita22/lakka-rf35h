#!/bin/sh
# rf35h-rescue.sh - card nel lettore del PC, niente GUI e niente ssh sul device.
#
#   sudo sh rf35h-rescue.sh /dev/sdX  "NomeRete"  "password"
#
# Fa quattro cose, tutte dal PC:
#   1. copia qui i log che rf35h-bootlog ha gia' scritto in /storage/rf35h-logs
#   2. semina la rete Wi-Fi in connman con un file di provisioning, cosi' al
#      prossimo boot il device si collega da solo e ssh e' raggiungibile
#   3. si assicura che ssh sia acceso (flag che il menu di Lakka legge)
#   4. installa un autostart.sh usa-e-getta che, 45 s dopo il boot, scarica in
#      /storage/rescue/ il journal, lo stato di retroarch e un tentativo di
#      retroarch --verbose: se ssh non dovesse comunque funzionare, basta
#      rimettere la card nel PC per leggere perche' RetroArch non parte.
# Se la partizione e' ancora da espandere (marcatore presente), la espande
# prima: altrimenti fs-resize al boot rifarebbe il filesystem cancellando tutto.
set -u
if [ $# -ne 3 ]; then
	echo "uso: sudo $0 /dev/sdX NomeRete password" >&2
	exit 1
fi
DEV="$1"; SSID="$2"; PASS="$3"
[ "$(id -u)" = 0 ] || { echo "serve root (sudo)"; exit 1; }
[ -b "$DEV" ] || { echo "$DEV non risulta un device a blocchi"; exit 1; }
if [ -b "${DEV}p2" ]; then P2="${DEV}p2"; else P2="${DEV}2"; fi
[ -b "$P2" ] || { echo "partizione 2 non trovata ($P2): card giusta?"; exit 1; }

# L'SSID in esadecimale: connman lo accetta cosi' con qualunque carattere.
HEX="$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')"

for p in "${DEV}"*; do [ "$p" = "$DEV" ] || umount "$p" 2>/dev/null; done
M="$(mktemp -d)"
mount -t ext4 "$P2" "$M" || { echo "non riesco a montare $P2"; exit 1; }
echo "[storage] $(df -h "$M" | tail -1 | awk '{print $2" totali, "$4" liberi"}')"

# --- 0. se il resize non e' mai avvenuto, farlo ora (senno' cancella tutto)
if [ -e "$M/.please_resize_me" ]; then
	echo "[resize] marcatore presente: la partizione e' ancora quella dell'immagine"
	umount "$M"
	before=$(blockdev --getsize64 "$P2")
	if parted -s -f "$DEV" resizepart 2 100% >/dev/null 2>&1; then
		partprobe "$DEV" >/dev/null 2>&1; sleep 1; udevadm settle 2>/dev/null
		after=$(blockdev --getsize64 "$P2")
		if [ "$after" -gt "$before" ]; then
			e2fsck -f -p "$P2" >/dev/null 2>&1; [ $? -le 1 ] && resize2fs "$P2" >/dev/null 2>&1 \
				&& echo "[resize] $((before/1024/1024)) -> $((after/1024/1024)) MB"
		fi
	fi
	mount -t ext4 "$P2" "$M" || exit 1
	rm -f "$M/.please_resize_me"
fi

# --- 1. i log gia' scritti dal device
OUT="./rf35h-rescue-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$OUT"
if [ -d "$M/rf35h-logs" ]; then
	cp -a "$M/rf35h-logs" "$OUT/" && echo "[log] copiati: $(ls "$M/rf35h-logs" | wc -l) file in $OUT/rf35h-logs/"
else
	echo "[log] nessun /storage/rf35h-logs (bootlog non ha girato o storage azzerata)"
fi
[ -d "$M/rescue" ] && cp -a "$M/rescue" "$OUT/" && echo "[log] c'era gia' una raccolta rescue precedente: copiata"

# --- 2. Wi-Fi in connman
# Un file di provisioning (connman-service.config), non la cartella
# wifi_<MAC>_<SSID>_managed_psk che scrive il menu: quella porta nel nome il
# MAC dell'interfaccia, e il MAC dell'RF35H e' diverso su ogni console (il
# driver rk915 lo ricava dall'ID della CPU nell'OTP del PX30, 02:xx:...).
# Senza "MAC =" connman lo usa per l'interfaccia Wi-Fi che trova, qualunque
# sia. Nome del file solo lettere e cifre (le versioni vecchie di connman
# non accettano altro). Una rete data cosi' e' "immutable": dal menu non si
# dimentica; per toglierla, via ssh: rm /storage/.cache/connman/rf35hrescue.config
# Nella password "\" va raddoppiato e gli spazi in testa e in coda scritti
# "\s": GKeyFile li toglierebbe.
PASS_KF="$(printf '%s' "$PASS" | sed 's/\\/\\\\/g; s/^ /\\s/; s/ $/\\s/')"
CFG="$M/.cache/connman/rf35hrescue.config"
mkdir -p "$M/.cache/connman"
{
	echo "[global]"
	echo "Description = rete seminata da rf35h-rescue.sh"
	echo
	echo "[service_rf35h_rescue]"
	echo "Type = wifi"
	echo "SSID = $HEX"
	# printf, non echo: l'echo di dash interpreta le "\"
	printf 'Passphrase = %s\n' "$PASS_KF"
} > "$CFG"
chmod 600 "$CFG"
echo "[wifi] seminata: $SSID (provisioning connman, per qualunque MAC)"

# --- 3. ssh acceso
mkdir -p "$M/.cache/services" && touch "$M/.cache/services/sshd.conf" && echo "[ssh] flag presente"

# --- 4. autostart usa-e-getta che raccoglie la diagnosi al prossimo boot
mkdir -p "$M/.config"
cat > "$M/.config/autostart.sh" <<'EOF'
#!/bin/sh
# rf35h rescue: raccoglie perche' RetroArch non parte, poi si toglie da solo.
# Gira PRIMA di retroarch.service; si stacca in background e aspetta.
(
	sleep 45
	R=/storage/rescue; mkdir -p "$R"
	journalctl -b --no-pager > "$R/journal.txt" 2>&1
	systemctl status retroarch --no-pager -l > "$R/retroarch-status.txt" 2>&1
	systemctl list-units --failed --no-pager > "$R/failed-units.txt" 2>&1
	systemctl status rf35h-audio rf35h-state rf35h-ledd rf35h-zram rf35h-ntp --no-pager > "$R/rf35h-units.txt" 2>&1
	dmesg > "$R/dmesg.txt" 2>&1
	# se retroarch e' morto, lo rilancio a mano in verboso per 25 s e catturo tutto
	if ! systemctl is-active retroarch >/dev/null 2>&1; then
		# niente "timeout" nella busybox di Lakka: background + sleep + kill
		retroarch --verbose > "$R/retroarch-verbose.txt" 2>&1 &
		rp=$!
		sleep 25
		kill "$rp" 2>/dev/null; wait "$rp" 2>/dev/null
		echo "exit=$?" >> "$R/retroarch-verbose.txt"
	fi
	cp /storage/.config/retroarch/retroarch-core-options.cfg "$R/" 2>/dev/null
	sync
	rm -f /storage/.config/autostart.sh   # usa-e-getta
) >/dev/null 2>&1 &
exit 0
EOF
chmod +x "$M/.config/autostart.sh"
echo "[autostart] installato: al prossimo boot scrive /storage/rescue/ e si rimuove"

sync; umount "$M"; rmdir "$M"
echo
echo "Fatto. Rimetti la card nel device, accendi e aspetta 2 minuti:"
echo "  - se ssh risponde ($SSID), incollami: systemctl status retroarch ; cat /storage/rescue/retroarch-verbose.txt"
echo "  - se no, spegni, card nel PC, e rilancia questo script: copia /storage/rescue/ in $OUT"
