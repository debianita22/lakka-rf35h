
# --- rf35h: cores/pre-patch.sh, aggiunto da apply.sh -------------------------
# Le patch di Lakka di questo core non le applica scripts/unpack: apply.sh le
# ha spostate in patches-lakka/, e pre_patch le applica qui una per una, nello
# stesso ordine. Per ognuna, la prima regola che vale:
#   1. si applica: come prima (patch -p1, o git apply per le binarie e i
#      rename, come scripts/unpack);
#   2. e' gia' tutta nel sorgente (entrata upstream: si applica al contrario,
#      con lo stesso fuzz con cui patch l'applicherebbe, perche' intorno
#      l'upstream ha spesso cambiato qualche riga): si salta;
#   3. c'e' la versione aggiornata con lo stesso nome in patches-rf35h/
#      (cores/patches/<core>/ dell'overlay): quella, con le stesse regole; se
#      e' solo testo, senza hunk, la patch e' superata e si salta (il testo
#      dice perche');
#   4. file per file (una patch "buildfix" di Lakka tocca spesso piu' file, e
#      l'upstream ne sistema uno alla volta): ogni file si applica o e' gia'
#      nel sorgente;
#   5. altrimenti errore, con le righe di patch che dicono dove: il core non
#      compila e cores.yml lo lascia al commit di prima.
rf35h_patch_git() { grep -qE '^GIT binary patch$|^rename from|^rename to' "$1"; }
rf35h_patch_state() {
	if rf35h_patch_git "$1"; then
		if git apply --check --directory="${PKG_BUILD}" -p1 --unsafe-paths < "$1" 2> /dev/null; then echo applica
		elif git apply --check -R --directory="${PKG_BUILD}" -p1 --unsafe-paths < "$1" 2> /dev/null; then echo presente
		else echo no; fi
	elif patch -d "${PKG_BUILD}" -p1 --dry-run -f -s < "$1" > /dev/null 2>&1; then echo applica
	elif patch -d "${PKG_BUILD}" -p1 -R --dry-run -f -s < "$1" > /dev/null 2>&1; then echo presente
	else echo no; fi
}
# $1 la patch da applicare, $2 (se c'e') il nome da scrivere nel log
rf35h_patch_apply() {
	echo "rf35h: APPLY PATCH ${2:-${1#"${ROOT}"/}}"
	if rf35h_patch_git "$1"; then
		git apply --directory="${PKG_BUILD}" -p1 --verbose --whitespace=nowarn --unsafe-paths < "$1"
	else
		patch -d "${PKG_BUILD}" -p1 < "$1"
	fi
}
# Una patch unificata in un file per ogni file che tocca (<dir>/NNN.patch):
# una sezione comincia a "diff --git" o, in un diff senza intestazione git, a
# "--- "; dentro un hunk si contano le righe dell'intestazione @@, cosi' una
# riga tolta che comincia con "-- " non apre una sezione nuova.
rf35h_patch_split() {
	awk -v dir="$2" '
		function part() { n++; f = sprintf("%s/%03d.patch", dir, n) }
		h > 0 || k > 0 {
			print > f
			c = substr($0, 1, 1)
			if (c == "-") h--; else if (c == "+") k--; else if (c != "\\") { h--; k-- }
			next
		}
		/^diff --git / { part(); g = 1; print > f; next }
		/^--- / { if (!g) part(); g = 0; print > f; next }
		/^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/ {
			split($2, a, ","); split($3, b, ",")
			h = (2 in a) ? a[2] + 0 : 1; k = (2 in b) ? b[2] + 0 : 1
			print > f; next
		}
		f != "" { print > f }
	' "$1"
}
rf35h_patch_files() {
	local p="$1" d s n=0
	d="$(mktemp -d)"
	rf35h_patch_split "${p}" "${d}"
	for s in "${d}"/*.patch; do
		[ -f "${s}" ] || continue
		case "$(rf35h_patch_state "${s}")" in
			applica|presente) n=$((n + 1)) ;;
			*) rm -rf "${d}"; return 1 ;;
		esac
	done
	[ "${n}" -ge 2 ] || { rm -rf "${d}"; return 1; }
	echo "rf35h: ${p##*/}: file per file (${n} file)"
	for s in "${d}"/*.patch; do
		case "$(rf35h_patch_state "${s}")" in
			applica) rf35h_patch_apply "${s}" "${p#"${ROOT}"/} ($(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "${s}" | head -1))" || { rm -rf "${d}"; return 1; } ;;
			presente) echo "rf35h: ${p##*/} ($(sed -n 's|^+++ b/\([^[:space:]]*\).*|\1|p' "${s}" | head -1)): gia' nel sorgente, saltato" ;;
			*) rm -rf "${d}"; return 1 ;;
		esac
	done
	rm -rf "${d}"
}
rf35h_patch_one() {
	local p="$1" alt="${PKG_DIR}/patches-rf35h/${1##*/}"
	case "$(rf35h_patch_state "${p}")" in
		applica) rf35h_patch_apply "${p}"; return ;;
		presente) echo "rf35h: ${p#"${ROOT}"/} e' gia' nel sorgente (upstream): saltata"; return 0 ;;
	esac
	if [ "${p}" != "${alt}" ] && [ -f "${alt}" ]; then
		# solo testo, nessun hunk: la patch e' superata ai commit nuovi
		if ! grep -q '^@@ ' "${alt}" && ! rf35h_patch_git "${alt}"; then
			echo "rf35h: ${p##*/} non si applica piu' ed e' superata (cores/patches/${PKG_NAME}/): $(grep -m1 . "${alt}")"
			return 0
		fi
		echo "rf35h: ${p##*/} non si applica piu': la versione di cores/patches/${PKG_NAME}/"
		rf35h_patch_one "${alt}"
		return
	fi
	if ! rf35h_patch_git "${p}" && rf35h_patch_files "${p}"; then
		return 0
	fi
	if [ "${p}" = "${alt}" ]; then
		echo "rf35h: ${p##*/} FAILED: non si applica, nemmeno la versione di cores/patches/${PKG_NAME}/, e non e' gia' nel sorgente" >&2
	else
		echo "rf35h: ${p##*/} FAILED: non si applica e non e' gia' nel sorgente (nessuna versione in cores/patches/${PKG_NAME}/)" >&2
	fi
	patch -d "${PKG_BUILD}" -p1 --dry-run -f < "${p}" >&2 || true
	return 1
}
pre_patch() {
	local p
	for p in "${PKG_DIR}"/patches-lakka/*.patch; do
		[ -f "${p}" ] || continue
		rf35h_patch_one "${p}" || return 1
	done
}
