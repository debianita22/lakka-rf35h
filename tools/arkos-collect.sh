#!/bin/sh
# arkos-collect.sh - da eseguire su ArkOS4Clone via ssh, come root.
#
#   scp arkos-collect.sh ark@<ip>:/tmp/ && ssh ark@<ip> 'sudo sh /tmp/arkos-collect.sh'
#   poi:  scp ark@<ip>:/tmp/arkos-dump.tar.gz .
#
# ArkOS ha audio e vibrazione funzionanti sullo stesso hardware: qui si
# fotografa TUTTO cio' che conta - registri del codec e dell'I2S mentre suona,
# mixer, clock, stato del GPIO dell'amplificatore, come il driver pilota il
# motore - per confrontarlo con la nostra Lakka mainline. Non modifica nulla,
# a parte fermare il frontend per pochi secondi e riprodurre un tono.
set -u
OUT=/tmp/arkos-dump; rm -rf "$OUT"; mkdir -p "$OUT"
log() { echo "$*" | tee -a "$OUT/00-riassunto.txt"; }
run() { # run <nomefile> <comando...>
	f="$OUT/$1"; shift; { echo "\$ $*"; "$@" 2>&1; } > "$f"; echo "  $(basename "$f")"; }

mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
log "=== ArkOS4Clone dump  $(date)"
log "kernel: $(uname -r)   modello: $(tr -d '\0' < /proc/device-tree/model 2>/dev/null)"

echo "--- sistema"
run 01-uname.txt uname -a
run 02-dmesg-audio.txt sh -c "dmesg | grep -iE 'rk817|i2s|codec|asoc|sound|simple-card|joypad|rumble|pwm|gpio'"
run 03-lsmod.txt sh -c "lsmod"
run 04-cmdline.txt cat /proc/cmdline

echo "--- ALSA a riposo"
run 10-cards.txt cat /proc/asound/cards
run 11-amixer-contents.txt amixer -c 0 contents
run 12-amixer-scontents.txt amixer -c 0 scontents
run 13-pcm-info.txt sh -c "cat /proc/asound/card0/pcm0p/info; cat /proc/asound/card0/pcm0p/sub0/hw_params"

