#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Lakka RF35H - costruisce dentro un container Ubuntu 24.04.
#
#   ./build-in-docker.sh --deva <path>       la build completa
#   ./build-in-docker.sh --deva <path> --dry-run
#   ./build-in-docker.sh --deva <path> --verify-only
#                                            controlla l'ultima immagine fatta
#   ./build-in-docker.sh [--deva <path>] --sh 'comando'
#                                            un comando nel container, in /work
#   ./build-in-docker.sh --deva <path> --re3 <path>
#                                            con GTA III (re3), dal suo pacchetto
#
# --deva e --re3 possono stare ovunque sull'host: vengono montati in sola
# lettura su /deva e /re3 e gli argomenti riscritti. --workdir invece deve
# restare relativo, perche' dentro si vede solo la cartella di lavoro.
# RE3_PGO, se c'e', arriva alla build: una cartella di profili va messa dentro
# la cartella di lavoro e data col percorso del container (/work/...).
#
# Perche': il "host-gcc" di LibreELEC non e' un compilatore suo, e' un wrapper
# attorno a quello di sistema (packages/devel/ccache/package.mk). Su Arch e
# CachyOS quello e' gcc 15+, ed e' la stessa classe di guai che devaOS ha gia'
# incontrato con Buildroot - vedi il commento in testa al suo
# build-in-docker.sh. Ubuntu 24.04 ha gcc 13: abbastanza moderno per Lakka
# devel, abbastanza vecchio da non inciampare.
#
# Stessa struttura del build-in-docker.sh di devaOS, comprese le due cose che
# li' erano gia' state imparate a spese proprie:
#   - il contesto di build sta in una directory sua, non in /tmp condivisa,
#     perche' l'engine legge tutto il contesto e su /tmp trova file di altri
#     processi che non puo' leggere;
#   - l'utente nel container ha l'UID e il GID dell'host, altrimenti l'output
#     esce di proprieta' di root.
#
# La seconda qui non e' solo comodita'. config/options di LibreELEC comincia
# con "Do not build as root. Ever." e si ferma se EUID e' 0.

set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="$(cd "${HERE}/.." && pwd)"          # la cartella che contiene overlay e albero
IMAGE="lakka-rf35h-build"

[ "$(id -u)" != "0" ] || {
	echo "Non lanciarlo da root: il Dockerfile toglierebbe l'utente che occupa"
	echo "l'UID 0, e LibreELEC comunque si rifiuta di compilare da root."
	exit 1
}

# Montare la cartella sbagliata significa dare al container la home intera.
case "${WORK}" in
	"${HOME}"|/|/home|/usr|/etc)
		echo "La cartella di lavoro risulta ${WORK}: e' troppo in alto."
		echo "Scompatta l'overlay in una sua directory, per esempio ~/lakka-rf35h/."
		exit 1 ;;
esac

ENGINE="$(command -v docker || command -v podman || true)"
[ -n "${ENGINE}" ] || { echo "Serve docker o podman."; exit 1; }

CTX="$(mktemp -d)"
trap 'rm -rf "${CTX}"' EXIT

