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
# ncurses (5/10/2026): invisible-mirror.net non risponde dai runner di GitHub
# (timeout, due tentativi della build #18) e il mirror di LibreELEC da' 404;
# la stessa release e' su ftp.gnu.org. Se i byte non fossero gli stessi lo
# sha256 di Lakka lo direbbe e il file non verrebbe usato.
# I pacchetti GNU (6/10/2026): ftpmirror.gnu.org, il redirector verso un
# mirror a caso, dai runner va in timeout (build #22 ferma su make 4.4.1, due
# tentativi). Stessi file presi da ftp.gnu.org, lo stamp tiene l'URL del
# package.mk. Sono quelli dell'albero pinnato con ftpmirror nel PKG_URL.
SEEDS="
fakeroot|fakeroot-1.37.2.tar.gz|http://archive.ubuntu.com/ubuntu/pool/main/f/fakeroot/fakeroot_1.37.2.orig.tar.gz|http://ftp.debian.org/debian/pool/main/f/fakeroot/fakeroot_1.37.2.orig.tar.gz|0eea60fbe89771b88fcf415c8f2f0a6ccfe9edebbcf3ba5dc0212718d98884db
netbase|netbase-6.5.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/n/netbase/netbase_6.5.tar.xz|http://ftp.debian.org/debian/pool/main/n/netbase/netbase_6.5.tar.xz|9116047aebbaa1698934052d01c6e09b4c3aed643e93df63d2ddcbec243c26d1
parted|parted-3.7.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/p/parted/parted_3.7.orig.tar.xz|https://ftpmirror.gnu.org/parted/parted-3.7.tar.xz|008de57561a4f3c25a0648e66ed11e7b30be493889b64334a6d70f2c1951ef7b
ccid|ccid-1.7.1.tar.xz|http://archive.ubuntu.com/ubuntu/pool/universe/c/ccid/ccid_1.7.1.orig.tar.xz|https://ccid.apdu.fr/files/ccid-1.7.1.tar.xz|32799ab16fe6e493c9452be3823f21810fbe80b884021a6f6f3fa69f26be5c86
pcsc-lite|pcsc-lite-2.4.1.tar.xz|http://archive.ubuntu.com/ubuntu/pool/main/p/pcsc-lite/pcsc-lite_2.4.1.orig.tar.xz|https://pcsclite.apdu.fr/files/pcsc-lite-2.4.1.tar.xz|afd3ba68c8000d2be048dc292df99a9812df9ad2efaf0a366eea22ac1faa19a7
ncurses|ncurses-6.6.tar.gz|https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz|http://invisible-mirror.net/archives/ncurses/ncurses-6.6.tar.gz|355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11
diffutils|diffutils-3.11.tar.xz|https://ftp.gnu.org/gnu/diffutils/diffutils-3.11.tar.xz|https://ftpmirror.gnu.org/diffutils/diffutils-3.11.tar.xz|a73ef05fe37dd585f7d87068e4a0639760419f810138bd75c61ddaa1f9e2131e
patch|patch-2.8.tar.xz|https://ftp.gnu.org/gnu/patch/patch-2.8.tar.xz|https://ftpmirror.gnu.org/patch/patch-2.8.tar.xz|f87cee69eec2b4fcbf60a396b030ad6aa3415f192aa5f7ee84cad5e11f7f5ae3
screen|screen-5.0.1.tar.gz|https://ftp.gnu.org/gnu/screen/screen-5.0.1.tar.gz|https://ftpmirror.gnu.org/screen/screen-5.0.1.tar.gz|2dae36f4db379ffcd14b691596ba6ec18ac3a9e22bc47ac239789ab58409869d
autoconf-archive|autoconf-archive-2024.10.16.tar.xz|https://ftp.gnu.org/gnu/autoconf-archive/autoconf-archive-2024.10.16.tar.xz|https://ftpmirror.gnu.org/autoconf-archive/autoconf-archive-2024.10.16.tar.xz|7bcd5d001916f3a50ed7436f4f700e3d2b1bade3ed803219c592d62502a57363
autoconf|autoconf-2.73.tar.xz|https://ftp.gnu.org/gnu/autoconf/autoconf-2.73.tar.xz|https://ftpmirror.gnu.org/autoconf/autoconf-2.73.tar.xz|9fd672b1c8425fac2fa67fa0477b990987268b90ff36d5f016dae57be0d6b52e
automake|automake-1.18.1.tar.xz|https://ftp.gnu.org/gnu/automake/automake-1.18.1.tar.xz|https://ftpmirror.gnu.org/automake/automake-1.18.1.tar.xz|168aa363278351b89af56684448f525a5bce5079d0b6842bd910fdd3f1646887
bison|bison-3.8.2.tar.xz|https://ftp.gnu.org/gnu/bison/bison-3.8.2.tar.xz|https://ftpmirror.gnu.org/bison/bison-3.8.2.tar.xz|9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2
libtool|libtool-2.5.4.tar.xz|https://ftp.gnu.org/gnu/libtool/libtool-2.5.4.tar.xz|https://ftpmirror.gnu.org/libtool/libtool-2.5.4.tar.xz|f81f5860666b0bc7d84baddefa60d1cb9fa6fceb2398cc3baca6afaa60266675
m4|m4-1.4.21.tar.bz2|https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.bz2|https://ftpmirror.gnu.org/m4/m4-1.4.21.tar.bz2|dc487e11d2f0c9e01555bb1af26be4eae983ec8f0726746505b4327186eb21fc
make|make-4.4.1.tar.gz|https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz|https://ftpmirror.gnu.org/make/make-4.4.1.tar.gz|dd16fb1d67bfab79a72f5e8390735c49e3e8e70b4945a15ab1f81ddb78658fb3
mpc|mpc-1.4.1.tar.xz|https://ftp.gnu.org/gnu/mpc/mpc-1.4.1.tar.xz|https://ftpmirror.gnu.org/mpc/mpc-1.4.1.tar.xz|91204cd32f164bd3b7c992d4a6a8ce6519511aadab30f78b6982d0bf8d73e931
mpfr|mpfr-4.2.2.tar.xz|https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz|https://ftpmirror.gnu.org/mpfr/mpfr-4.2.2.tar.xz|b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01
readline|readline-8.3.tar.gz|https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz|https://ftpmirror.gnu.org/readline/readline-8.3.tar.gz|fe5383204467828cd495ee8d1d3c037a7eba1389c22bc6a041f627976f9061cc
gcc|gcc-16.1.0.tar.xz|https://ftp.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz|https://ftpmirror.gnu.org/gnu/gcc/gcc-16.1.0/gcc-16.1.0.tar.xz|50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79
libidn2|libidn2-2.3.8.tar.gz|https://ftp.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz|https://ftpmirror.gnu.org/gnu/libidn/libidn2-2.3.8.tar.gz|f557911bf6171621e1f72ff35f5b1825bb35b52ed45325dcdee931e5d3c0787a
mtools|mtools-4.0.49.tar.bz2|https://ftp.gnu.org/gnu/mtools/mtools-4.0.49.tar.bz2|https://ftpmirror.gnu.org/mtools/mtools-4.0.49.tar.bz2|6fe5193583d6e7c59da75e63d7234f76c0b07caf33b103894f46f66a871ffc9f
libmicrohttpd|libmicrohttpd-1.0.5.tar.gz|https://ftp.gnu.org/gnu/libmicrohttpd/libmicrohttpd-1.0.5.tar.gz|https://ftpmirror.gnu.org/libmicrohttpd/libmicrohttpd-1.0.5.tar.gz|b46d00f58efa6f497b97d2e782c4ee66301d412ddd855dd3068518b3a2cd3ea2
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
