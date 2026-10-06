#!/bin/sh
# check-sources.sh - controlla PRIMA della build quali sorgenti non si
# scaricano piu', invece di scoprirlo un pacchetto alla volta.
#
#   ./check-sources.sh [percorso/dell/albero] [--jobs N]
#
# Li controlla tutti, in parallelo: circa un migliaio di URL, un paio di
# minuti. Filtrare per :host sembrava piu' furbo ma si perdeva netbase, che
# host non e' e la build l'avrebbe fermata lo stesso.
#
# Per ogni pacchetto prova l'URL del package.mk e poi il mirror di LibreELEC,
# esattamente come fa scripts/get_archive (per gli URL GNU, prima ancora
# mirrors.kernel.org; per ultimo tarballs.nixos.org per sha256:
# integration/source-mirrors-rf35h.patch): se almeno uno risponde, quel
# pacchetto non e' un problema. Stampa solo quelli dove falliscono tutti.
#
# Quello che trova va aggiunto a seed-sources.sh. Gli stessi tarball stanno
# quasi sempre nel pool di Ubuntu, che le versioni vecchie le tiene:
#   http://archive.ubuntu.com/ubuntu/pool/main/<iniziale>/<nome>/

set -eu

TREE=""
PAR=16
while [ $# -gt 0 ]; do
	case "$1" in
		--jobs) PAR="$2"; shift 2 ;;
		*)      TREE="$1"; shift ;;
	esac
done
[ -n "${TREE}" ] || TREE="./lakka-rf35h-build"

[ -f "${TREE}/scripts/get_archive" ] && [ -d "${TREE}/packages/virtual" ] || {
	echo "Non sembra un albero Lakka: ${TREE}" >&2
	exit 1
}

MIRROR="https://sources.libreelec.tv/mirror"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