echo "--- registri del codec rk817 A RIPOSO (regmap del PMIC su i2c0 @0x20)"
R=""; for d in /sys/kernel/debug/regmap/*0020* /sys/kernel/debug/regmap/rk817* /sys/kernel/debug/regmap/*rk8*; do [ -r "$d/registers" ] && R="$d/registers" && break; done
if [ -n "$R" ]; then
	run 20-codec-regs-idle.txt sh -c "awk '{ split(\$1,a,\":\"); if (strtonum(\"0x\" a[1]) >= 0x12 && strtonum(\"0x\" a[1]) <= 0x4e) print }' $R 2>/dev/null || sed -n '/^12:/,/^4e:/p' $R"
	log "regmap codec: $R"
else
	# ripiego: i2c-tools
	if command -v i2cget >/dev/null 2>&1; then
		{ r=18; while [ $r -le 78 ]; do printf '0x%02x = %s\n' $r "$(i2cget -y 0 0x20 $r 2>/dev/null)"; r=$((r+1)); done; } > "$OUT/20-codec-regs-idle.txt"; log "codec via i2cget"
	else
		log "ATTENZIONE: ne' regmap debugfs ne' i2cget: registri del codec non letti"
	fi
fi

echo "--- I2S e clock a riposo"
for d in /sys/kernel/debug/regmap/ff070000.i2s /sys/kernel/debug/regmap/*i2s*; do [ -r "$d/registers" ] && run 21-i2s-regs-idle.txt cat "$d/registers" && break; done
run 22-clk-audio-idle.txt sh -c "grep -E 'i2s|mclk|dpll|ddr|gpll|cpll|npll' /sys/kernel/debug/clk/clk_summary"

echo "--- GPIO: amplificatore (gpio3 A7 = 103) e motore (gpio3 A6 = 102) a riposo"
run 23-gpio-idle.txt sh -c "grep -E 'gpio-10[0-9]|spk|amp|rumble|vibr' /sys/kernel/debug/gpio; echo ---; cat /sys/kernel/debug/gpio | sed -n '/gpiochip3/,/gpiochip4/p'"

echo "--- fermo il frontend e SUONO un tono (registri mentre suona)"
systemctl stop emulationstation 2>/dev/null || systemctl stop retroarch 2>/dev/null || true
sleep 1
speaker-test -D hw:0 -c2 -t sine -f 440 -l 40 >/dev/null 2>&1 &
SPK=$!
sleep 3
[ -n "$R" ] && run 30-codec-regs-playing.txt sh -c "sed -n '/^12:/,/^4e:/p' $R"
for d in /sys/kernel/debug/regmap/ff070000.i2s /sys/kernel/debug/regmap/*i2s*; do [ -r "$d/registers" ] && run 31-i2s-regs-playing.txt cat "$d/registers" && break; done
run 32-hw-params-playing.txt cat /proc/asound/card0/pcm0p/sub0/hw_params
run 33-amixer-playing.txt amixer -c 0 contents
run 34-gpio-playing.txt sh -c "grep -E 'gpio-10[0-9]|spk|amp' /sys/kernel/debug/gpio"
run 35-clk-audio-playing.txt sh -c "grep -E 'i2s|mclk' /sys/kernel/debug/clk/clk_summary"
kill $SPK 2>/dev/null; wait $SPK 2>/dev/null
sleep 1
run 36-gpio-after.txt sh -c "grep -E 'gpio-10[0-9]|spk|amp' /sys/kernel/debug/gpio"

echo "--- vibrazione: il driver ha un PWM? il GPIO oscilla o e' fisso?"
run 40-input-devices.txt cat /proc/bus/input/devices
run 41-pwm.txt sh -c "cat /sys/kernel/debug/pwm 2>/dev/null; ls /sys/class/pwm/ 2>/dev/null"
run 42-joypad-sysfs.txt sh -c "for d in /sys/devices/platform/*joypad* /sys/devices/platform/*gamepad*; do [ -d \"\$d\" ] && { echo \"== \$d\"; ls \"\$d\"; for f in \"\$d\"/*; do [ -f \"\$f\" ] && printf '%s = %s\n' \"\$(basename \"\$f\")\" \"\$(cat \"\$f\" 2>/dev/null | head -c 80)\"; done; }; done"
if command -v fftest >/dev/null 2>&1; then
	EV=$(grep -B4 "FF=" /proc/bus/input/devices | grep -oE "event[0-9]+" | head -1)
	[ -n "$EV" ] && run 43-fftest.txt sh -c "echo 4 | timeout 8 fftest /dev/input/$EV 2>&1 | head -30" && log "fftest su $EV"
fi
# campiono il GPIO del motore mentre un effetto e' in corso: se cambia valore
# fra un campione e l'altro e' PWM software, se resta fisso e' on/off
if [ -n "${EV:-}" ] && command -v fftest >/dev/null 2>&1; then
	( echo 4 | timeout 6 fftest /dev/input/$EV >/dev/null 2>&1 ) &
	sleep 1
	{ i=0; while [ $i -lt 40 ]; do grep -E "gpio-102" /sys/kernel/debug/gpio | grep -oE "(lo|hi)"; i=$((i+1)); done; } | sort | uniq -c > "$OUT/44-rumble-gpio-samples.txt"
	wait 2>/dev/null
	log "campioni GPIO motore durante l'effetto: $(tr '\n' ' ' < "$OUT/44-rumble-gpio-samples.txt")"
fi

echo "--- sorgenti di configurazione utili"
run 50-asound-conf.txt sh -c "cat /etc/asound.conf /home/ark/.asoundrc /etc/alsa/conf.d/* 2>/dev/null"
run 51-retroarch-audio-cfg.txt sh -c "grep -hE '^audio_|^input_rumble' /home/ark/.config/retroarch/retroarch.cfg /opt/*/retroarch.cfg 2>/dev/null"
run 52-dtb.txt sh -c "dtc -I fs -O dts /proc/device-tree 2>/dev/null | grep -A40 'codec {' | head -60"
run 53-headphone-script.txt sh -c "cat /usr/local/bin/*headphone* /usr/local/bin/*audio* 2>/dev/null | head -80"

systemctl start emulationstation 2>/dev/null || systemctl start retroarch 2>/dev/null || true

cd /tmp && tar czf arkos-dump.tar.gz arkos-dump && log "pronto: /tmp/arkos-dump.tar.gz ($(ls "$OUT" | wc -l) file)"
