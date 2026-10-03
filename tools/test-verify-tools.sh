#!/bin/bash
# test-verify-tools.sh - prove dei controlli di fine build, senza una build:
# verify-kernel.sh su un albero finto, verify-image.sh su un'immagine finta
# (SYSTEM squashfs vero dentro un .tar vero), build-lakka-rf35h.sh
# --verify-only sopra entrambi, e la firma dell'overlay da due percorsi.
#
#   ./tools/test-verify-tools.sh
#
# Nasce da due difetti che nessuno aveva mai visto scattare, perche' questi
# percorsi girano solo a fine build: verify-kernel prendeva
# build.*/install_pkg/linux-7.2.7 (stesso nome del sorgente, nessun sorgente
# dentro) e dava 20 MANCA su un kernel giusto; la verifica dell'immagine a fine
# build cercava lo script in un percorso che non esiste e non era mai girata.
#
# L'albero "buono" si costruisce leggendo le righe check di verify-kernel.sh:
# un controllo aggiunto la' e' coperto qui senza toccare il test.
# La parte immagine richiede mksquashfs e unsquashfs (squashfs-tools).
#
# D, rc, s0 si leggono dentro eval (le righe check e le condizioni di ok):
# shellcheck disable=SC2034
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
pass=0; fail=0; skip=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
nocolor() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- albero finto ----------------------------------------------------------------
W="${T}/w/lakka-rf35h-build"
B="${W}/build.Lakka-RK3326.aarch64"
K="${B}/build/linux-7.2.7"
D="${K}/arch/arm64/boot/dts/rockchip"
mkdir -p "${W}/packages" "${B}/build/linux-7.0.1" "${B}/install_pkg/linux-7.2.7/usr/lib"
# ogni check "marcatore" "file" "descrizione": il marcatore, senza ancore, nel file
grep -E '^check ' "${O}/verify-kernel.sh" > "${T}/checks"
while IFS= read -r line; do
	eval "set -- ${line#check }"
	pat="${1#^}"; pat="${pat%\$}"
	mkdir -p "$(dirname "$2")"
	printf '%s\n' "${pat}" >> "$2"
done < "${T}/checks"
nchk="$(wc -l < "${T}/checks")"

vk() { sh "${O}/verify-kernel.sh" "${W}" > "${T}/vk.out" 2>&1; echo $?; }
echo "verify-kernel (${nchk} controlli letti dallo script)"
rc="$(vk)"
ok "albero buono: esce 0" '[ "${rc}" = 0 ]'
ok "sceglie build/linux-7.2.7, non install_pkg ne' la 7.0.1" 'grep -q "^kernel: .*/build/linux-7.2.7$" "${T}/vk.out"'
f="${K}/include/linux/mmc/host.h"; cp "${f}" "${T}/bak"; : > "${f}"
rc="$(vk)"; cp "${T}/bak" "${f}"
ok "un marcatore tolto: esce 1 e lo nomina" '[ "${rc}" = 1 ] && grep -q "r-024 hack SDIO.*MANCA" "${T}/vk.out"'
echo "Switch to cmd mode for panel-bridge" >> "${K}/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c"
rc="$(vk)"; sed -i '/Switch to cmd mode for panel-bridge/d' "${K}/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c"
ok "riga vecchia di r-025 presente: esce 1" '[ "${rc}" = 1 ] && grep -q "ANCORA PRESENTE" "${T}/vk.out"'
f="${K}/drivers/gpu/drm/bridge/synopsys/dw-mipi-dsi.c"; mv "${f}" "${T}/dsi"; rc="$(vk)"; mv "${T}/dsi" "${f}"
ok "controllo negativo di r-025 senza il file: non passa" '[ "${rc}" = 1 ] && grep -q "riga vecchia rimossa *MANCA" "${T}/vk.out"'
mv "${B}/build" "${T}/build.off"; rc="$(vk)"; mv "${T}/build.off" "${B}/build"
ok "sorgente assente (solo install_pkg): esce 2, non 1" '[ "${rc}" = 2 ]'

