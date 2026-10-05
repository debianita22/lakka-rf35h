#!/bin/sh
# rf35h-compare-images.sh - cosa cambia fra due immagini costruite.
#
#   sh rf35h-compare-images.sh <vecchia> <nuova> [cartella-output]
#
# <vecchia> e <nuova>: Lakka-*.tar, Lakka-*.img.gz o Lakka-*.img.
# Nasce dallo standby (5/10/2026): funzionava con le build locali, non con la
# v1.0.0, la prima costruita da zero in CI. Le build locali riusano i pacchetti
# gia' costruiti quando cambiano solo le options del device (lo stamp non le
# copre: vedi 4ea5cc1), quindi fra le due immagini puo' esserci molto piu' di
# quanto dica il log dei commit. Qui si guarda il contenuto, non la storia.
#
# Cosa confronta:
#   - os-release, versione e configurazione del kernel (IKCONFIG, se c'e');
#   - il device tree, decompilato;
#   - l'elenco dei file del SYSTEM con le dimensioni (date escluse);
#   - il contenuto dei file di configurazione cambiati (etc/, unita' systemd,
#     sway, udev, modprobe), e lo sha256 delle librerie grafiche, di sway,
#     wlroots e RetroArch.
#
# Serve: unsquashfs (squashfs-tools), dtc (device-tree-compiler), python3.
# Per un .img: mtools (mcopy), oppure sudo per montare la prima partizione.
# Niente viene scritto sulle immagini.
set -u

usage() { echo "uso: sh $0 <vecchia> <nuova> [cartella-output]" >&2; exit 1; }
[ $# -ge 2 ] || usage
OLD="$1"; NEW="$2"; OUT="${3:-./confronto-immagini}"
for f in "${OLD}" "${NEW}"; do [ -f "${f}" ] || { echo "non trovo ${f}" >&2; exit 1; }; done
for t in unsquashfs dtc python3; do
	command -v "${t}" >/dev/null 2>&1 || { echo "manca ${t}" >&2; exit 2; }
done
mkdir -p "${OUT}"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

# Estrae KERNEL, SYSTEM e i .dtb di un'immagine in $2.
extract() {
	img="$1"; d="$2"; mkdir -p "${d}"
	case "${img}" in
	*.tar)
		tar -xf "${img}" -C "${d}" --wildcards '*/KERNEL' '*/SYSTEM' '*.dtb' 2>/dev/null \
			|| tar -xf "${img}" -C "${d}" 2>/dev/null
		;;
	*.img.gz|*.img)
		raw="${d}/disk.img"
		case "${img}" in *.gz) zcat "${img}" > "${raw}" ;; *) ln -s "$(readlink -f "${img}")" "${raw}" ;; esac
		# offset della prima partizione dalla tabella MBR
		off="$(python3 -c 'import sys,struct
