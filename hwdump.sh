#!/bin/sh
# hwdump.sh - fotografa lo stato dell'hardware: registri GPIO, mux e pull del
# GRF, registri del RK817. Da eseguire su Lakka E su ArkOS4Clone, poi:
#
#   diff lakka.txt arkos.txt
#
# Le righe diverse sono i registri che un kernel imposta e l'altro no. E'
# l'unico confronto che resta quando device tree, byte, baud e pin sono
# identici e i LED si accendono solo da una parte.
#
# Su ArkOS (Ubuntu) se manca devmem: sudo apt install busybox  oppure usa
# python3, che lo script prova da solo come ripiego.

OUT="${1:-/tmp/hwdump-$(uname -r | cut -c1-4).txt}"

rd() {   # legge una word a 32 bit da /dev/mem
	if command -v devmem >/dev/null 2>&1; then devmem "$1" 32
	elif command -v busybox >/dev/null 2>&1 && busybox devmem "$1" 32 >/dev/null 2>&1; then busybox devmem "$1" 32
	elif command -v python3 >/dev/null 2>&1; then
		python3 -c "import mmap,struct,sys;a=int(sys.argv[1],16);f=open('/dev/mem','r+b',0);m=mmap.mmap(f.fileno(),4096,offset=a&~0xfff);print('0x%08X'%struct.unpack_from('<I',m,a&0xfff)[0])" "$1"
	else echo "?"; fi
}

dump_range() {   # nome base offset_fine
	printf '\n=== %s (%s)\n' "$1" "$2"
	base=$(( $2 )); end=$(( $3 )); o=0
	while [ "$o" -le "$end" ]; do
		addr=$(printf '0x%x' $(( base + o )))
		printf '  +0x%03x  %s\n' "$o" "$(rd "$addr")"
		o=$(( o + 4 ))
	done
}

{
echo "# hwdump  $(uname -a)"
echo "# $(cat /etc/os-release 2>/dev/null | grep -E '^(NAME|VERSION)=' | tr '\n' ' ')"

# I quattro banchi GPIO del PX30. Offset che contano:
#   0x00 SWPORTA_DR  (valore di uscita)   0x04 SWPORTA_DDR (direzione, 1=out)
#   0x50 EXT_PORTA   (valore letto sul pin)
dump_range "GPIO0" 0xff040000 0x60
dump_range "GPIO1" 0xff250000 0x60
dump_range "GPIO2" 0xff260000 0x60
dump_range "GPIO3" 0xff270000 0x60

# GRF: iomux e pull di GPIO1..3 (i primi 0x200), e PMUGRF per GPIO0.
dump_range "GRF"    0xff140000 0x1fc
dump_range "PMUGRF" 0xff010000 0x0fc

echo; echo "=== RK817 (regmap via debugfs)"
mount -t debugfs none /sys/kernel/debug 2>/dev/null
found=0
for d in /sys/kernel/debug/regmap/*0020*; do
	[ -f "$d/registers" ] && { echo "--- $d"; cat "$d/registers"; found=1; }
done 2>/dev/null
[ "$found" = 1 ] || echo "  (regmap del PMIC non esposto)"

echo; echo "=== pinmux (debugfs)"
cat /sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null | grep -vE "UNCLAIMED\)$" | head -80

echo; echo "=== gpio richiesti (debugfs)"
cat /sys/kernel/debug/gpio 2>/dev/null

echo; echo "=== regolatori"
for r in /sys/class/regulator/regulator.*; do
	printf '  %-16s %-9s %s\n' "$(cat $r/name 2>/dev/null)" "$(cat $r/state 2>/dev/null)" "$(cat $r/microvolts 2>/dev/null)"
done
} > "$OUT" 2>&1

echo "scritto $OUT ($(wc -l < "$OUT") righe)"
