#!/bin/bash
# ci-apt.sh <pacchetto>... - apt-get install sul runner della CI, con un
# limite di tempo e tre tentativi.
#
# Di solito ci mette un minuto. Il 7/10/2026 la parte 1 della v1.3.1 e'
# rimasta tre ore nel passo "Spazio su disco" (apt-get o la pulizia del disco:
# il log di un job non si legge finche' non finisce), e il job sarebbe andato
# avanti fino al suo timeout di sei ore. Qui un tentativo dura al massimo
# CI_APT_TIMEOUT secondi (240), e il passo nel workflow ha il suo
# timeout-minutes.
set -uo pipefail
[ $# -gt 0 ] || { echo "uso: $0 pacchetto..." >&2; exit 2; }
t="${CI_APT_TIMEOUT:-240}"
pause="${CI_APT_SLEEP:-15}"
for i in 1 2 3; do
	# DPkg::Lock::Timeout: se apt e' occupato (un aggiornamento automatico del
	# runner) aspetta il lock invece di fallire subito
	if sudo timeout "${t}" apt-get -o DPkg::Lock::Timeout=60 update -qq &&
		sudo timeout "${t}" apt-get -o DPkg::Lock::Timeout=60 install -y -qq "$@" > /dev/null; then
		exit 0
	fi
	echo "::warning title=apt::tentativo ${i} di 3 fallito o scaduto (${*})"
	[ "${i}" -lt 3 ] && sleep "${pause}"
done
echo "::error title=apt::${*} non installati dopo 3 tentativi"
exit 1
