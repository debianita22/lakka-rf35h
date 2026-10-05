#!/bin/bash
# cores-bump.sh - i core di cores/pins.txt alla punta del loro ramo upstream
#
#   cores-bump.sh [--cores "a b"] [--write] [--out FILE]
#
# Per ogni core (tutti quelli di pins.txt, o solo --cores) chiede al repository
# la punta del ramo del pin ("-": HEAD del repository) con git ls-remote e
# scrive il pin nuovo: in --out FILE (default: stdout non c'e', si stampa solo
# l'elenco), o in cores/pins.txt stesso con --write. Stampa su stdout i core
# cambiati, uno per riga: "<core> <vecchio> <nuovo>". Lo usa cores.yml; a mano
# serve a vedere quanto e' indietro l'immagine.
# Un repository che non risponde non ferma gli altri: avviso, e il core resta.
set -euo pipefail
O="$(cd "$(dirname "$0")/.." && pwd)"
P="${O}/cores/pins.txt"
ONLY=""
WRITE=no
OUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--cores) ONLY="${2:-}"; shift 2 ;;
		--write) WRITE=yes; shift ;;
		--out)   OUT="${2:-}"; shift 2 ;;
		*) echo "uso: $0 [--cores \"a b\"] [--write] [--out FILE]" >&2; exit 2 ;;
	esac
done
[ "${WRITE}" = yes ] && OUT="${P}"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

wanted() { [ -z "${ONLY}" ] || case " ${ONLY} " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

changed=0
while IFS= read -r line; do
	case "${line}" in
		''|'#'*) printf '%s\n' "${line}" >> "${tmp}"; continue ;;
	esac
	read -r c site sha br _ <<< "${line}"
	if ! wanted "${c}"; then printf '%s\n' "${line}" >> "${tmp}"; continue; fi
	if [ "${br}" = - ]; then ref=HEAD; else ref="refs/heads/${br}"; fi
	new="$(git ls-remote "${site}" "${ref}" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
	if [ -z "${new}" ]; then
		echo "cores-bump: ${c}: ${site} non risponde o ${ref} non esiste: resta ${sha:0:7}" >&2
		printf '%s\n' "${line}" >> "${tmp}"
		continue
	fi
	if [ "${new}" != "${sha}" ]; then
		echo "${c} ${sha} ${new}"
		changed=$((changed + 1))
	fi
	printf '%-17s %-52s %s %s\n' "${c}" "${site}" "${new}" "${br}" >> "${tmp}"
done < "${P}"
if [ -n "${OUT}" ]; then
	cp "${tmp}" "${OUT}"
fi
echo "cores-bump: ${changed} core cambiati" >&2
