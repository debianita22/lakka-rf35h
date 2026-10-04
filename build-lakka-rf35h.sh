#!/usr/bin/env bash
# build-lakka-rf35h.sh - costruisce l'immagine Lakka per l'XiFan RF35H.
#
#   ./build-lakka-rf35h.sh --deva ~/devaos/lume/buildroot-external/boards/rf35h
#
# Rieseguibile: l'albero Lakka e le patch vengono toccati una volta sola, e la
# build di LibreELEC e' incrementale. Se si interrompe, rilancia lo stesso
# comando e riprende.
#
# Richiede: ~100 GB liberi, host Linux x86_64, connessione (scarica sorgenti
# da parecchi host).

set -euo pipefail

LAKKA_COMMIT="e2cf2e5cc3bdbb274aac5e3b6849549f6995dca3"   # devel, 2026-05-09
LAKKA_REPO="https://github.com/libretro/Lakka-LibreELEC.git"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${PWD}/lakka-rf35h-build"
DEVA_BOARD=""
OVERLAY=""
JOBS=""
PKG_JOBS=""
# Set di core di default: per ogni sistema della collezione un core principale
# e almeno una riserva, scelti per quello che l'RK3326 regge. Verificati uno
# per uno nei loro package.mk e Makefile (vedi docs/diario.md, "Core").
#   SNES/SFC        snes9x2010 (veloce), snes9x (accurato), snes9x2005 (leggero)
#   GB/GBC          gambatte, sameboy, tgbdual
#   NES/Famicom     fceumm, nestopia
#   MAME            mame2010: l'UNICO per il romset 0.139. Riserva mame2015
#                   (0.160): buona parte dei set 0.139 carica ancora, non tutti.
#   Mega Drive      genesis_plus_gx, picodrive (blastem e' x86-only in Lakka)
#   Game Gear, SG-1000, Master System   genesis_plus_gx, gearsystem
#   Sega 32X        picodrive (unico core 32X in libretro)
#   GBA             mgba, gpsp (dynarec arm64; vbam e' piu' lento e meno preciso di entrambi)
#   PC Engine       beetle_pce_fast, beetle_pce (fa anche SuperGrafx)
#   Neo Geo, CPS1/2/3   fbneo, fbalpha2012; e mame2010 dal romset 0.139
#   N64             mupen64plus_next, parallel_n64 (unico altro core N64)
#   Neo Geo Pocket  beetle_ngp, race
#   Atari 2600      stella2014, stella
#   Nintendo DS     melonds (JIT arm64), melondsds (desmume e' un interprete: su un A35 non gira)
#   Amstrad CPC     cap32, crocods
#   Dreamcast       flycast (unico core Dreamcast)
# --all-cores per i ~120 di Lakka; --cores "..." per un elenco proprio.
CORES_DEFAULT="gambatte sameboy tgbdual fceumm nestopia genesis_plus_gx picodrive gearsystem snes9x2010 snes9x snes9x2005 mgba gpsp beetle_pce_fast beetle_pce fbneo fbalpha2012 mame2010 mame2015 mupen64plus_next parallel_n64 beetle_ngp race stella2014 stella melonds melondsds cap32 crocods flycast"
CORES="${CORES_DEFAULT}"
SKIP_CORES=""
KEEP_GOING="no"
KEEP_GOING_MAX=25
WITH_KMS="no"
CORE_LTO="yes"
WITH_VULKAN="yes"
WITH_IKEMEN="yes"
# i giochi fatti per questa console (options: RF35H_GTASA, RF35H_RE3,
# RF35H_OPENXEENNG, RF35H_DEVA_ADVENTURES). re3 c'e' solo con --re3: il suo
# pacchetto sta in un repository privato, non nell'overlay.
WITH_GTASA="yes"
WITH_RE3="yes"
RE3_PKG=""
WITH_OPENXEENNG="yes"
WITH_DEVA="yes"
SKIP_DEPS="no"
PIN="yes"
DRY_RUN="no"
VERIFY_ONLY="no"

usage() {
	cat <<'EOF'
Uso: ./build-lakka-rf35h.sh [opzioni]

  --deva <path>      una cartella con loader/known-good.bin e .sha256, per
                     esempio boards/rf35h di devaOS (default: board/ di
                     questo repository, lo stesso loader)
  --overlay <path>   cartella lakka-rf35h/ o il suo tar.gz
                     (default: ./lakka-rf35h oppure ./lakka-rf35h-overlay.tar.gz)
  --workdir <path>   dove clonare Lakka (default: ./lakka-rf35h-build)
  --jobs N           make -j dentro ogni pacchetto (default: 2)
  --pkg-jobs N       quanti pacchetti in parallelo (default: dai core e dalla
                     RAM, vedi sotto)
                     I due si MOLTIPLICANO. Il default era nproc per entrambi:
                     su 16 core fino a 256 compilatori insieme, e un link
                     con LTO (re3; Mesa e i core quando l'LTO sara' attivo
                     davvero, vedi docs/diario.md) puo' chiedere mezzo giga.
                     Ora il default e' --jobs 2 e --pkg-jobs pari al minore fra
                     i core e RAM/2 GB: cosi' il prodotto resta vicino ai core
                     veri e non si va in swap. Per spingere: --pkg-jobs 4
                     --jobs 4.
  --all-cores        tutti i ~120 core di Lakka per RK3326 (default: 30, con riserve)
  --skip-core NOME   esclude un core dalla build; ripetibile. Lakka applica
                     EXCLUDE_LIBRETRO_CORES dopo la lista, quindi vale sia con
                     --all-cores sia con --cores
  --keep-going       non fermarsi al primo core che non compila: lo esclude e
                     riprende, poi elenca alla fine quelli saltati
  --keep-going-max N quante riprese al massimo (default 25)
  --cores "a b c"    costruisci solo questi core libretro invece dei 30 di
                     default. Per una prima immagine di prova bastano:
                     --cores "gambatte fceumm genesis_plus_gx snes9x2010 mgba"
  --kms              applica anche optional/kms-no-compositor.patch
                     RetroArch su KMS senza sway. Non al primo tentativo.
  --no-core-lto      toglie l'LTO ai 19 core a cui lo mette l'overlay
                     (+lto: -flto con i -Werror di LibreELEC). Se un core
                     con LTO si comporta male sulla console
  --no-vulkan        immagine senza Vulkan (Mesa senza PanVK, RetroArch senza
                     il driver vulkan). Di default Vulkan c'e', come
                     alternativa: OpenGL ES resta il predefinito
  --no-ikemen        immagine senza IKEMEN GO (niente Go, niente screenpack)
  --no-gtasa         senza GTA: San Andreas (lanciatore per APK/OBB propri)
  --re3 <path>       con GTA III (re3): la cartella del pacchetto re3 (il
                     repository privato re3-rf35h). re3 non ha licenza:
                     l'immagine che lo contiene e' solo per uso personale
  --no-re3           senza re3 anche se --re3 c'e' (per un'immagine da dare
                     ad altri dallo stesso comando)
  --no-openxeenng    senza OpenXeenNG (e senza Rust per l'host)
  --no-deva-adventures  senza Deva's Awesome Adventures
  --skip-deps        non lanciare scripts/checkdeps
  --dry-run          prepara e verifica tutto, poi si ferma prima della build
  --verify-only      non costruisce ne' tocca l'albero: controlla l'ultima
                     immagine in target/ (verify-image) e il sorgente del
                     kernel (verify-kernel). Per un'immagine gia' fatta
  --no-pin           usa la punta di devel invece del commit pinnato
  -h, --help         questo messaggio
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--deva)    DEVA_BOARD="$2"; shift 2 ;;
		--overlay) OVERLAY="$2"; shift 2 ;;
		--workdir) WORKDIR="$2"; shift 2 ;;
		--jobs)     JOBS="$2"; shift 2 ;;
		--pkg-jobs) PKG_JOBS="$2"; shift 2 ;;
		--cores)    CORES="$2"; shift 2 ;;
		--all-cores) CORES=""; shift ;;   # vuoto = tutti quelli di Lakka
		--skip-core)
				[ -n "${2:-}" ] || { printf '\033[31m[x] %s\033[0m\n' "--skip-core vuole il nome di un core" >&2; exit 1; }
			SKIP_CORES="${SKIP_CORES} $2"; shift 2 ;;
		--keep-going) KEEP_GOING="yes"; shift ;;
		--keep-going-max)
			case "${2:-}" in ''|*[!0-9]*) printf '\033[31m[x] %s\033[0m\n' "--keep-going-max vuole un numero" >&2; exit 1 ;; esac
			KEEP_GOING_MAX="$2"; KEEP_GOING="yes"; shift 2 ;;
		--kms)     WITH_KMS="yes"; shift ;;
		--no-core-lto) CORE_LTO="no"; shift ;;
		--no-vulkan) WITH_VULKAN="no"; shift ;;
		--no-ikemen) WITH_IKEMEN="no"; shift ;;
		--no-gtasa) WITH_GTASA="no"; shift ;;
		--re3)
			[ -n "${2:-}" ] || { printf '\033[31m[x] %s\033[0m\n' "--re3 vuole la cartella del pacchetto re3" >&2; exit 1; }
			RE3_PKG="$2"; shift 2 ;;
		--no-re3) WITH_RE3="no"; shift ;;
		--no-openxeenng) WITH_OPENXEENNG="no"; shift ;;
		--no-deva-adventures) WITH_DEVA="no"; shift ;;
		--skip-deps) SKIP_DEPS="yes"; shift ;;
		--dry-run) DRY_RUN="yes"; SKIP_DEPS="yes"; shift ;;
		--verify-only) VERIFY_ONLY="yes"; shift ;;
		--no-pin)  PIN="no"; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "opzione sconosciuta: $1" >&2; usage; exit 1 ;;
	esac