# --- board e immagine finte ----------------------------------------------------------
BOARD="${T}/board"; mkdir -p "${BOARD}/loader"
head -c 65536 /dev/urandom > "${BOARD}/loader/known-good.bin"
( cd "${BOARD}/loader" && sha256sum known-good.bin > known-good.sha256 )

mkimg() { # nome, loader, drop-in timesyncd, quanti script[, core dei giochi]
	local r="${T}/root-$1" t="${T}/tar-$1" g
	mkdir -p "${r}/usr/share/bootloader" "${r}/usr/bin" "${r}/usr/lib/libretro" \
		"${r}/usr/lib/systemd/system/systemd-timesyncd.service.d" \
		"${r}/usr/lib/systemd/system/retroarch.service.d" "${t}/$1/target"
	for g in ${5:-}; do echo core > "${r}/usr/lib/libretro/${g}_libretro.so"; done
	cp "$2" "${r}/usr/share/bootloader/u-boot-rockchip.bin"
	echo dtb > "${r}/usr/share/bootloader/rk3326-xifan-rf35h.dtb"
	cp "$3" "${r}/usr/lib/systemd/system/systemd-timesyncd.service.d/rf35h-timesyncd.conf"
	cp "${O}/packages/rf35h-utils/retroarch.service.d/rf35h-crashlog.conf" \
		"${r}/usr/lib/systemd/system/retroarch.service.d/"
	ls "${O}/packages/rf35h-utils/scripts/" | head -n "$4" \
		| while read -r s; do cp "${O}/packages/rf35h-utils/scripts/${s}" "${r}/usr/bin/"; done
	mksquashfs "${r}" "${t}/$1/target/SYSTEM" -comp zstd -noappend -quiet >/dev/null 2>&1 \
		|| mksquashfs "${r}" "${t}/$1/target/SYSTEM" -noappend >/dev/null 2>&1
	echo kernel > "${t}/$1/target/KERNEL"
	mkdir -p "${W}/target"
	tar -C "${t}" -cf "${W}/target/$1.tar" "$1"
	echo img | gzip > "${W}/target/$1.img.gz"
}

