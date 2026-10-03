#!/bin/sh
# repin-checksum.sh - quando una forge cambia il modo di generare gli archivi
# e lo sha256 pinnato non torna piu', questo verifica che il contenuto sia
# comunque quello del tag e, solo in quel caso, riscrive il checksum.
#
#   ./repin-checksum.sh <albero> <percorso/package.mk> <repo.git> <ref>
#
# esempio:
#   ./repin-checksum.sh ./lakka-rf35h-build \
#       packages/wayland/util/foot/package.mk \
#       https://codeberg.org/dnkl/foot.git 1.26.1
#
# Non aggiorna niente sulla fiducia: scarica il tarball, clona il repo al tag
# e confronta i due alberi file per file. Se differiscono si ferma.
#
# Nota: scrive dentro l'albero di build, quindi la modifica sparisce al primo
# "git checkout -- ." . Alla fine stampa anche la patch da mandare, per
# metterla nell'overlay una volta per tutte.

set -eu
[ $# -eq 4 ] || { echo "Uso: $0 <albero> <percorso/package.mk> <repo.git> <ref>"; exit 1; }
TREE="$1"; REL="$2"; REPO="$3"; REF="$4"
MK="${TREE}/${REL}"
[ -f "${MK}" ] || { echo "non trovo ${MK}"; exit 1; }

VER="$(sed -n 's/^PKG_VERSION="\([^"]*\)".*/\1/p' "${MK}" | head -1)"
NAME="$(sed -n 's/^PKG_NAME="\([^"]*\)".*/\1/p' "${MK}" | head -1)"
OLD="$(sed -n 's/^PKG_SHA256="\([^"]*\)".*/\1/p' "${MK}" | head -1)"
URL="$(sed -n 's/^PKG_URL="\([^"]*\)".*/\1/p' "${MK}" | head -1)"
URL="$(printf '%s' "${URL}" \
	| sed -e "s|\${PKG_NAME}|${NAME}|g" -e "s|\${PKG_VERSION}|${VER}|g" \
	      -e "s|\$PKG_NAME|${NAME}|g"   -e "s|\$PKG_VERSION|${VER}|g")"
echo "${NAME} ${VER}"
echo "  url: ${URL}"
echo "  pin: ${OLD}"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
curl -sL --fail -o "${W}/t" "${URL}" || { echo "  download fallito"; exit 1; }
NEW="$(sha256sum "${W}/t" | cut -d' ' -f1)"
echo "  ora: ${NEW}"
if [ "${NEW}" = "${OLD}" ]; then
	echo
	echo "  Combaciano gia': niente da fare."
	exit 0
fi

mkdir -p "${W}/tar"
tar xf "${W}/t" -C "${W}/tar" 2>/dev/null || { echo "  archivio illeggibile"; exit 1; }
n="$(ls "${W}/tar" | wc -l)"
if [ "${n}" = "1" ]; then SRC="${W}/tar/$(ls "${W}/tar")"; else SRC="${W}/tar"; fi

git clone -q --depth 1 --branch "${REF}" "${REPO}" "${W}/git" 2>/dev/null \
	|| { echo "  clone fallito"; exit 1; }
rm -rf "${W}/git/.git"

echo
if ! diff -r -q "${SRC}" "${W}/git" > "${W}/d" 2>&1; then
	echo "  DIFFERENZE fra il tarball e il tag ${REF}:"
	sed 's/^/    /' "${W}/d" | head -20
	echo
	echo "  Non tocco il checksum. Guarda cosa sono prima di decidere."
	exit 1
fi

echo "  IDENTICI: il tarball e' il tag ${REF}, e' cambiato solo l'impacchettamento."
sed -i "s|^PKG_SHA256=\"${OLD}\"|PKG_SHA256=\"${NEW}\"|" "${MK}"
echo "  Checksum aggiornato in ${REL}"
echo
echo "  La patch da mettere nell'overlay:"
echo
printf -- '--- a/%s\n+++ b/%s\n' "${REL}" "${REL}"
printf -- '-PKG_SHA256="%s"\n+PKG_SHA256="%s"\n' "${OLD}" "${NEW}"