done

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# Un percorso come lo vede chi ha lanciato. Nel container la cartella di lavoro
# e' /work: un comando suggerito con /work/... e incollato nella shell
# dell'host non trova niente. build-in-docker.sh passa il percorso vero.
hp() {
	if [ -n "${RF35H_HOST_WORK:-}" ]; then
		case "$1" in
			/work|/work/*) printf '%s\n' "${RF35H_HOST_WORK}${1#/work}"; return 0 ;;
		esac
	fi
	printf '%s\n' "$1"
}

# --- controlli sul risultato ----------------------------------------------------
# Usati a fine build e da --verify-only. Tornano 0 se conforme, 1 se qualcosa
# non va, 2 se non si e' potuto controllare: decide chi li chiama.

# L'immagine piu' recente per mtime, cosi' le build vecchie non confondono.
# IMAGE_NAME contiene "-${UBOOT_SYSTEM}" (scripts/image), quindi "rf35h" c'e'.
find_image() {
	IMG="$( { find "${WORKDIR}/target" -name '*rf35h*.img.gz' -printf '%T@ %p\n' 2>/dev/null \
		| sort -rn | head -1 | cut -d' ' -f2-; } || true )"
	TAR="${IMG%.img.gz}.tar"
}

# Le patch del kernel non si controllano da sole: unpack le applica senza
# guardare l'esito e build non guarda il suo. Una mancata applicazione uscirebbe
# come un kernel silenziosamente monco.
check_kernel() {
	[ -f "${OVERLAY}/verify-kernel.sh" ] || return 0
	say "Le patch del kernel sono finite nel sorgente?"
	sh "${OVERLAY}/verify-kernel.sh" "${WORKDIR}"
}

# L'immagine COSTRUITA: apre il SYSTEM e controlla che contenga quello che ci
# aspettiamo - sopra tutto che il loader li' dentro sia il known-good, perche'
# update.sh lo riscrive raw a 32K e un blob sbagliato rende il device non
# avviabile. Con "strict" (--verify-only) non poterla aprire e' un errore; a
# fine build e' un avviso, l'immagine c'e' comunque.
check_image() {
	find_image
	if [ -z "${IMG}" ]; then
		warn "nessuna immagine *rf35h*.img.gz in $(hp "${WORKDIR}/target")"
		return 2
	fi
	if [ ! -f "${TAR}" ]; then
		warn "manca $(basename "${TAR}") accanto a $(basename "${IMG}"): e' il .tar che si apre"
		return 2
	fi
	if ! command -v unsquashfs >/dev/null 2>&1 && ! command -v 7z >/dev/null 2>&1; then
		warn "unsquashfs assente: non posso aprire il SYSTEM dell'immagine."
		warn "  Debian/Ubuntu: squashfs-tools   Arch: squashfs-tools   (il container ce l'ha)"
		[ "${1:-}" = "strict" ] && return 2
		warn "salto la verifica dell'immagine"
		return 0
	fi
	say "Verifica dell'immagine costruita"
	if [ "${1:-}" = "strict" ]; then
		# --verify-only: con che opzioni e' stata fatta l'immagine non si sa,
		# quindi i giochi si elencano soltanto
		sh "${OVERLAY}/tools/verify-image.sh" "${TAR}" "${DEVA_BOARD}"
	else
		# a fine build si sa quali giochi devono esserci (tolti i --no-... e
		# quelli esclusi da --keep-going)
		RF35H_GAMES="$(games_on)" sh "${OVERLAY}/tools/verify-image.sh" "${TAR}" "${DEVA_BOARD}"
	fi
}

# L'ambiente di "make image" e del piano di build del dry run: lo stesso,
# ricostruito prima di ogni giro (--keep-going cambia SKIP_CORES e i WITH_*).
build_env() {
	BENV=(PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 UBOOT_SYSTEM=rf35h
		BUILDER_NAME=lakka-rf35h
		RF35H_VULKAN="${WITH_VULKAN}" RF35H_IKEMEN="${WITH_IKEMEN}"
		RF35H_GTASA="${WITH_GTASA}" RF35H_RE3="${WITH_RE3}"
		RF35H_OPENXEENNG="${WITH_OPENXEENNG}" RF35H_DEVA_ADVENTURES="${WITH_DEVA}")
	if [ -n "${RF35H_VERSION:-}" ]; then BENV+=(CUSTOM_VERSION="${RF35H_VERSION}"); fi
	if [ -n "${OVERLAY_REV:-}" ]; then BENV+=(BUILDER_VERSION="${OVERLAY_REV}"); fi
	if [ -n "${JOBS}" ]; then BENV+=(CONCURRENCY_MAKE_LEVEL="${JOBS}"); fi
	if [ -n "${PKG_JOBS}" ]; then BENV+=(THREADCOUNT="${PKG_JOBS}"); fi
	if [ -n "${CORES}" ]; then BENV+=(CUSTOM_LIBRETRO_CORES="${CORES}"); fi
	if [ -n "${SKIP_CORES}" ]; then BENV+=(EXCLUDE_LIBRETRO_CORES="${SKIP_CORES# }"); fi
}

# i giochi accesi, coi nomi dei loro core (<nome>_libretro.so)
games_on() {
	local g=""
	if [ "${WITH_GTASA}" = "yes" ]; then g="${g} gtasa"; fi
	if [ "${WITH_RE3}" = "yes" ]; then g="${g} re3"; fi
	if [ "${WITH_OPENXEENNG}" = "yes" ]; then g="${g} openxeenng"; fi
	if [ "${WITH_DEVA}" = "yes" ]; then g="${g} deva_adventures"; fi
	echo "${g# }"
}

# --- preflight ---------------------------------------------------------------
say "Controlli preliminari"

if [ -n "${DEVA_BOARD}" ]; then
	DEVA_BOARD="$(cd "${DEVA_BOARD}" 2>/dev/null && pwd)" || die "--deva: percorso inesistente"
fi

# re3: fuori dall'overlay (repository privato), solo con --re3. Senza, l'immagine
# non lo ha e --no-re3 non serve.
if [ -n "${RE3_PKG}" ]; then
	RE3_PKG="$(cd "${RE3_PKG}" 2>/dev/null && pwd)" || die "--re3: percorso inesistente"
	grep -q '^PKG_NAME="re3"' "${RE3_PKG}/package.mk" 2>/dev/null \
		|| die "--re3: ${RE3_PKG} non e' il pacchetto re3 (serve un package.mk con PKG_NAME=\"re3\")"
	[ -d "${RE3_PKG}/files" ] && [ -d "${RE3_PKG}/patches" ] \
		|| die "--re3: in ${RE3_PKG} mancano files/ o patches/"
	echo "  re3           ok ($(hp "${RE3_PKG}"))"
else
	WITH_RE3="no"
fi

# overlay: cartella o tarball
# Default: la directory dello script, che e' l'overlay stesso. Cosi' funziona
# sia lanciandolo da dentro sia da fuori, che con il default su ${PWD} no.
if [ -z "${OVERLAY}" ]; then
	if   [ -x "${SELF_DIR}/apply.sh" ];         then OVERLAY="${SELF_DIR}"
	elif [ -d ./lakka-rf35h ];                  then OVERLAY="./lakka-rf35h"
	elif [ -f ./lakka-rf35h-overlay.tar.gz ];   then OVERLAY="./lakka-rf35h-overlay.tar.gz"
	else die "overlay non trovato. Passa --overlay <cartella|tar.gz>"; fi
fi
if [ -f "${OVERLAY}" ]; then
	TMPO="$(mktemp -d)"; tar xzf "${OVERLAY}" -C "${TMPO}"
	OVERLAY="${TMPO}/lakka-rf35h"
fi
OVERLAY="$(cd "${OVERLAY}" && pwd)"
[ -x "${OVERLAY}/apply.sh" ] || die "${OVERLAY}/apply.sh non trovato o non eseguibile"
echo "  overlay       ${OVERLAY}"

# Il loader: quello del repository (board/, lo stesso di devaOS) se --deva non
# dice altro. Qui e non prima: con --overlay tar.gz board/ sta nel tarball.
if [ -z "${DEVA_BOARD}" ]; then
	DEVA_BOARD="${OVERLAY}/board"
	[ -d "${DEVA_BOARD}/loader" ] \
		|| die "manca ${DEVA_BOARD}/loader e non c'e' --deva: serve una cartella con loader/known-good.bin"
fi
[ -f "${DEVA_BOARD}/loader/known-good.bin" ] \
	|| die "manca ${DEVA_BOARD}/loader/known-good.bin - e' il bootloader, senza non si parte"
( cd "${DEVA_BOARD}/loader" && sha256sum -c --quiet known-good.sha256 ) \
	|| die "known-good.bin non corrisponde al suo sha256"
echo "  loader        ok ($(stat -c%s "${DEVA_BOARD}/loader/known-good.bin") byte, $(hp "${DEVA_BOARD}"))"

# finisce nel nome dei file dell'immagine e in os-release: niente spazi,
# barre o virgolette
case "${RF35H_VERSION:-}" in
	*[!A-Za-z0-9._+-]*) die "RF35H_VERSION='${RF35H_VERSION}': solo lettere, cifre e . _ + -" ;;
esac

[ "$(uname -s)" = "Linux" ] || die "serve un host Linux"
case "$(uname -m)" in
	x86_64) ;;
	aarch64) warn "host aarch64: i binari rkbin di Rockchip sono x86_64, checkdeps aggiungera' qemu-user-binfmt e libc6-amd64-cross" ;;
	*) die "architettura host non supportata: $(uname -m)" ;;
esac

for t in git make gcc patch python3 tar xz sha256sum; do
	command -v "$t" >/dev/null || die "manca il comando: $t"
done
# Qui, prima di toccare l'albero: stava dopo l'applicazione dell'overlay, e una
# build sull'host senza mkimage moriva con l'albero gia' modificato.
if [ "${SKIP_DEPS}" != "yes" ] && [ "${VERIFY_ONLY}" != "yes" ] && ! command -v mkimage >/dev/null 2>&1; then
	warn "mkimage non e' installato: serve a costruire il boot.scr di questa"
	warn "board, senza il quale il loader non trova niente da avviare."
	warn "  Debian/Ubuntu: u-boot-tools   Arch: uboot-tools"
	warn "  oppure costruisci nel container, che ce l'ha: ./lakka-rf35h/build-in-docker.sh"
	die "mkimage mancante"
fi

if command -v ccache >/dev/null; then
	echo "  ccache        presente (il build system gli assegna 10 GB da solo)"
else
	warn "ccache assente. Installalo PRIMA della prima build: senza, ogni ricompilazione riparte da zero."
	warn "  debian/ubuntu: sudo apt-get install ccache"
fi

mkdir -p "$(dirname "${WORKDIR}")"
# Assoluto: la build fa cd nell'albero, e con un --workdir relativo (come serve
# nel container) il log "${WORKDIR}/build-rf35h-*.log" finiva a indicare
# ${WORKDIR}/${WORKDIR}/..., che non esiste: tee non scriveva il log.
WORKDIR="$(cd "$(dirname "${WORKDIR}")" && pwd)/$(basename "${WORKDIR}")"
AVAIL_GB=$(( $(stat -f -c '%a * %S' "$(dirname "${WORKDIR}")") / 1024 / 1024 / 1024 ))
echo "  spazio libero ${AVAIL_GB} GB"
[ "${AVAIL_GB}" -ge 100 ] || warn "meno di 100 GB liberi: la build della toolchain da sola ne mangia parecchi"

case "$(readlink -f "${WORKDIR}")" in
	/mnt/[a-z]/*) warn "workdir su un mount 9p/DrvFs (WSL). L'I/O qui e' il collo di bottiglia: sposta il tree dentro il filesystem della VM." ;;
esac

# --- solo verifica -------------------------------------------------------------
# Prima di clonare o applicare qualunque cosa: controlla cio' che c'e' gia'.
if [ "${VERIFY_ONLY}" = "yes" ]; then
	[ -d "${WORKDIR}" ] || die "$(hp "${WORKDIR}") non esiste: niente da verificare"
	krc=0; irc=0
	check_kernel || krc=$?
	check_image strict || irc=$?
	say "Esito"
	if [ "${krc}" = 0 ] && [ "${irc}" = 0 ]; then
		echo "  immagine: $(hp "${IMG}")"
		echo "  kernel e immagine conformi: si puo' scrivere la card, o copiare il .tar"
		echo "  in /storage/.update/ sul device."
		exit 0
	fi
	[ "${irc}" != 1 ] || die "l'immagine NON e' conforme (vedi sopra): non usarla"
	[ "${krc}" != 1 ] || die "il sorgente del kernel non ha tutte le patch (vedi sopra): immagine da non usare"
	die "non ho potuto verificare tutto (vedi sopra): nessun esito, ne' buono ne' cattivo"
fi

# --- albero Lakka ------------------------------------------------------------
say "Albero Lakka"

if [ -d "${WORKDIR}/.git" ]; then
	echo "  gia' presente: ${WORKDIR}"
else
	echo "  clono ${LAKKA_REPO} (branch devel)"
	git clone --depth 1 --branch devel --single-branch "${LAKKA_REPO}" "${WORKDIR}"
	if [ "${PIN}" = "yes" ] && [ "$(git -C "${WORKDIR}" rev-parse HEAD)" != "${LAKKA_COMMIT}" ]; then
		# Non "--depth 50 e speriamo": si chiede a GitHub proprio quel commit.
		if git -C "${WORKDIR}" fetch -q --depth 1 origin "${LAKKA_COMMIT}" 2>/dev/null; then
			git -C "${WORKDIR}" checkout -q FETCH_HEAD
			echo "  pinnato a ${LAKKA_COMMIT}"
		else
			warn "non riesco a recuperare ${LAKKA_COMMIT}: resto sulla punta di devel"
			warn "le patch sono verificate su quel commit; se qualcuna fallisce e' questo il primo sospetto"
		fi
	else
		echo "  al commit pinnato ${LAKKA_COMMIT}"
	fi
fi

[ -d "${WORKDIR}/projects/Rockchip/devices/RK3326" ] \
	|| die "${WORKDIR} non ha projects/Rockchip/devices/RK3326 - branch sbagliato?"

# Firma dell'overlay: serve a sapere non solo *che* e' stato applicato, ma
# **quale versione**. Senza, un overlay nuovo su un albero gia' applicato viene
# saltato in silenzio, e i controlli falliscono su file che nell'albero non
# sono mai arrivati.
#
# Copre esattamente cio' che apply.sh porta nell'albero: apply.sh stesso, le
# cartelle da cui copia e applica, e le variabili che legge. Percorsi RELATIVI
# all'overlay e ordinamento con LC_ALL=C: la prima versione firmava i percorsi
# assoluti con l'ordinamento della locale, quindi la firma cambiava fra host
# (/home/...) e container (/work/...), e a ogni --overlay tar.gz (scompattato
# ogni volta in una cartella temporanea nuova): "overlay disallineato" su un
# albero giusto. Fuori README, docs/, tools/ e gli altri script, che nell'albero non
# finiscono; dentro apply.sh, che prima restava fuori con tutti gli .sh pur
# decidendo cosa entra nell'albero.
OVERLAY_TREE_PATHS="apply.sh autoconfig integration optional packages patches"
overlay_sig() {
	local p list=""
	for p in ${OVERLAY_TREE_PATHS}; do
		if [ -e "${OVERLAY}/${p}" ]; then list="${list} ${p}"; fi
	done
	{
		( cd "${OVERLAY}" && find ${list} -type f -printf '%m %p\n' | LC_ALL=C sort )
		( cd "${OVERLAY}" && find ${list} -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum )
		echo "core-lto=${CORE_LTO} lto-cores=${RF35H_LTO_CORES:-} all-cores=${RF35H_ALL_CORES:-0}"
		# il loader che apply.sh copia nell'albero (board/ o --deva)
		if [ -n "${DEVA_BOARD:-}" ]; then
			echo "loader=$(sha256sum < "${DEVA_BOARD}/loader/known-good.bin" | cut -c1-64)"
		fi
		# re3 viene da fuori (--re3): conta cio' che apply.sh ne copia
		if [ -n "${RE3_PKG:-}" ]; then
			echo "re3:"
			( cd "${RE3_PKG}" && find package.mk files patches -type f -printf '%m %p\n' | LC_ALL=C sort )
			( cd "${RE3_PKG}" && find package.mk files patches -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum )
		fi
	} 2>/dev/null | sha256sum | cut -c1-16
	return 0
}

# --- overlay -----------------------------------------------------------------
STAMP="${WORKDIR}/.rf35h-applied"
say "Overlay RF35H"

# Percorsi dell'host anche dal container (hp): questi comandi si incollano li'.
# I resoconti build-rf35h-* in cima all'albero non sono ignorati da git: senza
# -e li cancellerebbe il clean.
reapply_hint() {
	warn "Per riapplicarlo, senza perdere sorgenti, pacchetti gia' fatti e resoconti:"
	warn "    rm -f $(hp "${STAMP}")"
	warn "    git -C $(hp "${WORKDIR}") checkout -- ."
	warn "    git -C $(hp "${WORKDIR}") clean -fd -e sources -e 'build.*' -e target -e '*.log' -e 'build-rf35h-*'"
	warn "poi rilancia lo stesso comando: si ricostruisce solo cio' che e' cambiato."
}

if [ -f "${STAMP}" ]; then
	sig_old="$(sed -n 's/^overlay-sig2: //p' "${STAMP}")"
	sig_now="$(overlay_sig)"
	if [ -n "${sig_old}" ] && [ "${sig_old}" != "${sig_now}" ]; then
		warn "l'albero ha l'overlay applicato il $(head -1 "${STAMP}"), ma quello qui"
		warn "porta nell'albero file diversi (o opzioni diverse, come --no-core-lto):"
		warn "i cambiamenti non ci sono mai arrivati."
		reapply_hint
		die "overlay disallineato"
	fi
	if [ -z "${sig_old}" ]; then
		if grep -q '^overlay-sig: ' "${STAMP}"; then
			# firma col calcolo vecchio, che dipendeva dal percorso: non si
			# puo' confrontare, e lasciar correre vorrebbe dire non sapere
			warn "l'albero e' stato applicato da una versione precedente dell'overlay,"
			warn "che firmava in un altro modo: non posso dire se e' aggiornato."
			reapply_hint
			die "overlay da riapplicare (una volta sola)"
		fi
		warn "stamp senza firma (overlay vecchio): non posso dire se e' aggiornato."
		warn "Nel dubbio:"
		reapply_hint
	fi
	echo "  gia' applicato ($(head -1 "${STAMP}")), salto"
else
	# apply.sh applica una patch alla volta e non sa tornare indietro: se muore a
	# meta' lascia l'albero mezzo patchato, e al rilancio le patch gia' applicate
	# fallirebbero con "Reversed (or previously applied) patch detected".
	# L'albero e' un clone git nostro, quindi si riporta a nuovo e si riparte.
	if ! RF35H_CORE_LTO="${CORE_LTO}" RF35H_RE3_PKG="${RE3_PKG}" "${OVERLAY}/apply.sh" "${WORKDIR}" "${DEVA_BOARD}"; then
		warn "apply.sh fallito: riporto l'albero allo stato pulito"
		git -C "${WORKDIR}" checkout -q -- . 2>/dev/null || true
		# log e resoconti delle build precedenti non sono ignorati da git
		git -C "${WORKDIR}" clean -qfd -e '*.log' -e 'build-rf35h-*' 2>/dev/null || true
		die "overlay non applicato. Corretto il problema, rilancia: l'albero e' di nuovo pulito."
	fi
	{ date -Iseconds; echo "overlay-sig2: $(overlay_sig)"; } > "${STAMP}"
fi

if [ "${WITH_KMS}" = "yes" ]; then
	if grep -q "kms-no-compositor" "${STAMP}" 2>/dev/null; then
		echo "  patch KMS gia' applicata"
	else
		echo "  applico optional/kms-no-compositor.patch"
		patch -p1 -d "${WORKDIR}" < "${OVERLAY}/optional/kms-no-compositor.patch"
		echo "kms-no-compositor" >> "${STAMP}"
	fi
fi

# --- verifiche post-patch ----------------------------------------------------
say "Verifica che l'overlay sia atterrato"
RK="${WORKDIR}/projects/Rockchip/devices/RK3326"
check() { [ -e "$2" ] && printf '  %-34s ok\n' "$1" || die "$1: manca $2"; }
grep -q "DISPLAYLIST_RF35H_LED_SETTINGS_LIST" "${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch" \
	|| die "1003: mancano i sottomenu - rigenerata solo col primo stadio? servono entrambi (tools/gen-retroarch-rf35h-*.py)"
# Ogni label DEFERRED dei sottomenu deve avere la sua stringa in msg_hash_lbl.h:
# senza, il sottomenu si apre su "Directory not found" (visto sul device).
P1003="${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch"
for d in $(grep -oE "^\+   MENU_ENUM_LABEL_DEFERRED_RF35H_[A-Z_]+_LIST," "${P1003}" | tr -d '+,' | tr -d ' ' | sort -u); do
	low="$(echo "${d}" | sed 's/^MENU_ENUM_LABEL_DEFERRED_//; s/_LIST$//' | tr 'A-Z' 'a-z')"
	grep -q "\"deferred_${low}_list\"" "${P1003}" \
		|| die "1003: ${d} senza stringa label in msg_hash_lbl.h: il suo menu si aprirebbe vuoto"
done
# I drop-in su servizi di early boot (DefaultDependencies=no, Before=sysinit)
# non devono ordinarli dopo la rete: e' un ciclo, e systemd lo spezza cancellando
# un job a caso - sul device ha tolto connman, e il Wi-Fi non trovava reti.
for d in "${RK}"/packages/rf35h-utils/timesyncd.d/*.conf; do
	grep -qE "^(After|Wants|Requires)=.*(network|multi-user|graphical)" "${d}" \
		&& die "$(basename "${d}"): ordina timesyncd (early boot) dopo la rete: ciclo di dipendenze"
done
# Il loader known-good deve stare anche nel SYSTEM, non solo sulla card: senza,
# bootloader/update.sh lo sovrascrive a 32K a ogni aggiornamento .tar con
# l'u-boot di Lakka, e il device non riparte piu'.
grep -q 'UBOOT_SYSTEM}" = "rf35h"' "${WORKDIR}/projects/Rockchip/bootloader/install" \
	|| die "bootloader/install: manca il ramo rf35h, un aggiornamento .tar sovrascriverebbe il loader"
# Residui da non spedire mai: __pycache__ dai py_compile sui generatori, backup
# di patch, file di rigetto. Sono finiti nel tarball piu' di una volta.
junk="$(find "${RK}" "${WORKDIR}/packages/lakka" -name '__pycache__' -o -name '*.pyc' \
	-o -name '*.orig' -o -name '*.rej' 2>/dev/null | head -5)"
[ -z "${junk}" ] || die "residui nell'albero: ${junk}"
# GPU: i 600 MHz del vendor girano alla stessa tensione dei 560 (1,15 V).
grep -q "opp-600000000" "${RK}/patches/linux/z-010-add-rf35h-dts.patch" \
	|| die "z-010: manca il punto operativo GPU a 600 MHz"
# Lo stamp su DISPLAYSERVER: senza, passare da "no" a "wl" riusa dalla cache un
# RetroArch che non sa di avere un compositore.
grep -q 'PKG_STAMP="${DISPLAYSERVER}"' "${WORKDIR}/packages/lakka/retroarch_base/retroarch/package.mk" \
	|| die "retroarch: manca PKG_STAMP su DISPLAYSERVER"
# SDL: le opzioni host non devono contenere il sysroot del target, o host-gcc
# compila con gli header aarch64 e fallisce sui tipi NEON.
sed -n '/PKG_CONFIGURE_OPTS_HOST=/,/without-x"/p' "${WORKDIR}/packages/lakka/lakka_depends/SDL/package.mk" \
	| grep -q "SYSROOT_PREFIX" \
	&& die "SDL: le opzioni host ereditano ancora il sysroot del target"
# ...ma quelle TARGET devono conservare ALSA: e' la SDL che gira sulla console,
# e la usano i core (dosbox_core, ecwolf, nxengine, tic80) per suonare.
sed -n '/PKG_CONFIGURE_OPTS_TARGET=/,/^$/p' "${WORKDIR}/packages/lakka/lakka_depends/SDL/package.mk" \
	| grep -qE -- "--enable-alsa([[:space:]]|\\\\|$)" \
	|| die "SDL: le opzioni target hanno perso ALSA (l'audio dei core SDL non funzionerebbe)"
# Il cmdline: quiet per non stampare ~850 righe sul framebuffer a ogni avvio,
# e net.ifnames scritto giusto (Lakka ha "iframes", che e' inerte).
grep -q 'EXTRA_CMDLINE="quiet console=tty0 console=ttyS1,1500000n8 net.ifnames=0"' \
	"${WORKDIR}/projects/Rockchip/devices/RK3326/options" \
	|| die "cmdline rf35h: atteso quiet + ttyS1 + net.ifnames"
# sway: la barra di stato non deve tornare (un "date" al secondo, e blocca il
# direct scanout di RetroArch).
grep -q "status_command" "${WORKDIR}/packages/wayland/compositor/sway/config/config" \
	&& die "sway: la barra di stato e' tornata nella configurazione"
# Vulkan accanto a OpenGL ES: il blocco nelle options, niente renderer Vulkan
# per sway, e lo stamp su VULKAN dove la build cambia con l'opzione.
grep -q 'RF35H_VULKAN:-yes' "${RK}/options" || die "options: manca il blocco Vulkan/IKEMEN"
grep -q 'UBOOT_SYSTEM}" != "rf35h"' "${WORKDIR}/packages/wayland/lib/wlroots/package.mk" \
	|| die "wlroots: il renderer Vulkan non e' escluso sull'RF35H"
for _pm in packages/graphics/mesa/package.mk packages/lakka/retroarch_base/retroarch/package.mk; do
	grep -q 'PKG_STAMP+=" VULKAN=' "${WORKDIR}/${_pm}" || die "${_pm}: manca PKG_STAMP su VULKAN"
done
# IKEMEN GO: package, lanciatore, core per "Core senza contenuto"
check "IKEMEN GO (ikemen-go)"            "${RK}/packages/ikemen-go/package.mk"
check "lanciatore rf35h-ikemen"          "${RK}/packages/ikemen-go/scripts/rf35h-ikemen"
check "Go per l'host (golang-bin)"       "${RK}/packages/golang-bin/package.mk"
check "core lanciatore ikemen_libretro"  "${RK}/packages/ikemen-go/launcher/ikemen_libretro.c"
grep -q 'supports_no_game = "true"' "${RK}/packages/ikemen-go/launcher/ikemen_libretro.info" \
	&& grep -q 'single_purpose = "true"' "${RK}/packages/ikemen-go/launcher/ikemen_libretro.info" \
	|| die "ikemen_libretro.info: IKEMEN GO non comparirebbe in Core senza contenuto"
# I giochi: package e, per quelli senza contenuto, il .info monouso
check "GTA: San Andreas (gtasa)"         "${RK}/packages/gtasa/package.mk"
if [ -n "${RE3_PKG}" ]; then
	check "GTA III (re3, da --re3)"      "${RK}/packages/re3/package.mk"
else
	[ ! -e "${RK}/packages/re3" ] || die "re3 nell'albero senza --re3: resto di un giro precedente?"
fi
check "OpenXeenNG (openxeenng)"              "${RK}/packages/openxeenng/package.mk"
check "Rust per l'host (rust-bin)"       "${RK}/packages/rust-bin/package.mk"
check "Deva's Awesome Adventures"        "${RK}/packages/deva_adventures/package.mk"
for _info in "${RK}/packages/gtasa/launcher/gtasa_libretro.info" ${RE3_PKG:+"${RK}/packages/re3/files/re3_libretro.info"}; do
	grep -q 'supports_no_game = "true"' "${_info}" && grep -q 'single_purpose = "true"' "${_info}" \
		|| die "$(basename "${_info}"): non comparirebbe in Core senza contenuto"
done
for _g in gtasa re3 openxeenng deva_adventures; do
	grep -q "ADDITIONAL_PACKAGES+=\" ${_g}\"" "${RK}/options" || die "options: manca ${_g}"
done
check "ripiego Vulkan di RetroArch"      "${RK}/packages/rf35h-utils/retroarch.service.d/rf35h-vulkan.conf"
check "attesa Wi-Fi (1005)"     "${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1005-wifi-connect-wait.patch"
check "device tree (z-010)"     "${RK}/patches/linux/z-010-add-rf35h-dts.patch"
grep -q "rumble-gpio = <&gpio3 RK_PA6 GPIO_ACTIVE_HIGH>" "${RK}/patches/linux/z-010-add-rf35h-dts.patch" \
	|| die "z-010: manca la regolazione del rumble (patch non unificata?)"
grep -q "#address-cells = <1>" "${RK}/patches/linux/z-010-add-rf35h-dts.patch" \
	|| die "z-010: il nodo dsi deve dichiarare le celle, o dtc salta quattro controlli"
grep -q "charge-full-design-microamp-hours = <3228000>" "${RK}/patches/linux/z-010-add-rf35h-dts.patch" \
	|| die "z-010: mancano i valori OEM della batteria"
# r-026 e r-027 (mie patch al codec e all'I2S) sono state spostate in
# optional/: AURKNIX ha audio funzionante su questo hardware con lo stesso
# device tree e NESSUNA patch al codec. Qui si verifica invece che la kconfig
# audio resti allineata alla sua, perche' e' li' che stava la differenza.
grep -qE "^CONFIG_SND_SOC_ROCKCHIP_I2S=y" "${RK}/linux/linux.aarch64.conf" \
	|| die "kconfig audio: l'I2S deve essere built-in (=y) come in AURKNIX"
grep -qE "^CONFIG_SND_SOC_SIMPLE_AMPLIFIER=m" "${RK}/linux/linux.aarch64.conf" \
	|| die "kconfig audio: l'amplificatore deve essere modulo (=m) come in AURKNIX"
# Debug del kernel: DEBUG_PREEMPT mette un controllo su ogni operazione di
# preempt_count, cioe' su ogni lock del kernel. E' sovraccarico continuo sui
# percorsi a bassa latenza, audio compreso, e AURKNIX non ce l'ha.
grep -qE "^# CONFIG_DEBUG_PREEMPT is not set" "${RK}/linux/linux.aarch64.conf" \
	|| die "kconfig: DEBUG_PREEMPT deve restare spento (sovraccarico su ogni lock)"
# SND_SOC_ROCKCHIP non esiste come simbolo, ne' nella 7.0.1 ne' nella 7.2.7:
# sound/soc/rockchip/Kconfig e' un semplice menu "Rockchip". Averlo a =y era
# una riga morta (ereditata da una config piu' vecchia); l'opzione che conta
# e' SND_SOC_ROCKCHIP_I2S, controllata sopra.
check "package rk915"           "${RK}/packages/rk915/package.mk"
check "package rocknix-joypad"  "${RK}/packages/rocknix-joypad/package.mk"
check "  fix of_gpio (0002)"     "${RK}/packages/rocknix-joypad/patches/0002-of-gpio-legacy-guard.patch"
check "  of_gpio per 7.2 (0003)" "${RK}/packages/rocknix-joypad/patches/0003-rocknix-joypad-linux-7.2-of-gpio.patch"
check "  rk915 per 7.2 (0003)"   "${RK}/packages/rk915/patches/0003-rk915-linux-7.2-strncpy.patch"
check "package rf35h-utils"     "${RK}/packages/rf35h-utils/package.mk"
check "bootloader"              "${RK}/bootloader/rf35h-loader.bin"
grep -q "'rf35h'" "${WORKDIR}/scripts/uboot_helper" || die "voce rf35h assente da uboot_helper"
printf '  %-34s ok\n' "voce uboot_helper"
grep -q "^CONFIG_INPUT_RK805_PWRKEY=y" "${RK}/linux/linux.aarch64.conf" || die "tasto power: simbolo non abilitato"
grep -q "^# CONFIG_BT is not set" "${RK}/linux/linux.aarch64.conf" \
	|| die "Bluetooth: dovrebbe essere spento anche nel kernel"
grep -q 'BLUETOOTH_SUPPORT="no"' "${RK}/options" \
	|| die "Bluetooth: dovrebbe essere spento per rf35h (la board non ce l'ha)"
grep -q 'ADDITIONAL_PACKAGES/ xpadneo /' "${RK}/options" \
	|| die "xpadneo: dovrebbe essere tolto per rf35h (e' un driver Bluetooth)"
grep -q "^CONFIG_ZRAM=y" "${RK}/linux/linux.aarch64.conf" || die "zram: simbolo non abilitato"
grep -q "^CONFIG_LEDS_CLASS_MULTICOLOR=y" "${RK}/linux/linux.aarch64.conf" \
	|| die "HID_PLAYSTATION senza LEDS_CLASS_MULTICOLOR: kconfig lo scarterebbe"
grep -q "^CONFIG_JOYSTICK_XPAD=m" "${RK}/linux/linux.aarch64.conf" || die "gamepad USB: xpad non abilitato"
grep -q "^CONFIG_NTFS3_FS=m" "${RK}/linux/linux.aarch64.conf" || die "ntfs3: simbolo non abilitato"
printf '  %-34s ok\n' "CONFIG_INPUT_RK805_PWRKEY"
grep -q 'UBOOT_SYSTEM.*rf35h' "${RK}/packages/odroidgo2-utils/package.mk" \
	|| die "odroidgo2-utils abiliterebbe ancora il suo servizio: l'audio si spegnerebbe staccando le cuffie"
printf '  %-34s ok\n' "guardia odroidgo2-utils"
grep -q "cmd_plugged" "${RK}/packages/odroidgo2-utils/sources/headphone-sense.c" \
	|| die "headphone-sense non parametrizzato"
printf '  %-34s ok\n' "headphone-sense parametrizzato"
AC="${WORKDIR}/packages/lakka/retroarch_base/retroarch_joypad_autoconfig/sources/udev/retrogame_joypad.cfg"
[ -f "${AC}" ] || die "autoconfig joypad non copiato in sources/udev/"
printf '  %-34s ok\n' "autoconfig retrogame_joypad"
for t in rf35h-led rf35h-brightness rf35h-diag; do
	[ -x "${RK}/packages/rf35h-utils/scripts/${t}" ] || die "${t} mancante o non eseguibile"
done
printf '  %-34s ok\n' "script rf35h-led/brightness/diag"
[ -f "${RK}/packages/rf35h-utils/scripts/rf35h-bootlog" ] || die "manca rf35h-bootlog"
grep -q "rf35h-bootlog" "${RK}/packages/rf35h-utils/package.mk" \
	|| die "rf35h-bootlog.service non abilitato: niente log persistente"
printf '  %-34s ok\n' "log persistente al boot"
grep -q "b0c0f4a599f43723736c8565b8b84337c4195077f07f1bb8bb3252bb13a2306a" \
	"${WORKDIR}/packages/wayland/lib/fcft/package.mk" || die "checksum fcft non aggiornato"
grep -q "9d6a6222062111d0b8d7156cfbe4dc0bd74fcb9e8a387b0c81b99cc5087c526d" \
	"${WORKDIR}/packages/wayland/util/foot/package.mk" || die "checksum foot non aggiornato"
printf '  %-34s ok\n' "checksum fcft e foot"
grep -q 'KCFLAGS="-Wno-error"' "${RK}/packages/u-boot/package.mk" \
	|| die "u-boot senza -Wno-error: si fermera' su cmd/gpt.c"
printf '  %-34s ok\n' "u-boot con gcc moderno"
grep -q "HandlePowerKey=suspend" "${WORKDIR}/packages/sysutils/systemd/package.mk" \
	|| die "tasto power non configurato per sospendere"
[ -f "${RK}/packages/rf35h-utils/system.d/rf35h-suspend.service" ] \
	|| die "manca rf35h-suspend.service"
printf '  %-34s ok\n' "sospensione sul tasto power"
[ -f "${RK}/packages/rf35h-utils/sources/rf35h-idle.c" ] && [ -f "${RK}/packages/rf35h-utils/system.d/rf35h-idle.service" ] \
	|| die "manca rf35h-idle: niente sospensione automatica"
printf '  %-34s ok\n' "sospensione automatica (idle)"
[ -f "${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch" ] \
	|| die "manca la patch del menu RF35H in RetroArch"
grep -q "rf35h_present" "${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1003-rf35h-settings-menu.patch" \
	|| die "la patch del menu RF35H non e' quella giusta"
printf '  %-34s ok\n' "menu Device Settings"
grep -q "__ARM_NEON)" "${WORKDIR}/packages/lakka/retroarch_base/retroarch/patches/retroarch-1004-arm64-neon-cpu-model.patch" 2>/dev/null \
	|| die "manca la patch NEON/CPU model per aarch64"
printf '  %-34s ok\n' "NEON e CPU model su aarch64"
grep -q "^CONFIG_USB_CONFIGFS_RNDIS=y" "${RK}/linux/linux.aarch64.conf" || die "kernel senza gadget USB (configfs RNDIS)"
grep -q "^CONFIG_UDHCPD=y" "${WORKDIR}/packages/sysutils/busybox/config/busybox-target.conf" || die "busybox senza udhcpd"
grep -q "zt,usb" "${WORKDIR}/packages/network/connman/package.mk" || die "connman senza blacklist usb"
printf '  %-34s ok\n' "porta USB-C: gadget, dhcp, blacklist"
# PROJECT_CFLAGS con un -O rompe glibc: lo toglie dai suoi CFLAGS insieme al
# proprio -O2 ("glibc cannot be compiled without optimization"). Il -O2 lo
# mette gia' LibreELEC a ogni pacchetto (CFLAGS_OPTIM_DEFAULT).
! grep -qE '^[^#]*PROJECT_CFLAGS="[^"]*-O' "${RK}/options" || die "PROJECT_CFLAGS con -O nelle options: glibc non compilerebbe"
grep -q 'SYSTEM_SIZE=3072' "${RK}/options" || die "manca SYSTEM_SIZE=3072 nelle options"
# il flag della patch di Mesa c'e', ma questa LibreELEC non lo conosce: per ora
# l'LTO non e' attivo (docs/diario.md, correzione del 3/10); si controlla solo la patch
grep -q 'PKG_BUILD_FLAGS="+lto-parallel"' "${WORKDIR}/packages/graphics/mesa/package.mk" || die "manca la patch LTO di Mesa"
printf "  %-34s ok\n" "SYSTEM 3 GB, glibc ottimizzata, LTO Mesa inerte"
grep -q 'WIRELESS_DAEMON="wpa_supplicant"' "${RK}/options" \
	|| die "WIRELESS_DAEMON non impostato: con iwd la UI non vede reti"
grep -q 'WIRELESS_DAEMON.*wpa_supplicant' "${WORKDIR}/packages/network/iwd/package.mk" \
	|| die "iwd.service partirebbe comunque e si prenderebbe phy0"
grep -q 'PKG_VERSION="2.11"' "${RK}/packages/wpa_supplicant/package.mk" \
	|| die "manca il package wpa_supplicant: Lakka e' iwd-only dalla v6"
grep -q '^CONFIG_SAE=y' "${RK}/packages/wpa_supplicant/config/makefile.config" \
	|| die "wpa_supplicant senza SAE: connman 2.0 lo manda sempre, connect fallirebbe con invalid-key"
grep -q 'PKG_STAMP="${WIRELESS_DAEMON' "${WORKDIR}/packages/network/connman/package.mk" \
	|| die "connman senza PKG_STAMP: non verrebbe ricostruito col nuovo backend"
printf '  %-34s ok\n' "wpa_supplicant 2.11 invece di iwd"
grep -q "modified_cmd" "${RK}/packages/eventservice/sources/spkeys-service.c" \
	|| die "spkeys-service senza supporto al modificatore: niente Select+volume"
printf '  %-34s ok\n' "combo Select+volume"

# --- cache dei sorgenti -------------------------------------------------------
# Prima della build, non dopo il fallimento: il pool di Debian tiene solo la
# versione corrente di ogni pacchetto e quando ne esce una nuova il tarball
# pinnato sparisce. Meglio riempire la cache adesso che scoprirlo dopo venti
# minuti di toolchain.
if [ -x "${OVERLAY}/seed-sources.sh" ]; then
	say "Cache dei sorgenti"
	"${OVERLAY}/seed-sources.sh" "${WORKDIR}" || warn "qualche sorgente non si e' scaricato: la build potrebbe fermarsi li'"
fi

# --- core libretro --------------------------------------------------------
# Qui e non nella sezione Build: --dry-run esce prima, e un nome sbagliato si
# scoprirebbe solo lanciando la build vera. Un nome che non corrisponde a una
# cartella finisce in PKG_DEPENDS_TARGET e fa morire la build con un messaggio
# poco chiaro.
if [ -n "${CORES}" ]; then
	say "Core libretro"
	bad=""
	for c in ${CORES}; do
		[ -d "${WORKDIR}/packages/lakka/libretro_cores/${c}" ] || bad="${bad} ${c}"
	done
	[ -z "${bad}" ] || die "core libretro inesistenti:${bad}
  I nomi sono quelli delle cartelle in ${WORKDIR}/packages/lakka/libretro_cores/"
	n=0; for c in ${CORES}; do n=$((n+1)); done
	if [ "${CORES}" = "${CORES_DEFAULT}" ]; then
		echo "  ${n} core (set curato per RK3326): ${CORES}"
	else
		echo "  ${n} core: ${CORES}"
	fi
else
	say "Core libretro"
	warn "tutti i ~120 di Lakka per RK3326, mame/ppsspp/scummvm compresi: sono ore,"
	warn "e su questo SoC molti non sono giocabili. Il default (senza --all-cores)"
	warn "e' un set curato di 13."
fi

# Ogni modifica dichiarata deve essere davvero nell'albero. Si verifica sia al
# dry-run sia prima di una build vera: e' economico, e una regressione trovata
# qui costa secondi invece delle ore di una build.
say "Le modifiche dichiarate sono tutte presenti?"
RF35H_CORE_LTO="${CORE_LTO}" "${OVERLAY}/tools/verify-claims.sh" "${WORKDIR}" "${OVERLAY}" \
	|| die "una o piu' modifiche dichiarate non sono nell'albero (vedi sopra)"

# La versione dell'immagine. RF35H_VERSION (la CI ci mette il tag della
# release) diventa VERSION in /etc/os-release e entra nel nome dell'immagine:
# e' cio' che rf35h-update confronta con l'ultima release. Senza, resta quella
# di Lakka (devel-<data>-<commit di Lakka>). BUILDER_VERSION e' il commit
# dell'overlay, per sapere da cosa viene un'immagine.
OVERLAY_REV="$(git -C "${OVERLAY}" describe --always --dirty --abbrev=12 2>/dev/null || true)"

if [ "${DRY_RUN}" = "yes" ]; then
	# Il piano di build con l'ambiente della build vera: una dipendenza che
	# non esiste, o un pacchetto che manca, qui costa un minuto invece di
	# fermare la build dopo ore.
	say "Piano di build"
	build_env
	PLAN="${WORKDIR}/build-rf35h-plan.txt"
	if ( cd "${WORKDIR}" && env "${BENV[@]}" ./scripts/pkgjson | ./scripts/genbuildplan.py --show-wants --build image ) \
			> "${PLAN}" 2> "${PLAN%.txt}.err"; then
		echo "  $(wc -l < "${PLAN}") passi: $(grep -c '^build ' "${PLAN}") per l'host, $(grep -c '^install ' "${PLAN}") per la console"
		echo "  $(hp "${PLAN}")"
		echo "  giochi: $(games_on)"
	else
		sed 's/^/    /' "${PLAN%.txt}.err" >&2
		die "il piano di build non si calcola (vedi sopra): una dipendenza manca o e' sbagliata"
	fi

	say "Dry run"
	echo "  Tutto applicato e verificato."
	echo
	echo "  Per costruire, rilancia questo stesso script senza --dry-run."
	echo "  (Non lanciare make a mano: dentro un container ${WORKDIR} e' il"
	echo "   percorso interno, non quello dell'host.)"
	exit 0
fi

# --- dipendenze host ---------------------------------------------------------
if [ "${SKIP_DEPS}" = "no" ]; then
	say "Dipendenze host"
	( cd "${WORKDIR}" && PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 ./scripts/checkdeps ) \
		|| warn "checkdeps ha segnalato qualcosa: leggilo prima di proseguire"
fi

# --- build -------------------------------------------------------------------
# Default del parallelismo: due compilatori per pacchetto (il grosso dei
# pacchetti non scala oltre) e tanti pacchetti quanti ne reggono core e
# memoria. La RAM conta piu' dei core: un link LTO (oggi re3; Mesa e i core
# quando l'LTO sara' attivo davvero) arriva tranquillamente a mezzo giga, e andare in swap su una build
# di ore costa molto piu' di qualche compilatore in meno.
if [ -z "${JOBS}" ]; then JOBS=2; fi
if [ -z "${PKG_JOBS}" ]; then
	_cores="$(nproc 2>/dev/null || echo 4)"
	_ramgb="$(awk '/^MemTotal:/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)"
	_byram=$(( _ramgb / 2 ))
	[ "${_byram}" -lt 1 ] && _byram=1
	if [ "${_byram}" -lt "${_cores}" ]; then PKG_JOBS="${_byram}"; else PKG_JOBS="${_cores}"; fi
	PKG_JOBS_WHY="$( [ "${_byram}" -lt "${_cores}" ] && echo "limitato dalla RAM (${_ramgb} GB)" || echo "pari ai core (${_cores})" )"
fi

LOG="${WORKDIR}/build-rf35h-$(date +%Y%m%d-%H%M%S).log"
say "Build"
echo "  PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 UBOOT_SYSTEM=rf35h"
echo "  Vulkan (PanVK, alternativa a OpenGL ES): ${WITH_VULKAN}   IKEMEN GO: ${WITH_IKEMEN}"
echo "  GTA SA: ${WITH_GTASA}   GTA III (re3): ${WITH_RE3}$([ -n "${RE3_PKG}" ] || echo ' (serve --re3)')   OpenXeenNG: ${WITH_OPENXEENNG}   Deva's Awesome Adventures: ${WITH_DEVA}"
[ "${WITH_RE3}" = "yes" ] \
	&& warn "re3 incluso: il suo codice non ha licenza, immagine solo per uso personale (--no-re3 per una da condividere)"
echo "  versione: ${RF35H_VERSION:-quella di Lakka (devel-<data>)}${OVERLAY_REV:+   overlay: ${OVERLAY_REV}}"
echo "  make -j per pacchetto: ${JOBS}"
echo "  pacchetti in parallelo: ${PKG_JOBS}${PKG_JOBS_WHY:+ (${PKG_JOBS_WHY})}"
echo "  compilatori al massimo: $(( JOBS * PKG_JOBS ))"
if [ -n "${CORES}" ]; then
	echo "  core libretro: ${CORES}"
else
	warn "core libretro: tutti (--all-cores). Sono mame, ppsspp e scummvm a mangiare le ore."
fi
echo "  log: ${LOG}"
echo
warn "Sono ore. Lancialo dentro tmux o screen, non in una ssh che puo' cadere."
echo

cd "${WORKDIR}"

# Il nome del pacchetto fallito sta nella riga
#   FAILURE: scripts/<azione> <pkg>:<host|target> has failed!
# Niente ancore: la riga puo' arrivare con i codici di colore di LibreELEC.
failed_pkg() {
	sed -n 's|.*FAILURE: scripts/[a-z]* \([A-Za-z0-9_.+-]*\):[a-z]* has failed!.*|\1|p' "$1" | tail -1
}

# Solo i core libretro si possono saltare: un pacchetto di sistema (SDL, mesa,
# busybox) serve all'immagine, e proseguire senza avrebbe poco senso.
is_core() { [ -d "${WORKDIR}/packages/lakka/libretro_cores/$1" ]; }

# ...e i pezzi di IKEMEN GO e dei giochi, che sono facoltativi: con
# --keep-going, se uno non compila si rifa' l'immagine senza quel gioco, come
# con il suo --no-... Solo i pacchetti che servono a lui solo: openal-soft e
# mpg123, per dire, servono a due giochi e restano pacchetti di sistema. I
# *-snapshot di Rust in questa build li usa solo rust-bin.
extra_of() {
	case "$1" in
		ikemen-go|ikemen-sdl2|ikemen-screenpack|libxmp|golang-bin) echo ikemen ;;
		gtasa) echo gtasa ;;
		re3) echo re3 ;;
		openxeenng|rust-bin|rust-std-aarch64|rustc-snapshot|cargo-snapshot|rust-std-snapshot) echo openxeenng ;;
		deva_adventures) echo deva-adventures ;;
	esac
}
extra_on() {
	case "$1" in
		ikemen) echo "${WITH_IKEMEN}" ;;
		gtasa) echo "${WITH_GTASA}" ;;
		re3) echo "${WITH_RE3}" ;;
		openxeenng) echo "${WITH_OPENXEENNG}" ;;
		deva-adventures) echo "${WITH_DEVA}" ;;
	esac
}
drop_extra() {
	case "$1" in
		ikemen) WITH_IKEMEN="no" ;;
		gtasa) WITH_GTASA="no" ;;
		re3) WITH_RE3="no" ;;
		openxeenng) WITH_OPENXEENNG="no" ;;
		deva-adventures) WITH_DEVA="no" ;;
	esac
}

BUILD_ATTEMPT=0
DROPPED=""
DROPPED_EXTRAS=""
while : ; do
	BUILD_ATTEMPT=$((BUILD_ATTEMPT + 1))
	[ "${BUILD_ATTEMPT}" -gt 1 ] && say "ripresa ${BUILD_ATTEMPT}: la cache conserva tutto il costruito finora"
	build_env
	set +e
	env "${BENV[@]}" make image 2>&1 | tee "${LOG}"
	RC=${PIPESTATUS[0]}
	set -e
	[ "${RC}" -eq 0 ] && break
	[ "${KEEP_GOING}" = "yes" ] || break

	PKG="$(failed_pkg "${LOG}")"
	if [ -z "${PKG}" ]; then
		warn "non riesco a capire quale pacchetto ha fallito: mi fermo"
		warn "ultime righe FAILURE nel log, per capire il formato:"
		grep -a "FAILURE" "${LOG}" | tail -3 | sed 's/^/    /' >&2 || true
		break
	fi
	# Il log del THREAD contiene solo questo pacchetto; quello complessivo
	# contiene l'intera build ed e' fuorviante (ci si legge l'errore di un
	# altro core e si insegue la pista sbagliata). I log dei thread sono
	# numerati e la build successiva li sovrascrive, quindi si copiano subito,
	# per ogni pacchetto: anche per uno di sistema, che ferma la build.
	TLOG="$(sed -n 's|^ *\(/.*/\.threads/logs/[0-9]*\.log\) *$|\1|p' "${LOG}" | tail -1)"
	if [ -n "${TLOG}" ] && [ -r "${TLOG}" ]; then
		cp -f "${TLOG}" "${LOG%.log}-${PKG}-fallito.log"
	else
		# senza log del thread si ripiega sulla coda di quello complessivo
		tail -400 "${LOG}" > "${LOG%.log}-${PKG}-fallito.log" 2>/dev/null || true
	fi
	EXTRA="$(extra_of "${PKG}")"
	if [ -z "${EXTRA}" ] && ! is_core "${PKG}"; then
		warn "${PKG} non e' un core libretro ne' un pezzo di un gioco, ma un pacchetto di sistema: mi fermo"
		warn "il suo log: $(hp "${LOG%.log}-${PKG}-fallito.log")"
		case "${PKG}" in
			openal-soft|mpg123)
				warn "serve a GTA SA e a GTA III (re3): --no-gtasa --no-re3 fanno l'immagine senza, intanto" ;;
			mesa|retroarch|vulkan-headers|vulkan-loader|vulkan-tools|volk|glslang|ply)
				[ "${WITH_VULKAN}" = "yes" ] \
					&& warn "con Vulkan attivo ${PKG} e' nuovo o cambiato: --no-vulkan rifa' l'immagine come prima, intanto" ;;
		esac
		break
	fi
	# Gia' escluso e fallisce ancora: l'esclusione non ha effetto, di solito
	# perche' un altro pacchetto lo tira dentro come dipendenza. Riprovare
	# ripeterebbe lo stesso fallimento fino al limite, un make image per volta.
	if [ -n "${EXTRA}" ]; then
		if [ "$(extra_on "${EXTRA}")" = "no" ]; then
			warn "${PKG} (${EXTRA}) e' gia' escluso ma fallisce ancora: lo richiede un altro pacchetto come dipendenza"
			warn "va escluso quel pacchetto, o riparato ${PKG}: mi fermo invece di ripetere"
			break
		fi
	else
		case " ${SKIP_CORES} " in
			*" ${PKG} "*)
				warn "${PKG} e' gia' escluso ma fallisce ancora: lo richiede un altro pacchetto come dipendenza"
				warn "va escluso quel pacchetto, o riparato ${PKG}: mi fermo invece di ripetere"
				break ;;
		esac
	fi
	if [ "${BUILD_ATTEMPT}" -ge "${KEEP_GOING_MAX}" ]; then
		warn "raggiunto il limite di ${KEEP_GOING_MAX} riprese: mi fermo"
		break
	fi
	if [ -n "${EXTRA}" ]; then
		warn "${PKG} fallito: e' un pezzo di ${EXTRA}, rifaccio l'immagine senza (come --no-${EXTRA})"
		drop_extra "${EXTRA}"
		DROPPED_EXTRAS="${DROPPED_EXTRAS} ${EXTRA}"
	else
		warn "core ${PKG} fallito: lo escludo e riprendo"
		SKIP_CORES="${SKIP_CORES} ${PKG}"
	fi
	DROPPED="${DROPPED} ${PKG}"