cat > "${CTX}/Dockerfile" <<'DOCKER'
FROM ubuntu:24.04
ARG DEBIAN_FRONTEND=noninteractive
# Questa lista deve soddisfare scripts/checkdeps di LibreELEC per intero, non
# "quello che sembra servire": scripts/image lo esegue da se' alla riga 22 e
# fallisce la build se manca qualcosa. Dentro il container non c'e' sudo,
# quindi non puo' rimediare da solo.
#
# u-boot-tools da' /usr/bin/mkimage, che serve a costruire il boot.scr di
# questa board. Non lo prendiamo dal package u-boot-tools:host di LibreELEC:
# per RK3326 e' rotto (unpack() cerca un .tar.bz2 fisso mentre il u-boot del
# device arriva da github come .tar.gz) e vorrebbe dire compilare i tool di
# uno U-Boot del 2018 col compilatore di oggi.
#
# xfonts-utils fornisce mkfontdir, mkfontscale e bdftopcf, che il ramo default
# di checkdeps (quello che prende Ubuntu) pretende. Mancava, e la build moriva
# subito dopo il dry run.
#
# Verificata eseguendo checkdeps vero su una Ubuntu 24.04: esce 0.
#
# squashfs-tools non serve a LibreELEC (mksquashfs se lo compila come
# pacchetto host) ma a tools/verify-image.sh, che a fine build apre il SYSTEM
# dell'immagine con unsquashfs. Senza, la verifica veniva saltata.
RUN apt-get update && apt-get install -y \
    build-essential git wget curl cpio unzip zip rsync bc file \
    bison flex texinfo gawk gperf lzop patchutils rdfind diffutils bzip2 \
    xz-utils zstd xsltproc ca-certificates \
    python3 python3-setuptools libssl-dev libncurses-dev xfonts-utils \
    libjson-perl libparse-yapp-perl libxml-parser-perl perl \
    default-jre-headless ccache u-boot-tools squashfs-tools \
 && rm -rf /var/lib/apt/lists/*
ARG UID=1000
ARG GID=1000
# Ubuntu 24.04 spedisce gia' "ubuntu:x:1000:1000", e 1000 e' l'UID del primo
# utente su quasi ogni desktop. Senza togliere chi occupa quei numeri,
# useradd fallisce e "USER b" punta a un utente inesistente: il container non
# parte affatto. Su 22.04 il problema non c'era, ed e' per questo che lo
# script di devaOS funziona cosi' com'e'.
RUN set -eux; \
    if getent passwd "$UID" >/dev/null; then \
      userdel -r "$(getent passwd "$UID" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    if getent group "$GID" >/dev/null; then \
      groupdel "$(getent group "$GID" | cut -d: -f1)" 2>/dev/null || true; \
    fi; \
    groupadd -g "$GID" b; \
    useradd -u "$UID" -g "$GID" -m b
USER b
DOCKER

echo ">> costruisco l'immagine del container (solo la prima volta)"
"${ENGINE}" build -t "${IMAGE}" \
	--build-arg UID="$(id -u)" --build-arg GID="$(id -g)" \
	"${CTX}"

# Il percorso passato a --deva sta fuori dalla cartella di lavoro: va montato
# a parte, e l'argomento riscritto col percorso che ha dentro il container.
# In sola lettura, perche' da li' si legge soltanto il loader.
#
# --sh si riconosce in qualunque posizione: prima valeva solo come primo
# argomento, e "--deva X --sh 'cmd'" finiva alla build come opzione
# sconosciuta, mentre "--sh 'cmd' --deva X" eseguiva "cmd --deva /deva".
DEVA=""
RE3=""
SHMODE=no
SHCMD=""
want=""
n=$#
i=0
while [ ${i} -lt ${n} ]; do
	a="$1"; shift
	case "${want}" in
		deva)
			DEVA="$(cd "$a" 2>/dev/null && pwd)" || { echo "--deva: percorso inesistente: $a"; exit 1; }
			set -- "$@" "/deva"
			want="" ;;
		re3)
			RE3="$(cd "$a" 2>/dev/null && pwd)" || { echo "--re3: percorso inesistente: $a"; exit 1; }
			set -- "$@" "/re3"
			want="" ;;
		sh)
			SHCMD="$a"
			want="" ;;
		*)
			case "$a" in
				--deva) want="deva"; set -- "$@" "--deva" ;;
				--re3)  want="re3"; set -- "$@" "--re3" ;;
				--sh)   want="sh"; SHMODE=yes ;;
				*)      set -- "$@" "$a" ;;
			esac ;;
	esac
	i=$((i+1))
done
[ -z "${want}" ] || { echo "--${want} vuole un argomento"; exit 1; }
[ "${SHMODE}" = no ] || [ -n "${SHCMD}" ] || { echo "--sh vuole un comando"; exit 1; }

# Le opzioni del container si mettono in testa ai parametri posizionali, in
# ordine inverso. Cosi' niente stringa "-v percorso" da espandere non quotata
# (un percorso con spazi si spezzerebbe in piu' argomenti), e i mount
# facoltativi (--deva, --re3) senza un ramo per ogni combinazione.
#
# RF35H_HOST_WORK: dentro, la cartella di lavoro e' /work. Il build script lo
# usa per stampare i comandi da incollare sull'host (riapplicare l'overlay,
# scp, dd) con i percorsi dell'host.
#
# --sh 'comando': una shell dentro, in /work. Serve per guardare l'albero di
# build: ha symlink con percorsi assoluti del container, che dall'host
# dondolano. Degli altri argomenti contano solo i mount.
#
# La ccache di LibreELEC sta in ${BUILD}/.ccache, cioe' dentro l'albero
# montato: sopravvive da sola fra una esecuzione e l'altra, senza altri mount.
if [ "${SHMODE}" = yes ]; then
	set -- sh -c "${SHCMD}"
else
	echo ">> lancio la build dentro Ubuntu 24.04"
	set -- ./lakka-rf35h/build-lakka-rf35h.sh --skip-deps "$@"
fi
set -- -w /work "${IMAGE}" "$@"
if [ -n "${RE3_PGO:-}" ]; then set -- -e RE3_PGO "$@"; fi
if [ -n "${RE3}" ]; then set -- -v "${RE3}:/re3:ro,z" "$@"; fi
if [ -n "${DEVA}" ]; then set -- -v "${DEVA}:/deva:ro,z" "$@"; fi
exec "${ENGINE}" run --rm -it -e RF35H_HOST_WORK="${WORK}" -v "${WORK}:/work:z" "$@"
