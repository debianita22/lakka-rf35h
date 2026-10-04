#!/bin/bash
# upstream-lakka.sh - Lakka-LibreELEC devel si e' mosso dal commit pinnato?
#
#   upstream-lakka.sh [--dry-run]
#
# Lo lancia .github/workflows/upstream.yml ogni settimana. Solo un avviso: un
# issue "Lakka devel: N commit dopo il pin", aggiornato a ogni giro e chiuso
# quando devel torna al commit pinnato. Il pin si sposta a mano: le patch
# d'integrazione (integration/) sono scritte contro quel commit e vanno
# riviste, e un ramo automatico fallirebbe al dry run quasi sempre.
# Con --dry-run scrive soltanto cosa farebbe.
set -euo pipefail
O="$(cd "$(dirname "$0")/.." && pwd)"
DRY=no
[ "${1:-}" = "--dry-run" ] && DRY=yes

note() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::$1 title=Lakka::$2"; fi; echo "$2"; }
die()  { note error "$*"; exit 1; }

pin="$(sed -n 's/^LAKKA_COMMIT="\([0-9a-f]*\)".*/\1/p' "${O}/build-lakka-rf35h.sh")"
url="$(sed -n 's/^LAKKA_REPO="\([^"]*\)".*/\1/p' "${O}/build-lakka-rf35h.sh")"
slug="${url#https://github.com/}"
slug="${slug%.git}"
[ -n "${pin}" ] && [ -n "${slug}" ] || die "LAKKA_COMMIT o LAKKA_REPO non trovati in build-lakka-rf35h.sh"
head="$(git ls-remote "${url}" refs/heads/devel | cut -f1)"
[ -n "${head}" ] || die "devel non trovato in ${url}"

# l'issue aperto di un giro precedente, se c'e'
num="$(gh issue list --state open --search 'Lakka devel in:title' --json number,title \
	--jq '[.[] | select(.title | startswith("Lakka devel:"))][0].number // empty')"

if [ "${head}" = "${pin}" ]; then
	note notice "Lakka devel e' al commit pinnato (${pin:0:12})"
	if [ -n "${num}" ] && [ "${DRY}" = no ]; then
		gh issue close "${num}" --comment "devel e' di nuovo al commit pinnato (${pin:0:12})."
	fi
	exit 0
fi

ahead="$(gh api "repos/${slug}/compare/${pin}...${head}" --jq .ahead_by)"
when="$(gh api "repos/${slug}/commits/${head}" --jq .commit.committer.date)"
last="$(gh api "repos/${slug}/compare/${pin}...${head}" \
	--jq '.commits[-15:] | reverse | .[] | "- `\(.sha[0:12])` \(.commit.message | split("\n")[0])"')"
title="Lakka devel: ${ahead} commit dopo il pin"
body="$(cat <<EOF
Lakka-LibreELEC \`devel\` e' a \`${head:0:12}\` (${when}), ${ahead} commit dopo quello pinnato in \`build-lakka-rf35h.sh\` (\`${pin:0:12}\`).

Gli ultimi:
${last}

Per spostare il pin (a mano: le patch in \`integration/\` sono scritte contro quel commit):
1. \`LAKKA_COMMIT\` in \`build-lakka-rf35h.sh\`;
2. un dry run (\`./build-in-docker.sh --dry-run\`): ogni patch deve applicare a fuzz 0;
3. push su un ramo \`ci-test/...\` per la build di prova; se e' verde, merge e release.

Questo issue lo aggiorna e lo chiude \`upstream.yml\`.
EOF
)"

if [ "${DRY}" = yes ]; then
	note notice "${title} (prova: issue ${num:-nuovo} non toccato)"
	printf '%s\n' "${body}"
	exit 0
fi
if [ -n "${num}" ]; then
	gh issue edit "${num}" --title "${title}" --body "${body}"
	note notice "${title}: issue #${num} aggiornato"
else
	gh issue create --title "${title}" --body "${body}"
	note notice "${title}: issue aperto"
fi
