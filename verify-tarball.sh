#!/bin/sh
# verify-tarball.sh - stabilisce se un tarball il cui sha256 non combacia piu'
# col pin e' comunque autentico, confrontandolo con il tag git a monte.
#
#   ./verify-tarball.sh <url> <repo.git> <ref>
#
# Perche': le forge (Gitea, gitweb) generano gli archivi al volo. Quando
# cambiano versione di git o opzioni di compressione, i byte cambiano e lo
# sha256 pinnato non torna piu'. Il codice pero' e' lo stesso.
#
# "Diverso dal pin" e "manomesso" sono due cose diverse, e questo script
# distingue: scarica il tarball, clona il repo al tag, e confronta i due
# alberi file per file. Se sono identici, il tarball e' quel tag - e allora
# aggiornare il checksum e' legittimo, non e' disattivare un controllo.
#
# Se invece emergono differenze, NON vanno ignorate.

set -eu
[ $# -eq 3 ] || { echo "Uso: $0 <url> <repo.git> <ref>"; exit 1; }
URL="$1"; REPO="$2"; REF="$3"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT

echo "Scarico ${URL}"
curl -sL --fail -o "${W}/t" "${URL}" || { echo "download fallito"; exit 1; }
SHA="$(sha256sum "${W}/t" | cut -d' ' -f1)"
echo "  sha256: ${SHA}"
echo "  byte:   $(stat -c%s "${W}/t")"

mkdir -p "${W}/tar"
tar xf "${W}/t" -C "${W}/tar" 2>/dev/null || { echo "non e' un archivio leggibile"; exit 1; }
# le forge mettono tutto in una cartella sola
n="$(ls "${W}/tar" | wc -l)"
if [ "${n}" = "1" ]; then SRC="${W}/tar/$(ls "${W}/tar")"; else SRC="${W}/tar"; fi

echo "Clono ${REPO} al ref ${REF}"
git clone -q --depth 1 --branch "${REF}" "${REPO}" "${W}/git" 2>/dev/null \
	|| { echo "clone fallito"; exit 1; }
rm -rf "${W}/git/.git"

echo
echo "Confronto i due alberi..."
if diff -r -q "${SRC}" "${W}/git" > "${W}/diff" 2>&1; then
	echo "  IDENTICI: il tarball e' esattamente il tag ${REF}."
	echo
	echo "  Il contenuto e' autentico, e' cambiato solo l'impacchettamento."
	echo "  Il checksum da mettere nel package.mk e':"
	echo
	echo "    PKG_SHA256=\"${SHA}\""
else
	echo "  DIFFERENZE:"
	sed 's/^/    /' "${W}/diff" | head -30
	echo
	echo "  Non aggiornare il checksum finche' non e' chiaro perche'."
	echo "  (File soltanto nel tarball possono essere normali: alcune forge"
	echo "   aggiungono .gitattributes o file generati. File col contenuto"
	echo "   diverso no.)"
	exit 1
fi
