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
sha="${GITHUB_SHA:-$(git -C "${O}" rev-parse HEAD 2>/dev/null || echo unknown)}"

cat <<EOF
Lakka for the XiFan RF35H, ${v}.

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

# I cambi dall'ultima release vera (le pre-release, con il trattino, no): i
# soggetti dei commit, in inglese. Serve la storia con i tag (build.yml:
# checkout con fetch-depth 0); il tag di questa release ancora non c'e'.
prev="$(git -C "${O}" describe --tags --abbrev=0 --match 'v*' --exclude '*-*' "${sha}^" 2>/dev/null || true)"
if [ -n "${prev}" ]; then
	echo
	echo "Changes since ${prev}:"
	git -C "${O}" log --no-merges --format='- %s' "${prev}..${sha}"
fi

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