echo "Leggo i package.mk..."
# PKG_NAME, PKG_VERSION e PKG_URL stanno su righe proprie in tutti i
# package.mk. L'URL contiene ${PKG_NAME} e ${PKG_VERSION}: li sostituiamo noi
# invece di eseguire il file, che sarebbe eseguire codice arbitrario.
# Anche i package del device (quelli dell'overlay): fra loro re3, che si
# scarica da un mirror git di un repository rimosso, e la libreria standard
# Rust per aarch64.
DEVPKG="${TREE}/projects/Rockchip/devices/RK3326/packages"
find "${TREE}/packages" "${DEVPKG}" -name package.mk 2>/dev/null | while read -r mk; do
	name="$(sed -n 's/^PKG_NAME="\([^"]*\)".*/\1/p' "${mk}" | head -1)"
	ver="$(sed -n 's/^PKG_VERSION="\([^"]*\)".*/\1/p' "${mk}" | head -1)"
	url="$(sed -n 's/^PKG_URL="\([^"]*\)".*/\1/p' "${mk}" | head -1)"
	sha="$(sed -n 's/^PKG_SHA256="\([^"]*\)".*/\1/p' "${mk}" | head -1)"
	site="$(sed -n 's/^PKG_SITE="\([^"]*\)".*/\1/p' "${mk}" | head -1)"
	[ -n "${name}" ] && [ -n "${url}" ] || continue
	case "${url}" in
		*'$('*|*'`'*) continue ;;   # URL calcolato: non lo sappiamo risolvere
		file://*) continue ;;
	esac
	case "${url}" in
		# i repo git non passano da get_archive: si controllano solo quelli
		# dell'overlay, con git ls-remote (i core di Lakka sono un centinaio)
		git://*|*.git) case "${mk}" in "${DEVPKG}"/*) ;; *) continue ;; esac ;;
	esac
	# Con e senza graffe: i package.mk usano entrambe le forme.
	url="$(printf '%s' "${url}" \
		| sed -e "s|\${PKG_NAME}|${name}|g" -e "s|\${PKG_VERSION}|${ver}|g" \
		      -e "s|\${PKG_SITE}|${site}|g" \
		      -e "s|\$PKG_NAME|${name}|g"   -e "s|\$PKG_VERSION|${ver}|g")"
	case "${url}" in *'${'*|*'$'*) continue ;; esac   # restano variabili: saltiamo
	printf '%s\t%s\t%s\t%s\n' "${name}" "${ver}" "${url}" "${sha}"
done | sort -u > "${TMP}/list"

tot=$(wc -l < "${TMP}/list")
echo "Controllo ${tot} URL, ${PAR} alla volta (prima il package.mk, poi il mirror)..."
echo

# Il controllo di un singolo URL, in uno script a parte perche' xargs lo
# esegue in processi suoi.
cat > "${TMP}/one.sh" <<'ONE'
#!/bin/sh
IFS='	' read -r name ver url sha <<EOF
$1
EOF
TREE="$2"; MIRROR="$3"; OUT="$4"
case "${url}" in
	git://*|*.git)
		# il repository risponde? (il commit si vede solo alla build)
		GIT_TERMINAL_PROMPT=0 timeout 60 git ls-remote --exit-code "${url}" HEAD >/dev/null 2>&1 && exit 0
		printf '%s|%s|%s|%s\n' "${name}" "(git)" "${url}" "${ver}" >> "${OUT}"
		printf '  %-24s %s (git)\n' "${name}" "${url}"
		exit 0 ;;
esac
base="${url##*/}"
case "${base}" in
	"${name}-${ver}".*) sname="${base}" ;;
	*.tar.bz2|*.tar.gz|*.tar.xz|*.tar.zst) sname="${name}-${ver}.tar.${base##*.}" ;;
	*) sname="${name}-${ver}.${base##*.}" ;;
esac
[ -f "${TREE}/sources/${name}/${sname}" ] && exit 0

# HEAD prima perche' costa niente, ma non ci si puo' fermare li': parecchi
# server rispondono male a HEAD pur servendo benissimo un GET, e gitweb
# genera lo snapshot al volo, quindi puo' metterci piu' del timeout. Se HEAD
# fallisce si riprova con un GET di un byte solo.
try() {
	curl -sI --fail --connect-timeout 15 --max-time 20 -o /dev/null "$1" 2>/dev/null && return 0
	curl -s --fail -r 0-0 --connect-timeout 20 --max-time 60 -o /dev/null "$1" 2>/dev/null && return 0
	return 1
}
# come integration/source-mirrors-rf35h.patch: un URL GNU prima da mirrors.kernel.org
case "${url}" in
	https://ftpmirror.gnu.org/gnu/*) try "https://mirrors.kernel.org/gnu/${url#https://ftpmirror.gnu.org/gnu/}" && exit 0 ;;
	https://ftpmirror.gnu.org/*)     try "https://mirrors.kernel.org/gnu/${url#https://ftpmirror.gnu.org/}" && exit 0 ;;
	https://ftp.gnu.org/gnu/*)       try "https://mirrors.kernel.org/gnu/${url#https://ftp.gnu.org/gnu/}" && exit 0 ;;
	https://ftp.gnu.org/pub/gnu/*)   try "https://mirrors.kernel.org/gnu/${url#https://ftp.gnu.org/pub/gnu/}" && exit 0 ;;
esac
try "${url}" && exit 0
try "${MIRROR}/${name}/${sname}" && exit 0
# e per ultimo il mirror di nixpkgs per sha256 (stesso patch)
[ -n "${sha}" ] && try "https://tarballs.nixos.org/sha256/${sha}" && exit 0
printf '%s|%s|%s|%s\n' "${name}" "${sname}" "${url}" "${sha}" >> "${OUT}"
printf '  %-24s %s\n' "${name}" "${url}"
ONE
chmod +x "${TMP}/one.sh"

# shellcheck disable=SC2016
xargs -d '\n' -I{} -P "${PAR}" "${TMP}/one.sh" "{}" "${TREE}" "${MIRROR}" "${TMP}/fails" < "${TMP}/list"

echo
if [ -f "${TMP}/fails" ]; then
	echo "Questi non si scaricano da nessuna parte."
	echo "Cercali nel pool di Ubuntu e aggiungili a seed-sources.sh:"
	echo
	sed 's/^/  /' "${TMP}/fails"
	exit 1
fi
echo "Tutti raggiungibili."
