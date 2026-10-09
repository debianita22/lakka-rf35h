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
# Le dipendenze di un core (le righe "+<pacchetto>" sotto di lui) vanno con
# lui: si aggiornano quando si aggiorna il core, e se una e' cambiata il core
# e' fra i cambiati anche con lo stesso commit. In coda alla sua riga, le
# dipendenze cambiate: "easyrpg <vecchio> <nuovo> +liblcf <vecchio> <nuovo>".
# A --cores si da' il nome del core.
# Un repository che non risponde non ferma gli altri: avviso, e il core resta
# com'era, con le sue dipendenze (il gruppo si sposta tutto o niente).
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

# Il gruppo in corso, cioe' un core da aggiornare e le sue dipendenze: le righe
# come sono (gold) e coi commit nuovi (gnew), la riga per stdout del core
# (gline) e delle dipendenze cambiate (gdeps). Si scrive quando il gruppo
# finisce (una riga che non e' una dipendenza, o la fine del file): coi commit
# nuovi se tutti i repository hanno risposto, se no com'era.
g=""; gold=""; gnew=""; gok=yes; gline=""; gchg=no; gdeps=""
changed=0
flush() {
	[ -n "${g}" ] || return 0
	if [ "${gok}" = yes ]; then
		printf '%s' "${gnew}" >> "${tmp}"
		if [ "${gchg}" = yes ] || [ -n "${gdeps}" ]; then
			echo "${gline}${gdeps}"
			changed=$((changed + 1))
		fi
	else
		printf '%s' "${gold}" >> "${tmp}"
	fi
	g=""; gold=""; gnew=""; gok=yes; gline=""; gchg=no; gdeps=""
}

while IFS= read -r line || [ -n "${line}" ]; do
	case "${line}" in
		''|'#'*) flush; printf '%s\n' "${line}" >> "${tmp}"; continue ;;
	esac
	read -r c site sha br _ <<< "${line}"
	case "${c}" in
		# la dipendenza di un core che non si aggiorna resta com'e'
		+*) if [ -z "${g}" ]; then printf '%s\n' "${line}" >> "${tmp}"; continue; fi ;;
		*)  flush
			if ! wanted "${c}"; then printf '%s\n' "${line}" >> "${tmp}"; continue; fi
			g="${c}" ;;
	esac
	gold="${gold}${line}"$'\n'
	[ "${gok}" = yes ] || continue
	if [ "${br}" = - ]; then ref=HEAD; else ref="refs/heads/${br}"; fi
	new="$(git ls-remote "${site}" "${ref}" 2>/dev/null | awk 'NR == 1 { print $1 }' || true)"
	if [ -z "${new}" ]; then
		echo "cores-bump: ${c}: ${site} non risponde o ${ref} non esiste: resta ${sha:0:7}$([ "${c}" = "${g}" ] || echo ", e ${g} con lei")" >&2
		gok=no
		continue
	fi
	if [ "${c}" = "${g}" ]; then
		gline="${c} ${sha} ${new}"
		[ "${new}" = "${sha}" ] || gchg=yes
	elif [ "${new}" != "${sha}" ]; then
		gdeps="${gdeps} ${c} ${sha} ${new}"
	fi
	gnew="${gnew}$(printf '%-20s %-56s %s %s' "${c}" "${site}" "${new}" "${br}")"$'\n'
done < "${P}"
flush
if [ -n "${OUT}" ]; then
	cp "${tmp}" "${OUT}"
fi
echo "cores-bump: ${changed} core cambiati" >&2