vi() { sh "${O}/tools/verify-image.sh" "$1" "${BOARD}" > "${T}/vi.out" 2>&1; echo $?; }
if command -v mksquashfs >/dev/null 2>&1 && command -v unsquashfs >/dev/null 2>&1; then
	echo "verify-image (SYSTEM squashfs vero)"
	TS="${O}/packages/rf35h-utils/timesyncd.d/rf35h-timesyncd.conf"
	printf '[Unit]\nAfter=network-online.target\n' > "${T}/ts-bad.conf"
	head -c 4096 /dev/urandom > "${T}/bad-loader.bin"
	G=Lakka-RK3326.aarch64-Next-devel-20260925160538-e2cf2e5-rf35h
	mkimg "${G}" "${BOARD}/loader/known-good.bin" "${TS}" 99
	ok "immagine buona: conforme" '[ "$(vi "${W}/target/${G}.tar")" = 0 ] && grep -q "^Conforme" "${T}/vi.out"'
	mkimg bad-loader "${T}/bad-loader.bin" "${TS}" 99
	ok "loader diverso dal known-good: NO" '[ "$(vi "${W}/target/bad-loader.tar")" = 1 ] && grep -q "loader DIVERSO" "${T}/vi.out"'
	mkimg bad-ts "${BOARD}/loader/known-good.bin" "${T}/ts-bad.conf" 99
	ok "timesyncd dopo la rete: NO" '[ "$(vi "${W}/target/bad-ts.tar")" = 1 ] && grep -q "ordina dopo la rete" "${T}/vi.out"'
	mkimg few "${BOARD}/loader/known-good.bin" "${TS}" 5
	ok "pochi script rf35h-*: NO" '[ "$(vi "${W}/target/few.tar")" = 1 ] && grep -q "solo 5 script" "${T}/vi.out"'
	# i giochi: RF35H_GAMES la mette build-lakka-rf35h.sh a fine build
	vig() { RF35H_GAMES="$1" sh "${O}/tools/verify-image.sh" "$2" "${BOARD}" > "${T}/vi.out" 2>&1; echo $?; }
	ok "senza RF35H_GAMES i giochi si elencano e basta" '[ "$(vi "${W}/target/${G}.tar")" = 0 ] && grep -q "giochi nell.immagine: nessuno" "${T}/vi.out"'
	mkimg games "${BOARD}/loader/known-good.bin" "${TS}" 99 "gtasa deva_adventures"
	ok "giochi attesi presenti (letti dal SYSTEM): conforme" '[ "$(vig "gtasa deva_adventures" "${W}/target/games.tar")" = 0 ] && grep -q "gioco deva_adventures: deva_adventures_libretro.so presente" "${T}/vi.out"'
	ok "un gioco atteso manca: NO e lo nomina" '[ "$(vig "gtasa re3" "${W}/target/games.tar")" = 1 ] && grep -q "gioco re3: re3_libretro.so assente" "${T}/vi.out"'
	ok "RF35H_GAMES vuota (tutti --no-...): conforme" '[ "$(vig "" "${W}/target/${G}.tar")" = 0 ] && grep -q "nessun gioco atteso" "${T}/vi.out"'
	rm -f "${W}"/target/bad-* "${W}"/target/few.* "${W}"/target/games.*

	# --- build-lakka-rf35h.sh --verify-only ------------------------------------------
	miss=""
	for t in git make gcc patch python3 tar xz sha256sum; do command -v "$t" >/dev/null || miss="${miss} $t"; done
	if [ -z "${miss}" ]; then
		echo "build-lakka-rf35h.sh --verify-only"
		vo() { ( cd "${T}/w" && bash "${O}/build-lakka-rf35h.sh" --deva "${BOARD}" --verify-only ) 2>&1 | nocolor > "${T}/vo.out"; echo "${PIPESTATUS[0]}"; }
		ok "albero e immagine buoni: esce 0" '[ "$(vo)" = 0 ] && grep -q "kernel e immagine conformi" "${T}/vo.out"'
		# un'immagine rotta piu' recente: deve essere lei quella controllata
		mkimg "${G/20260925160538/20260926100000}" "${T}/bad-loader.bin" "${TS}" 99
		ok "l'immagine piu' recente e' rotta: esce 1, NON conforme" '[ "$(vo)" = 1 ] && grep -q "20260926100000" "${T}/vo.out" && grep -q "NON e. conforme" "${T}/vo.out"'
		rm -f "${W}"/target/*20260926100000*
		mv "${W}/target/${G}.tar" "${T}/"
		ok "manca il .tar: esce 1 senza dare esiti" '[ "$(vo)" = 1 ] && grep -q "nessun esito" "${T}/vo.out"'
		mv "${T}/${G}.tar" "${W}/target/"
		ok "niente e' stato clonato o applicato" '[ ! -e "${W}/.git" ] && [ ! -e "${W}/.rf35h-applied" ]'
	else
		skip=$((skip + 1)); echo "  (salto --verify-only: mancano${miss})"
	fi
else
	skip=$((skip + 1)); echo "  (salto verify-image: serve squashfs-tools)"
fi

# --- firma dell'overlay ------------------------------------------------------------
echo "firma dell'overlay"
eval "$(sed -n '/^OVERLAY_TREE_PATHS=/,/^}/p' "${O}/build-lakka-rf35h.sh")"
sig() { OVERLAY="$1" CORE_LTO="${2:-yes}" RE3_PKG="${3:-}" overlay_sig; }
mkdir -p "${T}/a" "${T}/b/piu/profondo"
cp -a "${O}" "${T}/a/lakka-rf35h"; cp -a "${O}" "${T}/b/piu/profondo/lakka-rf35h"
A="${T}/a/lakka-rf35h"; BB="${T}/b/piu/profondo/lakka-rf35h"
s0="$(sig "${A}")"
ok "stessa firma da due percorsi" '[ -n "${s0}" ] && [ "${s0}" = "$(sig "${BB}")" ]'
echo x >> "${BB}/README.md"; echo x >> "${BB}/tools/verify-image.sh"; echo x >> "${BB}/verify-kernel.sh"
ok "README, tools/ e script fuori dall'albero non contano" '[ "${s0}" = "$(sig "${BB}")" ]'
ok "--no-core-lto cambia la firma" '[ "${s0}" != "$(sig "${A}" no)" ]'
echo x >> "${BB}/apply.sh"
ok "apply.sh conta" '[ "${s0}" != "$(sig "${BB}")" ]'
cp -p "${A}/apply.sh" "${BB}/apply.sh"; chmod -x "${BB}/packages/rf35h-utils/scripts/rf35h-led"
ok "il modo di un file conta" '[ "${s0}" != "$(sig "${BB}")" ]'
chmod +x "${BB}/packages/rf35h-utils/scripts/rf35h-led"; echo x >> "${BB}/packages/rf35h-utils/scripts/rf35h-led"
ok "un file dei pacchetti conta" '[ "${s0}" != "$(sig "${BB}")" ]'
# re3 viene da fuori (--re3): conta cio' che apply.sh ne copia, non il resto
R3T="${T}/re3pkg"; mkdir -p "${R3T}/files" "${R3T}/patches" "${R3T}/pgo"
echo 'PKG_NAME="re3"' > "${R3T}/package.mk"; echo info > "${R3T}/files/re3_libretro.info"; echo p > "${R3T}/patches/0001.patch"
r0="$(sig "${A}" yes "${R3T}")"
ok "--re3 cambia la firma" '[ "${r0}" != "$(sig "${A}")" ]'
echo x >> "${R3T}/patches/0001.patch"
ok "una patch di re3 cambia la firma" '[ "${r0}" != "$(sig "${A}" yes "${R3T}")" ]'
r1="$(sig "${A}" yes "${R3T}")"; echo x > "${R3T}/README.md"; echo x > "${R3T}/pgo/build-pgo.sh"
ok "README e pgo/ di re3 non contano" '[ "${r1}" = "$(sig "${A}" yes "${R3T}")" ]'

# --- giochi attesi a fine build ------------------------------------------------------
echo "giochi attesi a fine build"
eval "$(sed -n '/^games_on() {/,/^}/p;/^drop_extra() {/,/^}/p' "${O}/build-lakka-rf35h.sh")"
WITH_GTASA=yes; WITH_RE3=yes; WITH_OPENXEENNG=yes; WITH_DEVA=yes
ok "tutti accesi: i quattro core" '[ "$(games_on)" = "gtasa re3 openxeenng deva_adventures" ]'
drop_extra openxeenng
ok "--keep-going che toglie openxeenng: non piu' atteso" '[ "$(games_on)" = "gtasa re3 deva_adventures" ]'
WITH_GTASA=no; WITH_RE3=no; WITH_DEVA=no
ok "i --no-... di tutti: nessuno" '[ -z "$(games_on)" ]'
ok "RF35H_GAMES a fine build, non con --verify-only" 'sed -n "/^check_image() {/,/^}/p" "${O}/build-lakka-rf35h.sh" | grep -q "RF35H_GAMES=\"\$(games_on)\" sh" && [ "$(sed -n "/^check_image() {/,/^}/p" "${O}/build-lakka-rf35h.sh" | grep -c "verify-image.sh")" = 2 ]'

if [ "${skip}" = 0 ]; then echo "--- ${pass} ok, ${fail} falliti"; else echo "--- ${pass} ok, ${fail} falliti, ${skip} parti saltate"; fi
[ "${fail}" = 0 ]