done

# Resoconto dei core saltati: a fine build e' l'unica cosa che si ricorda.
if [ -n "${DROPPED}" ]; then
	REPORT="${LOG%.log}-core-saltati.txt"
	{
		echo "Core esclusi perche' non compilano, build del $(date '+%Y-%m-%d %H:%M')"
		echo
		for c in ${DROPPED}; do
			_x="$(extra_of "${c}")"
			echo "  ${c}${_x:+ (immagine fatta senza ${_x}, come --no-${_x})}    log: $(hp "${LOG%.log}-${c}-fallito.log")"
		done
		echo
		echo "Per riprovarne uno: cancellare build.*/build/<core>-* e rilanciare"
		echo "senza --skip-core per quel core (per un gioco: senza il suo --no-...)."
	} > "${REPORT}"
	echo
	warn "core saltati perche' non compilano:$(printf ' %s' ${DROPPED})"
	[ -n "${DROPPED_EXTRAS}" ] && warn "giochi tolti dall'immagine:$(printf ' %s' ${DROPPED_EXTRAS})"
	warn "resoconto: $(hp "${REPORT}")"
fi

if [ "${RC}" -ne 0 ]; then
	echo
	# senza --keep-going: se e' un pezzo di un gioco, dire come farne a meno
	_pkg="$(failed_pkg "${LOG}")"
	_x="$(extra_of "${_pkg}")"
	if [ -n "${_x}" ]; then
		warn "${_pkg} e' un pezzo di ${_x}: --no-${_x} fa l'immagine senza (--keep-going lo toglie da solo)"
		[ "${_pkg}" = "re3" ] && warn "re3 si scarica da un mirror (hottabxp/re3) di un repository rimosso nel 2021: puo' sparire anche lui"
	fi
	if grep -q "Cannot get .* sources" "${LOG}"; then
		echo
		warn "Un sorgente non si scarica piu'. Per non scoprirli uno per volta:"
		warn "    ./lakka-rf35h/check-sources.sh $(hp "${WORKDIR}")"
		warn "li prova tutti e dice quali mancano; poi si aggiungono a"
		warn "seed-sources.sh prendendoli dal pool di Ubuntu."
	fi
	die "build fallita (exit ${RC}). Ultimi errori:
