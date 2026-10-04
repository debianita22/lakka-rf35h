#!/bin/bash
# upstream-kernel.sh - c'e' un kernel 7.2.y piu' nuovo di quello della build?
#
#   upstream-kernel.sh [--dry-run] [--version X.Y.Z]
#
# Lo lancia .github/workflows/upstream.yml ogni settimana. Se kernel.org ha un
# 7.2.y piu' nuovo (o quello di --version), prima di toccare qualcosa:
#   - scarica il tarball e ne verifica la firma: la firma e' sul .tar non
#     compresso, le chiavi vengono dal WKD di kernel.org e devono avere le
#     impronte pubblicate su kernel.org/signature.html (sotto);
#   - controlla lo SHA256 del .tar.xz contro sha256sums.asc;
#   - applica le patch del kernel a fuzz 0, nell'ordine di scripts/unpack,
#     prese da un albero Lakka pinnato con apply.sh sopra: le stesse della
#     build (LibreELEC le applica con il fuzz di default e senza guardare
#     l'esito: una patch che entra male non ferma niente).
# Poi aggiorna integration/linux-rf35h.patch su un ramo ci-test/kernel-X,
# avvia la build di prova e apre un issue. Merge e release restano a mano.
# Con --dry-run fa tutte le verifiche e si ferma prima del ramo.
set -euo pipefail
O="$(cd "$(dirname "$0")/.." && pwd)"
P="${O}/integration/linux-rf35h.patch"
DRY=no
WANT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--dry-run) DRY=yes; shift ;;
		--version) WANT="${2:-}"; shift 2 ;;
		*) echo "uso: $0 [--dry-run] [--version X.Y.Z]" >&2; exit 2 ;;
	esac
done

say()  { printf '\n==> %s\n' "$*"; }
# un'annotazione nel run (si legge dall'API) e la stessa riga nel log
note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1 title=Kernel::$2"; fi; echo "$2"; }
die()  { note error "$*"; exit 1; }

cur="$(sed -n 's/^+ *PKG_VERSION="\([0-9][0-9.]*\)".*/\1/p' "${P}")"
[ -n "${cur}" ] || die "versione del kernel non trovata in ${P}"
br="${cur%.*}"
say "Kernel della build: ${cur} (ramo ${br})"

if [ -n "${WANT}" ]; then
	[[ "${WANT}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die "--version: ${WANT} non e' una versione"
	v="${WANT}"
else
	json="$(curl -fsSL --retry 3 https://www.kernel.org/releases.json)"
	v="$(jq -r --arg b "${br}." '[.releases[] | select(.version | startswith($b)) | .version][0] // empty' <<<"${json}")"
	eol="$(jq -r --arg b "${br}." '[.releases[] | select(.version | startswith($b)) | .iseol][0] // empty' <<<"${json}")"
	if [ -z "${v}" ]; then
		note warning "il ramo ${br} non e' piu' su kernel.org: va scelto un altro ramo (a mano)"
		exit 0
	fi
	if [ "${eol}" = true ]; then
		note warning "il ramo ${br} e' a fine vita (ultimo ${v}): va scelto un altro ramo (a mano)"
	fi
	if [ "${v}" = "${cur}" ]; then
		note notice "aggiornato: ${cur} e' l'ultimo ${br}.y"
		exit 0
	fi
	if [ "$(printf '%s\n%s\n' "${cur}" "${v}" | sort -V | tail -1)" != "${v}" ]; then
		note notice "kernel.org ha ${v}, la build usa ${cur}: niente da fare"
		exit 0
	fi
fi

nb="ci-test/kernel-${v}"
if [ "${DRY}" = no ] && git -C "${O}" ls-remote --exit-code --heads origin "refs/heads/${nb}" >/dev/null 2>&1; then
	note notice "${v} gia' proposto: c'e' il ramo ${nb}"
	exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
cd "${work}"

say "Scarico linux-${v} da kernel.org"
base="https://cdn.kernel.org/pub/linux/kernel/v${v%%.*}.x"
curl -fsSLO --retry 3 "${base}/linux-${v}.tar.xz"
curl -fsSLO --retry 3 "${base}/linux-${v}.tar.sign"
curl -fsSLO --retry 3 "${base}/sha256sums.asc"

say "Firma"
export GNUPGHOME="${work}/gnupg"
mkdir -m 700 "${GNUPGHOME}"
gpg --batch --quiet --auto-key-locate clear,wkd --locate-keys \
	torvalds@kernel.org gregkh@kernel.org sashal@kernel.org >/dev/null 2>&1 || true
st="$(xz -dc "linux-${v}.tar.xz" | gpg --batch --status-fd 1 --verify "linux-${v}.tar.sign" - 2>/dev/null || true)"
# VALIDSIG <impronta della chiave che ha firmato> ... <impronta della primaria>
signer=""
for f in $(sed -n 's/^\[GNUPG:\] VALIDSIG //p' <<<"${st}" | awk '{ print $1; print $NF }'); do
	case "${f}" in
		ABAF11C65A2970B130ABE3C479BE3E4300411886) signer="Linus Torvalds" ;;
		647F28654894E3BD457199BE38DBBDC86092693E) signer="Greg Kroah-Hartman" ;;
		E27E5D8A3403A2EF66873BBCDEA66FF797772CDC) signer="Sasha Levin" ;;
		AC2B29BD34A6AFDDB3F68F35E7BFC8EC95861109) signer="Ben Hutchings" ;;
	esac
