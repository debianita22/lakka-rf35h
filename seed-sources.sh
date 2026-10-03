#!/bin/sh
# seed-sources.sh - riempie la cache dei sorgenti per i pacchetti la cui URL
# a monte e' morta.
#
#   ./seed-sources.sh [percorso/dell/albero/lakka]
#
# Non solo Debian: ftpmirror.gnu.org e' un redirector che sceglie un mirror a
# caso, e non tutti i mirror hanno tutto. parted-3.7 e' finito qui per questo.
#
# Perche' serve: il pool di Debian tiene solo la versione corrente di ogni
# pacchetto. Quando ne arriva una nuova, il tarball che Lakka ha pinnato
# sparisce e il download da 404. scripts/get_archive ha un mirror di riserva
# (sources.libreelec.tv), ma non tutto ci finisce: nella build del
# 18 settembre 2026 ventuno URL hanno dato 404 e per tutte tranne una il
# mirror ha rimediato. L'unica rimasta a piedi era fakeroot.
#
# Gli stessi tarball, bit per bit, stanno nel pool di Ubuntu, che le versioni
# vecchie le tiene. Questo script li prende da li' e scrive i due file stamp
# che get_archive controlla, cosi' _get_file_already_downloaded() dice "gia'
# fatto" e il download non viene nemmeno tentato.
#
# Se un giorno non servisse piu', si vede subito: lo script dice "gia' in
# cache" e non fa niente.

set -eu

# Riconoscere l'albero da "ha una cartella packages/" non basta: ce l'ha anche
# questo overlay, e puntarcelo per sbaglio riempirebbe una cache che nessuno
# legge. scripts/get_archive e packages/virtual esistono solo nell'albero vero.
is_lakka_tree() {
	[ -f "$1/scripts/get_archive" ] && [ -d "$1/packages/virtual" ]
}