b=open(sys.argv[1],"rb").read(512)
print(struct.unpack_from("<I",b,446+8)[0]*512)' "${raw}")"
		if command -v mcopy >/dev/null 2>&1; then
			for n in KERNEL SYSTEM; do mcopy -n -i "${raw}@@${off}" "::${n}" "${d}/${n}" 2>/dev/null; done
			mcopy -n -i "${raw}@@${off}" '::*.dtb' "${d}/" 2>/dev/null
		else
			mkdir -p "${d}/p1"
			sudo mount -o ro,loop,offset="${off}" "${raw}" "${d}/p1" || return 1
			cp "${d}/p1/KERNEL" "${d}/p1/SYSTEM" "${d}/" 2>/dev/null
			cp "${d}"/p1/*.dtb "${d}/" 2>/dev/null
			sudo umount "${d}/p1"
		fi
		rm -f "${raw}"
		;;
	*) echo "formato non riconosciuto: ${img}" >&2; return 1 ;;
	esac
}

echo "estraggo le due immagini..."
extract "${OLD}" "${T}/a" || exit 1
extract "${NEW}" "${T}/b" || exit 1

pick() { find "$1" -name "$2" -type f | head -1; }

# configurazione del kernel incorporata (CONFIG_IKCONFIG): fra IKCFG_ST e IKCFG_ED
ikconfig() {
	python3 - "$1" <<'EOF'
import sys, gzip
d = open(sys.argv[1], "rb").read()
s = d.find(b"IKCFG_ST")
if s < 0:
    sys.exit(0)
e = d.find(b"IKCFG_ED", s)
try:
    sys.stdout.write(gzip.decompress(d[s + 8:e]).decode())
except Exception:
    pass
EOF
}

{
echo "== confronto: $(basename "${OLD}")  ->  $(basename "${NEW}")"
for side in a b; do
	k="$(pick "${T}/${side}" KERNEL)"
	echo "-- ${side}: $(strings "${k}" 2>/dev/null | grep -m1 'Linux version')"
done
} > "${OUT}/riassunto.txt"

# kernel config
ka="$(pick "${T}/a" KERNEL)"; kb="$(pick "${T}/b" KERNEL)"
ikconfig "${ka}" > "${T}/a.config"; ikconfig "${kb}" > "${T}/b.config"
if [ -s "${T}/a.config" ] && [ -s "${T}/b.config" ]; then
	diff "${T}/a.config" "${T}/b.config" | grep '^[<>] [C#]' > "${OUT}/kernel-config.diff"
else
	echo "IKCONFIG assente in almeno uno dei due kernel" > "${OUT}/kernel-config.diff"
fi

# device tree: tutti i .dtb con lo stesso nome
find "${T}/a" -name '*.dtb' -type f > "${T}/dtb.list"
while read -r da; do
	n="$(basename "${da}")"; db="$(pick "${T}/b" "${n}")"
	[ -n "${db}" ] || { echo "${n}: solo nella vecchia" >> "${OUT}/dtb.diff"; continue; }
	dtc -q -I dtb -O dts -s "${da}" > "${T}/a.dts" 2>/dev/null
	dtc -q -I dtb -O dts -s "${db}" > "${T}/b.dts" 2>/dev/null
	{ echo "### ${n}"; diff -u "${T}/a.dts" "${T}/b.dts"; } >> "${OUT}/dtb.diff"
done < "${T}/dtb.list"

# SYSTEM: elenco dei file (non delle cartelle) con dimensioni, senza date
sa="$(pick "${T}/a" SYSTEM)"; sb="$(pick "${T}/b" SYSTEM)"
for side in a b; do
	s="$(pick "${T}/${side}" SYSTEM)"
	unsquashfs -lls "${s}" 2>/dev/null \
		| awk '$1 ~ /^[-lcbps][rwx-]/ { p=$NF; if ($1 ~ /^l/) p=$(NF-2)" -> "$NF; print $1, $3, p }' \
		| sed 's,squashfs-root/,,' | sort -k3 > "${T}/${side}.list"
done
diff "${T}/a.list" "${T}/b.list" > "${OUT}/system-files.diff"

# file di configurazione cambiati o nuovi: contenuto
CONF='^(etc/|usr/lib/systemd/|usr/lib/udev/|usr/lib/modprobe.d/|usr/share/sway/|usr/lib/sway/|usr/share/retroarch/|usr/config/|usr/lib/tmpfiles.d/|usr/share/rf35h/)'
awk '$1 ~ /^-/ {print $3}' "${T}/b.list" | grep -E "${CONF}" > "${T}/conf.list"
: > "${OUT}/config-files.diff"
mkdir -p "${T}/xa" "${T}/xb"
unsquashfs -n -f -d "${T}/xa" -ef "${T}/conf.list" "${sa}" >/dev/null 2>&1
unsquashfs -n -f -d "${T}/xb" -ef "${T}/conf.list" "${sb}" >/dev/null 2>&1
while read -r f; do
	[ -f "${T}/xb/${f}" ] || continue
	if [ ! -e "${T}/xa/${f}" ]; then
		{ echo "### NUOVO ${f}"; head -c 4000 "${T}/xb/${f}"; echo; } >> "${OUT}/config-files.diff"
	elif ! cmp -s "${T}/xa/${f}" "${T}/xb/${f}"; then
		{ echo "### ${f}"; diff -u "${T}/xa/${f}" "${T}/xb/${f}" | head -200; } >> "${OUT}/config-files.diff"
	fi
done < "${T}/conf.list"

# binari del percorso grafico e di sospensione: sha256
BIN='(libgallium|libEGL|libGLES|libgbm|libvulkan|libwayland|libwlroots|libdrm|libpanfrost|panfrost_dri|libinput|libudev|libsystemd)[^/]*\.so|usr/bin/(sway|retroarch|rf35h-[a-z-]+)$|systemd-sleep|systemd-logind'
awk '$1 ~ /^-/ {print $3}' "${T}/a.list" "${T}/b.list" | grep -E "${BIN}" | sort -u > "${T}/bin.list"
rm -rf "${T}/xa" "${T}/xb"; mkdir -p "${T}/xa" "${T}/xb"
unsquashfs -n -f -d "${T}/xa" -ef "${T}/bin.list" "${sa}" >/dev/null 2>&1
unsquashfs -n -f -d "${T}/xb" -ef "${T}/bin.list" "${sb}" >/dev/null 2>&1
while read -r f; do
	ha="$( [ -f "${T}/xa/${f}" ] && sha256sum "${T}/xa/${f}" | cut -c1-12 || echo assente)"
	hb="$( [ -f "${T}/xb/${f}" ] && sha256sum "${T}/xb/${f}" | cut -c1-12 || echo assente)"
	[ "${ha}" = "${hb}" ] && st="uguale" || st="DIVERSO"
	printf '%-8s %-12s %-12s %s\n' "${st}" "${ha}" "${hb}" "${f}"
done < "${T}/bin.list" > "${OUT}/binari.txt"

{
echo "file solo nella vecchia: $(grep -c '^<' "${OUT}/system-files.diff")  solo/cambiati nella nuova: $(grep -c '^>' "${OUT}/system-files.diff")"
echo "kernel config, righe diverse: $(grep -c '' "${OUT}/kernel-config.diff")"
echo "device tree, righe diverse: $(grep -c '^[-+][^-+]' "${OUT}/dtb.diff" 2>/dev/null || echo 0)"
echo "file di configurazione cambiati o nuovi: $(grep -c '^### ' "${OUT}/config-files.diff")"
echo "binari grafici/sospensione diversi: $(grep -c '^DIVERSO' "${OUT}/binari.txt")"
} >> "${OUT}/riassunto.txt"
cat "${OUT}/riassunto.txt"
( cd "$(dirname "${OUT}")" && tar -czf "$(basename "${OUT}").tar.gz" "$(basename "${OUT}")" )
echo "tutto in ${OUT}/ e ${OUT}.tar.gz (da allegare)"
