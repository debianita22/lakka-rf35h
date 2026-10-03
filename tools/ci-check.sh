#!/bin/bash
# ci-check.sh - i controlli veloci, gli stessi della CI (check.yml). Da lanciare
# anche a mano prima di un push: pochi secondi, nessuna rete.
#
#   ./tools/ci-check.sh
#
#   1. shellcheck (livello warning) su ogni script di shell del repository,
#      riconosciuto dalla prima riga: anche quelli senza .sh che finiscono
#      nell'immagine (packages/*/scripts/rf35h-*)
#   2. i workflow (actionlint, se c'e')
#   3. sintassi dei .py, senza scrivere __pycache__ (verify-claims e il build
#      script rifiutano i residui)
#   4. i conteggi @@ di ogni patch (tools/check-patch-hunks.py)
#   5. le prove: tools/test-*.sh
set -u
O="$(cd "$(dirname "$0")/.." && pwd)"
cd "${O}" || exit 1
fail=0
step() { printf '\n== %s\n' "$*"; }
bad()  { printf '  NO  %s\n' "$*"; fail=1; }

# i file del repository: quelli di git se c'e', altrimenti tutto tranne .git
files() {
	if git -C "${O}" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "${O}" ls-files
	else
		find . -path ./.git -prune -o -type f -print | sed 's|^\./||'
	fi
}

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
	sh_files=()
	while IFS= read -r f; do
		[ -f "${f}" ] || continue
		head -1 "${f}" 2>/dev/null | grep -qE '^#!(/usr/bin/env[[:space:]]+|/bin/)(ba)?sh([[:space:]]|$)' \
			&& sh_files+=("${f}")
	done < <(files)
	if shellcheck -S warning "${sh_files[@]}"; then
		echo "  ok  ${#sh_files[@]} script"
	else
		bad "shellcheck: vedi sopra"
	fi
else
	bad "shellcheck non installato (Debian/Ubuntu: apt install shellcheck)"
fi

step "workflow (actionlint)"
if command -v actionlint >/dev/null 2>&1; then
	if actionlint .github/workflows/*.yml; then echo "  ok"; else bad "actionlint: vedi sopra"; fi
else
	echo "  (actionlint non installato: salto. pip install actionlint-py)"
fi

step "sintassi Python"
py=0
while IFS= read -r f; do
	case "${f}" in *.py) ;; *) continue ;; esac
	py=$((py + 1))
	python3 -c 'import sys; compile(open(sys.argv[1]).read(), sys.argv[1], "exec")' "${f}" \
		|| bad "${f}"
done < <(files)
echo "  ${py} file controllati"

step "patch: conteggi @@"
mapfile -t patches < <(files | grep '\.patch$')
python3 tools/check-patch-hunks.py "${patches[@]}" || bad "conteggi @@ sbagliati"

for t in tools/test-*.sh; do
	step "${t}"
	bash "${t}" || bad "${t}"
done

echo
if [ "${fail}" = 0 ]; then
	echo "tutti i controlli passano"
else
	echo "qualche controllo NON passa (righe NO qui sopra)" >&2
fi
exit "${fail}"
