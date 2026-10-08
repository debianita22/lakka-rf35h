#!/bin/bash
# ci-release-notes.sh <dist> - le note di una release (build.yml), in inglese
# come il README. Legge update.txt, cores.txt e dropped.txt che tools/ci-build.sh
# collect ha messo in <dist>, e missing.txt di check-dist.
set -euo pipefail
D="${1:?uso: ci-release-notes.sh <cartella con update.txt>}"
O="$(cd "$(dirname "$0")/.." && pwd)"

val() { sed -n "s/^$1=//p" "${D}/update.txt"; }
v="$(val version)"
tarf="$(val tar)"
img="$(cd "${D}" && ls -- *.img.gz | head -1)"
lakka="$(sed -n 's/^LAKKA_COMMIT="\([0-9a-f]*\)".*/\1/p' "${O}/build-lakka-rf35h.sh")"
repo="${GITHUB_REPOSITORY:-debianita22/lakka-rf35h}"
# il commit della build (con publish_from non e' quello di questo run)
sha="${RF35H_BUILD_SHA:-${GITHUB_SHA:-$(git -C "${O}" rev-parse HEAD 2>/dev/null || echo unknown)}}"

echo "Lakka for the XiFan RF35H, ${v}."
# Le novita' di questa versione, scritte a mano (docs/release-notes/<versione>.md),
# se ci sono, in cima: l'elenco dei commit piu' sotto e' completo ma tecnico.
if [ -f "${O}/docs/release-notes/${v}.md" ]; then
	echo
	cat "${O}/docs/release-notes/${v}.md"
fi

cat <<EOF