done
[ -n "${signer}" ] || die "linux-${v}.tar: nessuna firma valida delle chiavi di kernel.org"
echo "  firma di ${signer}"

sha="$(sha256sum "linux-${v}.tar.xz" | cut -d' ' -f1)"
grep -qx "${sha}  linux-${v}.tar.xz" sha256sums.asc \
	|| die "SHA256 di linux-${v}.tar.xz diverso da quello di sha256sums.asc"
echo "  SHA256 ${sha} (uguale a sha256sums.asc)"

say "Patch del kernel a fuzz 0"
lk="$(sed -n 's/^LAKKA_COMMIT="\([0-9a-f]*\)".*/\1/p' "${O}/build-lakka-rf35h.sh")"
lr="$(sed -n 's/^LAKKA_REPO="\([^"]*\)".*/\1/p' "${O}/build-lakka-rf35h.sh")"
git init -q lakka
git -C lakka fetch -q --depth 1 "${lr}" "${lk}"
git -C lakka checkout -q FETCH_HEAD
RF35H_CORE_LTO=yes RF35H_RE3_PKG="" "${O}/apply.sh" "${work}/lakka" "${O}/board" > apply.log 2>&1 \
	|| { tail -20 apply.log; die "apply.sh fallito sull'albero Lakka pinnato"; }
tar -xf "linux-${v}.tar.xz"
n=0
for p in lakka/packages/linux/patches/default/*.patch lakka/projects/Rockchip/devices/RK3326/patches/linux/*.patch; do
	patch -d "linux-${v}" -p1 --fuzz=0 --no-backup-if-mismatch -s < "${p}" \
		|| die "$(basename "${p}") non applica a fuzz 0 su ${v}: va rigenerata (a mano)"
	n=$((n + 1))
	echo "  ok  $(basename "${p}")"
done

if [ "${DRY}" = yes ]; then
	note notice "linux-${v}: firma di ${signer}, SHA256 ${sha}, ${n} patch a fuzz 0 (prova: niente ramo, build ne' issue)"
	exit 0
fi

say "Ramo ${nb}"
cd "${O}"
git switch -q -c "${nb}"
sed -i \
	-e "s|^\(+ *PKG_VERSION=\"\)${cur}\"|\1${v}\"|" \
	-e "s|^\(+ *PKG_SHA256=\"\)[0-9a-f]*\"|\1${sha}\"|" \
	-e "s|^Provenienza: .*|Provenienza: linux-${v}.tar.xz, firma di ${signer} verificata (chiavi dal WKD di kernel.org), SHA256 uguale al sha256sums.asc; ${n} patch a fuzz 0 (upstream.yml, $(date -u +%d/%m/%Y)).|" \
	"${P}"
grep -q "PKG_VERSION=\"${v}\"" "${P}" && grep -q "PKG_SHA256=\"${sha}\"" "${P}" \
	|| die "integration/linux-rf35h.patch non aggiornata"
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
	commit -q -m "linux: ${v}" -m "Signed by ${signer} (kernel.org WKD keys), SHA256 matches sha256sums.asc, ${n} kernel patches apply at fuzz 0. Opened by upstream.yml." -- "${P}"
git push -q origin "${nb}"
# un push del GITHUB_TOKEN non avvia altri workflow: la build si chiede
gh workflow run build.yml --ref "${nb}"

repo="${GITHUB_REPOSITORY:-debianita22/lakka-rf35h}"
gh issue create --title "Kernel ${v} da provare" --body "$(cat <<EOF
Su kernel.org c'e' Linux ${v}; la build usa ${cur}.

Il ramo \`${nb}\` ha \`integration/linux-rf35h.patch\` aggiornata:
- firma di ${signer} verificata sul tarball (chiavi dal WKD di kernel.org, impronte di kernel.org/signature.html);
- SHA256 \`${sha}\`, uguale al \`sha256sums.asc\` di kernel.org;
- le ${n} patch del kernel applicano a fuzz 0.

La build di prova e' partita: https://github.com/${repo}/actions/workflows/build.yml

Se e' verde (e la console va): \`git fetch origin && git merge --ff-only origin/${nb} && git push\`, poi la release.
Se no: chiudere l'issue e cancellare il ramo.
EOF
)"
note notice "linux-${v}: ramo ${nb}, build di prova avviata, issue aperto"