$(grep -nE 'error:|Error [0-9]|FAILED|No such file' "${LOG}" | tail -15)

Il log completo e' in $(hp "${LOG}"). Rilanciando lo stesso comando la build riprende
da dove si e' fermata."
fi

# --- risultato ---------------------------------------------------------------
check_kernel || warn "kernel incompleto: vedi sopra"

say "Fatto"
find_image
if [ -n "${IMG}" ] && [ -f "${TAR}" ]; then
	check_image || die "l'immagine costruita non e' conforme: non flasharla"
fi

if [ -n "${IMG}" ]; then
	echo "  immagine: $(hp "${IMG}")"
	echo "  dimensione: $(du -h "${IMG}" | cut -f1)"
	if [ -f "${TAR}" ]; then
		echo
		echo "  AGGIORNAMENTO senza riscrivere la card (ROM, salvataggi e configurazioni"
		echo "  restano): copia il .tar in /storage/.update/ sul device e riavvia."
		echo "  L'init scrive KERNEL, SYSTEM e il DTB in /flash; il loader a 32K viene"
		echo "  riscritto con il known-good che e' gia' li', cioe' resta com'e'. Via ssh:"
		echo
		echo "    scp '$(hp "${TAR}")' root@<ip>:/storage/.update/ && ssh root@<ip> reboot"
		echo
		echo "  oppure dal PC con la card nel lettore: nella partizione 2 (ext4), in .update/."
		echo "  La scrittura completa qui sotto serve solo la prima volta o per cambiare"
		echo "  il bootloader."
	fi
	echo
	echo "  Scrittura su SD (SOSTITUISCI sdX, e usa una SD dedicata: il loader va"
	echo "  scritto raw a 32K e sovrascrive quello che c'e'):"
	echo
	echo "    zcat '$(hp "${IMG}")' | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress"
	echo
	echo "  Al primo boot la console e' su ttyS1 a 1500000 8N1, ma il tuo loader"
	echo "  arriva fino al kernel da solo: se lo schermo resta nero il problema e'"
	echo "  a valle del bootloader."
else
	warn "build conclusa senza errori ma non trovo l'immagine sotto $(hp "${WORKDIR}/target")"
fi