| File | Use |
|---|---|
| \`${img}\` | first install: write it to an SD card (everything on the card is replaced) |
| \`${tarf}\` | update: ROMs, saves and settings stay |
| \`update.txt\` | what the consoles read to update themselves |

**Update from the console**: *Settings > Device Settings > System Update*
downloads this release, checks its SHA-256 and asks to restart; the update
is applied while the console starts. Or copy the \`.tar\` to
\`/storage/.update/\` over SSH (with the charger connected) and restart.

**First install** (replace \`sdX\`): \`zcat ${img} | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress\`,
or \`flash-sd.sh\` from the repository.
EOF

# Lo spazio che System Update chiede in /storage (rf35h-update): il .tar, che
# l'init estrae accanto a se' prima di installarlo, quindi due volte la sua
# dimensione piu' 100 MB. Dalla v1.3.0 (162 core) il .tar passa il GB.
size="$(val size)"
case "${size}" in
	''|*[!0-9]*) ;;
	*)
		size_mb=$(( size / 1048576 ))
		echo
		echo "**Free space**: the update is ${size_mb} MB; System Update needs about $(( 2 * size_mb + 100 )) MB"
		echo "free in \`/storage\` (the console unpacks the \`.tar\` next to itself before installing it)."
		;;
esac

# gli extra che ci sono davvero (cores.txt: i core nel SYSTEM). Non tutti
# stanno in Contentless Cores (OpenXeenNG no, col filtro di default): come si
# avviano lo dice la guida.
extras=""
has() { grep -qx "$1" "${D}/cores.txt" 2>/dev/null; }
if has ikemen; then extras="${extras}, IKEMEN GO"; fi
if has gtasa; then extras="${extras}, GTA: San Andreas (from your own APK and OBB)"; fi
if has openxeenng; then extras="${extras}, OpenXeenNG (Might and Magic IV/V, with the data files of your copy)"; fi
if has deva_adventures; then extras="${extras}, Deva's Awesome Adventures"; fi
if [ -n "${extras}" ]; then
	echo
	echo "Bundled extras, none with commercial game data: ${extras#, }."
	echo "How to start them: [guide](https://github.com/${repo}/blob/main/docs/guide.md#bundled-extras)."
fi
if [ -s "${D}/cores.txt" ]; then
	echo
	echo "RetroArch cores ($(wc -l < "${D}/cores.txt")): $(tr '\n' ' ' < "${D}/cores.txt" | sed 's/ $//; s/ /, /g')."
fi

# I cambi dall'ultima release stabile: vX.Y.Z senza trattino, pubblicata e
# non pre-release, antenata di questo commit; i soggetti dei commit, in
# inglese. Il tag da solo non basta: una vX.Y.Z costruita come pre-release e
# non ancora promossa non e' arrivata a nessuna console. Nel job release
# (GH_TOKEN) lo si chiede a GitHub; altrove (prove, a mano) l'ultimo tag senza
# trattino. Serve la storia con i tag (build.yml: checkout con fetch-depth 0);
# il tag di questa release ancora non c'e'.
prev=""
prev_rel=no
if [ -n "${GH_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
	for t in $(gh api "repos/${repo}/releases?per_page=100" \
			--jq '.[] | select((.draft or .prerelease) | not) | .tag_name' 2>/dev/null); do
		case "${t}" in *-*|"${v}") continue ;; v[0-9]*.[0-9]*.[0-9]*) ;; *) continue ;; esac
		if git -C "${O}" merge-base --is-ancestor "${t}" "${sha}" 2>/dev/null; then
			prev="${t}"
			prev_rel=yes
			break
		fi
	done
fi
if [ -z "${prev}" ]; then
	prev="$(git -C "${O}" describe --tags --abbrev=0 --match 'v*' --exclude '*-*' "${sha}^" 2>/dev/null || true)"
fi
if [ -n "${prev}" ]; then
	echo
	echo "Changes since ${prev}:"
	git -C "${O}" log --no-merges --format='- %s' "${prev}..${sha}" | sed 's/ \[skip ci\]$//'
	# quelle di prima, per chi aggiorna da una release piu' vecchia (solo se
	# prev e' una release vera: il link non va a vuoto)
	if [ "${prev_rel}" = yes ]; then
		echo
		echo "Earlier changes: [${prev} release notes](https://github.com/${repo}/releases/tag/${prev})."
	fi
fi

# I core portati a un commit upstream piu' nuovo da questa versione: i pin di
# cores/pins.txt (cores.yml li sposta quando il core compila) rispetto alla
# release precedente. Se allora pins.txt non c'era (fino alla v1.3.1), per
# ogni core la prima versione in cui compare nel file, cioe' il commit del
# Lakka pinnato, che e' quello che quella release aveva.
if [ -n "${prev}" ] && git -C "${O}" cat-file -e "${sha}:cores/pins.txt" 2>/dev/null; then
	pins_tmp="$(mktemp -d)"
	pins_of() { git -C "${O}" show "$1:cores/pins.txt" | awk '$2 ~ /^https?:/ { print $1, $3 }'; }
	if git -C "${O}" cat-file -e "${prev}:cores/pins.txt" 2>/dev/null; then
		pins_of "${prev}" > "${pins_tmp}/base"
	else
		for c in $(git -C "${O}" log --reverse --format=%H "${sha}" -- cores/pins.txt); do
			pins_of "${c}"
		done | awk '!($1 in seen) { seen[$1] = 1; print }' > "${pins_tmp}/base"
	fi
	pins_of "${sha}" > "${pins_tmp}/now"
	upd="$(awk 'FILENAME == ARGV[1] { b[$1] = $2; next } ($1 in b) && b[$1] != $2 { print $1 }' "${pins_tmp}/base" "${pins_tmp}/now")"
	rm -rf "${pins_tmp}"
	if [ -n "${upd}" ]; then
		echo
		echo "**Cores updated** to a newer upstream commit since ${prev} ($(wc -l <<< "${upd}")): $(tr '\n' ' ' <<< "${upd}" | sed 's/ $//; s/ /, /g')."
		echo "Each core is at the newest commit of its upstream that compiles here (\`cores/pins.txt\`)."
	fi
fi
# Il menu della v1.0.0 e della v1.1.0-rc1, durante il download, scrive
# "interrupted": il controllo "sta girando?" seguiva il link invocation:<unit>
# di systemd, che punta a un percorso che non esiste (corretto da eaaa503,
# v1.1.0). Chi aggiorna da li' lo vede con qualunque release: lo dicono tutte,
# finche' qualcuno puo' essere ancora su quelle due.
echo
echo "**Updating from v1.0.0 or v1.1.0-rc1**: while the update downloads, System Update"
echo "on those versions shows *interrupted: select to resume* instead of the progress."
echo "It is a display bug of those versions, fixed since v1.1.0: the download goes on"
echo "(selecting the entry again does no harm) and, when it is done, the entry says"
echo "*ready: ${v}, select to restart and install*."

if [ -s "${D}/dropped.txt" ]; then
	echo
	echo "Left out because they did not build:"
	grep -oE '^  [A-Za-z0-9_.+-]+' "${D}/dropped.txt" | sed 's/^ */- /'
fi
# pubblicata incompleta apposta (allow_incomplete): cosa manca rispetto al
# set di sempre
if [ -s "${D}/missing.txt" ]; then
	echo
	echo "Missing compared with a complete build: $(sed 's/ .*//' "${D}/missing.txt" | tr '\n' ' ' | sed 's/ $//; s/ /, /g')."
fi

cat <<EOF

Built by GitHub Actions from [\`${sha:0:12}\`](https://github.com/${repo}/commit/${sha})
on Lakka-LibreELEC \`${lakka:0:12}\` (devel). Checksums: \`SHA256SUMS\`.
EOF
