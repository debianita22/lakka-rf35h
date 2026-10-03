#!/bin/sh
# probe-gitea.sh - prova a ricostruire un tarball servito al volo da Gitea
# (codeberg) partendo dal repo git, e dice quale combinazione dà lo stesso
# sha256 che Lakka si aspetta.
#
# Prova gzip e bzip2, piu' i prefissi che le forge usano di solito. Validato
# su pax-utils, di cui la risposta era gia' nota: la ritrova.
#
#   ./probe-gitea.sh https://codeberg.org/dnkl/fcft.git 3.3.3 fcft \
#       c0d8d485b45b1af829f73101d6588f404a32bf3c7543236b1a4707d44be81b60
#
# Serve perché quei tarball non sono file su disco: Gitea li genera a ogni
# richiesta con "git archive". Se cambia la versione di git o le opzioni di
# compressione, i byte cambiano e lo sha256 pinnato non torna più - che è
# esattamente quello che è successo a fcft:
#
#   Incorrect checksum: got b0c0f4a5... wanted c0d8d485...
#
# Ha funzionato così per pax-utils: ricostruito, sha identico, nessun
# checksum da toccare. Se qui nessuna combinazione combacia, vuol dire che il
# contenuto del tag è cambiato e allora è un altro discorso.

set -eu
[ $# -eq 4 ] || { echo "Uso: $0 <repo.git> <ref> <prefisso-senza-slash> <sha256-atteso>"; exit 1; }
REPO="$1"; REF="$2"; NAME="$3"; WANT="$4"

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
echo "Clono ${REPO} al ref ${REF}..."
git clone -q --depth 1 --branch "${REF}" "${REPO}" "${W}/r" 2>/dev/null \
	|| { echo "clone fallito"; exit 1; }

found=""
try() {
	got="$(sh -c "$2" | sha256sum | cut -d' ' -f1)"
	if [ "${got}" = "${WANT}" ]; then
		printf '  %-46s %s  <<< COMBACIA\n' "$1" "$(echo "${got}" | cut -c1-16)..."
		found="$1"
	else
		printf '  %-46s %s\n' "$1" "$(echo "${got}" | cut -c1-16)..."
	fi
}

cd "${W}/r"
# I tag spesso sono "v1.2.3" mentre il prefisso nel tarball e' "nome-1.2.3/":
# provo il ref cosi' com'e' e senza la v iniziale.
BARE="${REF#v}"
for pfx in "${NAME}/" "${NAME}-${BARE}/" "${NAME}-${REF}/" ""; do
	try "format=tar.gz prefix='${pfx}'" \
	    "git archive --format=tar.gz --prefix='${pfx}' '${REF}'"
	for lvl in 9 6 1; do
		try "tar | gzip -n -${lvl} prefix='${pfx}'" \
		    "git archive --format=tar --prefix='${pfx}' '${REF}' | gzip -n -${lvl}"
		try "tar | bzip2 -${lvl} prefix='${pfx}'" \
		    "git archive --format=tar --prefix='${pfx}' '${REF}' | bzip2 -${lvl}"
	done
done

echo
echo "atteso: $(echo "${WANT}" | cut -c1-16)..."
if [ -n "${found}" ]; then
	echo
	printf 'Trovata: %s\n' "${found}"
	echo "Mandami questa riga e la metto in seed-sources.sh."
else
	echo
	echo "Nessuna combinazione combacia: il contenuto del tag è cambiato,"
	echo "non solo il modo di impacchettarlo. Da valutare a parte."
fi
