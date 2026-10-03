#!/bin/bash
# ci-release-notes.sh <dist> - le note di una release (build.yml), in inglese
# come il README. Legge update.txt e dropped.txt che tools/ci-build.sh
# collect ha messo in <dist>.
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
\`/storage/.update/\` (ssh, or the card's second partition on a PC) and
restart.

**First install** (replace \`sdX\`): \`zcat ${img} | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress\`,
or \`flash-sd.sh\` from the repository.
EOF

# i giochi che ci sono davvero (cores.txt: i core nel SYSTEM)
games=""
has() { grep -qx "$1" "${D}/cores.txt" 2>/dev/null; }
if has gtasa; then games="${games}, GTA: San Andreas (your own APK and OBB)"; fi
if has openxeenng; then games="${games}, OpenXeenNG (your GOG archives)"; fi
if has deva_adventures; then games="${games}, Deva's Awesome Adventures"; fi
echo
if [ -n "${games}" ]; then
	echo "Games, in *Contentless Cores*, none with game data: ${games#, }."
fi
cat <<'EOF'
GTA III (re3) is never in a release: its source has no license. On a console
that has it from a personal build, System Update first copies it to
`/storage`, so it survives the update.
EOF
if [ -s "${D}/cores.txt" ]; then
	echo
	echo "RetroArch cores ($(wc -l < "${D}/cores.txt")): $(tr '\n' ' ' < "${D}/cores.txt" | sed 's/ $//; s/ /, /g')."
fi

if [ -s "${D}/dropped.txt" ]; then
	echo
	echo "Left out because they did not build:"
	grep -oE '^  [A-Za-z0-9_.+-]+' "${D}/dropped.txt" | sed 's/^ */- /'
fi

cat <<EOF

Built by GitHub Actions from [\`${sha:0:12}\`](https://github.com/${repo}/commit/${sha})
on Lakka-LibreELEC \`${lakka:0:12}\` (devel). Checksums: \`SHA256SUMS\`.
EOF