SELF="$(cd "$(dirname "$0")" && pwd)"
if [ $# -gt 0 ]; then
	TREE="$1"
else
	# I posti dove finisce con i due script di questo overlay.
	TREE=""
	for c in ./lakka-rf35h-build "${SELF}/../lakka-rf35h-build" "${SELF}/lakka-rf35h-build"; do
		if is_lakka_tree "${c}"; then TREE="${c}"; break; fi
	done
	[ -n "${TREE}" ] || {
		echo "Non trovo l'albero Lakka. Passamelo:" >&2
		echo "  ./seed-sources.sh /percorso/di/lakka-rf35h-build" >&2
		echo "Per cercarlo:  find ~ -maxdepth 4 -name get_archive -path '*/scripts/*'" >&2
		exit 1
	}
	echo "albero: ${TREE}"
fi

is_lakka_tree "${TREE}" || {
	echo "Non sembra un albero Lakka: ${TREE}" >&2
	echo "  manca scripts/get_archive oppure packages/virtual" >&2
	echo "Per cercarlo:  find ~ -maxdepth 4 -name get_archive -path '*/scripts/*'" >&2
	exit 1
}
SRC="${TREE}/sources"

# nome_in_cache | url_da_cui_prendere | url_da_scrivere_nello_stamp | sha256
SEEDS="
fakeroot|fakeroot-1.37.2.tar.gz|http://archive.ubuntu.com/ubuntu/pool/main/f/fakeroot/fakeroot_1.37.2.orig.tar.gz|http://ftp.debian.org/debian/pool/main/f/fakeroot/fakeroot_1.37.2.orig.tar.gz|0eea60fbe89771b88fcf415c8f2f0a6ccfe9edebbcf3ba5dc0212718d98884db
netbase|netbase-6.5.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/n/netbase/netbase_6.5.tar.xz|http://ftp.debian.org/debian/pool/main/n/netbase/netbase_6.5.tar.xz|9116047aebbaa1698934052d01c6e09b4c3aed643e93df63d2ddcbec243c26d1
parted|parted-3.7.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/p/parted/parted_3.7.orig.tar.xz|https://ftpmirror.gnu.org/parted/parted-3.7.tar.xz|008de57561a4f3c25a0648e66ed11e7b30be493889b64334a6d70f2c1951ef7b
ccid|ccid-1.7.1.tar.xz|http://archive.ubuntu.com/ubuntu/pool/universe/c/ccid/ccid_1.7.1.orig.tar.xz|https://ccid.apdu.fr/files/ccid-1.7.1.tar.xz|32799ab16fe6e493c9452be3823f21810fbe80b884021a6f6f3fa69f26be5c86
pcsc-lite|pcsc-lite-2.4.1.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/p/pcsc-lite/pcsc-lite_2.4.1.orig.tar.xz|https://pcsclite.apdu.fr/files/pcsc-lite-2.4.1.tar.xz|afd3ba68c8000d2be048dc292df99a9812df9ad2efaf0a366eea22ac1faa19a7
"

# Un secondo modo, per i tarball che non esistono da nessuna parte come file.
# Gli snapshot di gitweb sono "git archive" e sono deterministici: dato il
# commit, tar e bzip2 producono sempre gli stessi byte. pax-utils sta qui
# perche' gitweb.gentoo.org non serve piu' lo snapshot, ma il repo e' su
# github e ricostruirlo da' esattamente lo stesso sha256 che Lakka pinna
# (verificato: prefix "pax-utils-1.3.10/", bzip2 -9).
#
# nome | file | repo | ref | prefix | url_stamp | sha256
GIT_SEEDS="
pax-utils|pax-utils-1.3.10.tar.bz2|https://github.com/gentoo/pax-utils.git|v1.3.10|pax-utils-1.3.10/|https://gitweb.gentoo.org/proj/pax-utils.git/snapshot/pax-utils-1.3.10.tar.bz2|e4813381dd3264c08d9693ef34b87248558acc5e63c55941dcfeca6dd62627c2
"

rc=0
# Heredoc e non "echo | while": in pipe il ciclo gira in una subshell e le
# modifiche a rc andrebbero perse, quindi lo script uscirebbe 0 anche dopo un
# fallimento - e chi lo chiama crederebbe che la cache sia a posto.
while IFS='|' read -r pkg name url stamp_url sha; do
	[ -n "${pkg}" ] || continue
	dest="${SRC}/${pkg}/${name}"

	# Stesso controllo che fa _get_file_already_downloaded(): file piu' i due
	# stamp, e lo stamp sha deve combaciare.
	if [ -f "${dest}" ] && [ -f "${dest}.url" ] && [ -f "${dest}.sha256" ] \
	   && [ "$(cat "${dest}.sha256")" = "${sha}" ]; then
		printf '  %-24s gia in cache\n' "${pkg}"
		continue
	fi

	mkdir -p "${SRC}/${pkg}"
	printf '  %-24s scarico... ' "${pkg}"
	if ! curl -sL --fail --connect-timeout 30 --retry 3 -o "${dest}.tmp" "${url}"; then
		echo "FALLITO (${url})"
		rc=1
		continue
	fi

	got="$(sha256sum "${dest}.tmp" | cut -d' ' -f1)"
	if [ "${got}" != "${sha}" ]; then
		echo "sha256 DIVERSO"
		echo "      ottenuto:  ${got}"
		echo "      atteso:    ${sha}"
		echo "      Non lo metto in cache: un tarball diverso da quello pinnato"
		echo "      farebbe fallire la build piu' avanti, in modo meno chiaro."
		rm -f "${dest}.tmp"
		rc=1
		continue
	fi

	mv "${dest}.tmp" "${dest}"
	# Lo stamp .url porta l'URL originale del package.mk, non quella da cui ho
	# preso il file: get_archive lo usa solo per ricordare da dove veniva.
	printf '%s\n' "${stamp_url}" > "${dest}.url"
	printf '%s\n' "${sha}" > "${dest}.sha256"
	echo "ok ($(stat -c%s "${dest}") byte, sha256 verificato)"
done <<EOF
${SEEDS}
EOF

while IFS='|' read -r pkg name repo ref prefix stamp_url sha; do
	[ -n "${pkg}" ] || continue
	dest="${SRC}/${pkg}/${name}"

	if [ -f "${dest}" ] && [ -f "${dest}.url" ] && [ -f "${dest}.sha256" ] \
	   && [ "$(cat "${dest}.sha256")" = "${sha}" ]; then
		printf '  %-24s gia in cache\n' "${pkg}"
		continue
	fi

	command -v git >/dev/null || { printf '  %-24s serve git\n' "${pkg}"; rc=1; continue; }
	mkdir -p "${SRC}/${pkg}"
	printf '  %-24s ricostruisco da git... ' "${pkg}"
	work="$(mktemp -d)"
	if ! git clone -q --depth 1 --branch "${ref}" "${repo}" "${work}" 2>/dev/null; then
		echo "clone FALLITO (${repo})"
		rm -rf "${work}"; rc=1; continue
	fi
	( cd "${work}" && git archive --format=tar --prefix="${prefix}" "${ref}" ) \
		| bzip2 -9 > "${dest}.tmp" 2>/dev/null
	rm -rf "${work}"

	got="$(sha256sum "${dest}.tmp" | cut -d' ' -f1)"
	if [ "${got}" != "${sha}" ]; then
		echo "sha256 DIVERSO"
		echo "      ottenuto:  ${got}"
		echo "      atteso:    ${sha}"
		rm -f "${dest}.tmp"; rc=1; continue
	fi
	mv "${dest}.tmp" "${dest}"
	printf '%s\n' "${stamp_url}" > "${dest}.url"
	printf '%s\n' "${sha}" > "${dest}.sha256"
	echo "ok ($(stat -c%s "${dest}") byte, sha256 verificato)"
done <<EOF
${GIT_SEEDS}
EOF

[ "${rc}" = "0" ] || echo "Qualcosa non e' entrato in cache: la build si fermera' li'." >&2
exit ${rc}
