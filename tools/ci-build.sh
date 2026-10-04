#!/bin/bash
# ci-build.sh - i passi della build in CI (.github/workflows/build-stage.yml).
# Fuori dalla CI non serve: a mano si usa build-in-docker.sh.
#
#   ci-build.sh disk            libera spazio e sceglie il disco piu' grande (W)
#   ci-build.sh prepare         overlay in W, albero Lakka, verifiche (--dry-run)
#   ci-build.sh build           la build, fino alla scadenza del job
#   ci-build.sh pack N [failed] lo stato per la parte N+1 (W/state-N.tar.zst);
#                               "failed": quello di una build fallita
#   ci-build.sh unpack N        lo stato della parte N
#   ci-build.sh reset           dopo unpack da un altro run: albero pulito + build
#   ci-build.sh collect         immagine, .tar, update.txt, SHA256SUMS in W/dist
#   ci-build.sh logs N          i log della parte N (W/log-N.tar.zst)
#   ci-build.sh ccache-stats
#
# Perche' a parti: un job dei runner gratuiti dura al massimo 6 ore e la build
# da zero (toolchain, llvm per l'host, Mesa, kernel, 30 core) ne chiede di
# piu'. Ogni parte costruisce fino a BUILD_MINUTES dall'inizio del job; se non
# ha finito si ferma, e la successiva riparte dallo stato: LibreELEC salta i
# pacchetti gia' fatti (stamp), rifa' solo quelli interrotti.
#
# Variabili (le mette il workflow): GITHUB_WORKSPACE, GITHUB_ENV,
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, JOB_START, BUILD_MINUTES, W,
# RF35H_VERSION, RF35H_CONTAINER.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
TREE_NAME="lakka-rf35h-build"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
gb()   { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }
out()  { echo "$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
summ() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
# Un'annotazione del job: si legge anche dall'API (check-runs/annotations),
# senza scaricare il log. Le righe vanno codificate (%0A).
note() {
	local level="$1" title="$2" msg="$3"
	[ -n "${GITHUB_ACTIONS:-}" ] || return 0
	msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/}"; msg="${msg//$'\n'/'%0A'}"
	echo "::${level} title=${title}::${msg}"
}

cmd_disk() {
	say "Spazio prima"
	df -h / /mnt 2>/dev/null || df -h /
	# Cio' che sul runner c'e' e qui non serve (la build gira nel container):
	# SDK Android, Haskell, .NET, Swift, i toolcache delle actions, CodeQL.
	# In parallelo: sono decine di GB di file piccoli.
	say "Libero spazio"
	local d
	for d in /usr/local/lib/android /usr/local/.ghcup /opt/ghc /usr/share/dotnet \
	         /usr/share/swift /opt/hostedtoolcache /usr/local/share/powershell \
	         /usr/local/share/chromium /usr/local/lib/node_modules /opt/az \
	         /opt/microsoft /opt/google /usr/lib/jvm /usr/share/java; do
		[ -e "${d}" ] && sudo rm -rf "${d}" &
	done
	docker image prune -af >/dev/null 2>&1 &
	wait
	df -h / /mnt 2>/dev/null || df -h /

	# Il disco con piu' spazio. /mnt (se c'e') e' un disco a parte, ma la
	# build vuole una cartella sola: niente LVM, si sceglie.
	local root mnt=0
	root="$(gb /)"
	if mountpoint -q /mnt 2>/dev/null; then mnt="$(gb /mnt)"; fi
	if [ "${mnt}" -gt "${root}" ]; then
		W=/mnt/rf35h
		sudo mkdir -p "${W}"
		sudo chown "$(id -u):$(id -g)" "${W}"
	else
		W="${HOME}/rf35h"
		mkdir -p "${W}"
	fi
	echo "  cartella di lavoro: ${W} ($(gb "${W}") GB liberi; / ${root} GB, /mnt ${mnt} GB)"
	echo "W=${W}" >> "${GITHUB_ENV:-/dev/null}"
	summ "- disco: ${W}, $(gb "${W}") GB liberi"
	note notice "Disco" "${W}: $(gb "${W}") GB liberi (/ ${root} GB, /mnt ${mnt} GB), $(nproc) CPU, $(free -g | awk '/^Mem:/ {print $2}') GB RAM"
}

cmd_prepare() {
	: "${W:?}"
	say "Overlay e albero Lakka in ${W}"
	# lo stesso layout di chi costruisce a mano: lakka-rf35h/ (con .git: il
	# commit va in BUILDER_VERSION) accanto a lakka-rf35h-build/
	rm -rf "${W}/lakka-rf35h"
	cp -a "${GITHUB_WORKSPACE:-${O}}" "${W}/lakka-rf35h"
	cd "${W}"
	./lakka-rf35h/build-in-docker.sh --dry-run

	# lo script, se il commit pinnato non si scarica, resta sulla punta di
	# devel con un avviso: qui e' un errore
	local want have
	want="$(sed -n 's/^LAKKA_COMMIT="\([0-9a-f]*\)".*/\1/p' lakka-rf35h/build-lakka-rf35h.sh)"
	have="$(git -C "${TREE_NAME}" rev-parse HEAD)"
	if [ -z "${want}" ] || [ "${want}" != "${have}" ]; then
		die "Lakka a ${have}, non al commit pinnato ${want}"
	fi

	# ccache: 6 GB invece dei 10 di LibreELEC, per stare nella cache delle
	# actions (10 GB per repository). config/options legge questo file dopo
	# i suoi default.
	mkdir -p "${TREE_NAME}/.libreelec"
	echo 'CCACHE_CACHE_SIZE="6G"' > "${TREE_NAME}/.libreelec/options"
}

cmd_build() {
	: "${W:?}" "${JOB_START:?}" "${BUILD_MINUTES:?}" "${RF35H_CONTAINER:?}"
	cd "${W}"
	local deadline now budget rc result try=1
	deadline=$(( JOB_START + BUILD_MINUTES * 60 ))
	now="$(date +%s)"
	while : ; do
		budget=$(( deadline - $(date +%s) ))
		if [ "${budget}" -lt 1200 ]; then
			if [ "${try}" -gt 1 ]; then break; fi   # resta l'esito del primo
			echo "meno di 20 minuti per la build: passo lo stato alla parte successiva"
			out "result=continue"
			return 0
		fi
		say "Build (tentativo ${try}): $(( budget / 60 )) minuti a disposizione"
		# Nel log delle actions solo l'avanzamento (il log completo, centinaia
		# di MB, lo scrive build-lakka-rf35h.sh nell'albero e finisce negli
		# artifact).
		set +e
		timeout --signal=TERM --kill-after=30 "${budget}" \
			./lakka-rf35h/build-in-docker.sh --keep-going --jobs 4 --pkg-jobs 2 2>&1 \
			| grep --line-buffered -aE '^\[[0-9]+/[0-9]+\] \[(INIT|DONE|FAIL|ACTV|IDLE)|==>|\[!\]|\[x\]|FAILURE|ERROR|NON conforme|Conforme'
		rc=${PIPESTATUS[0]}
		set -e
		# Allo scadere timeout ferma il client docker, non la build: e' il PID
		# 1 del container e ignora il SIGTERM inoltrato. Lo si uccide da fuori,
		# e lo si toglie (--rm lo fa il daemon, dopo): il tentativo dopo
		# riusa il nome.
		docker kill "${RF35H_CONTAINER}" >/dev/null 2>&1 || true
		docker rm -f "${RF35H_CONTAINER}" >/dev/null 2>&1 || true
		case "${rc}" in
			0)       result="done" ;;
			124|137) result="continue" ;;
			*)       result="failed" ;;
		esac
		# Un fallimento si riprova una volta. git fetch (get_git) non riprova
		# da solo, e un errore di rete al primo minuto (run #5: glsl_shaders,
		# passo 8 di 340) buttava la build; uno vero si ripete in pochi
		# minuti, perche' il costruito resta (stamp) e si rifa' solo il
		# pacchetto fallito.
		if [ "${result}" = failed ] && [ "${try}" -eq 1 ]; then
			note warning "Tentativo 1 fallito, riprovo" "$(failure_report)"
			try=2
			continue
		fi
		break
	done
	echo "uscita ${rc}: ${result}"
	out "result=${result}"
	summ "- build: uscita ${rc} (${result}) dopo $(( ($(date +%s) - now) / 60 )) minuti, tentativi ${try}"
	note notice "Build" "uscita ${rc} (${result}) dopo $(( ($(date +%s) - now) / 60 )) minuti, tentativi ${try}; $(progress); disco: $(gb "${W}") GB liberi, albero $(du -sh "${W}/${TREE_NAME}" 2>/dev/null | cut -f1)"
	if [ "${result}" = failed ]; then
		note error "Build fallita" "$(failure_report)"
		exit "${rc}"
	fi
}

# il log completo dell'ultima build (build-rf35h-AAAAMMGG-hhmmss.log, non i
# *-fallito.log dei pacchetti)
mainlog() {
	ls -t "${W}/${TREE_NAME}"/build-rf35h-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].log 2>/dev/null | head -1
}

# Quanti passi del piano sono fatti, dal log dell'ultima build
progress() {
	local log
	log="$(mainlog)"
	[ -n "${log}" ] || { echo "nessun log"; return 0; }
	echo "passi fatti $(grep -ac '\] \[DONE\] ' "${log}" || true) su $(sed -n 's/.*Package steps *: *//p' "${log}" | tail -1), ultimo: $(grep -a '\] \[DONE\] ' "${log}" | tail -1 | sed 's/.*\[DONE\] *//' | tr -s ' ')"
}

# Il pacchetto fallito e le ultime righe del suo log (quello del thread, che
# --keep-going copia in *-fallito.log; se no la coda del log completo, dove
# si mescolano i log di tutti i pacchetti finiti prima). Oltre agli errori di
# compilazione quelli di rete: un "fatal:" di git non contiene "error".
failure_report() {
	local log pkg flog
	log="$(mainlog)"
	[ -n "${log}" ] || { echo "nessun log della build: e' fallita prima (vedi il passo)"; return 0; }
	pkg="$(sed -n 's|.*FAILURE: scripts/[a-z]* \([A-Za-z0-9_.+-]*\):[a-z]* has failed!.*|\1|p' "${log}" | tail -1)"
	flog="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-*-"${pkg:-nessuno}"-fallito.log 2>/dev/null | head -1)"
	echo "pacchetto: ${pkg:-?} (log: $(basename "${flog:-${log}}"))"
	grep -aE 'error|Error|FAILED|No such file|fatal:|Cannot get|curl: \(|unable to|Could not|Failed to|timed out|reset by peer' "${flog:-${log}}" \
		| grep -av 'Werror\|error\.o\|_error\.' | tail -10 | cut -c1-180
	echo "--- coda:"
	tail -20 "${flog:-${log}}" | cut -c1-180
}

cmd_pack() {
	local n="${1:?parte}" why="${2:-}" size
	: "${W:?}"
	cd "${W}"
	say "Stato della parte ${n}"
	du -sh "${TREE_NAME}" "${TREE_NAME}"/build.*/* "${TREE_NAME}"/build.*/.ccache* 2>/dev/null | sort -h | tail -12 || true
	# Fuori: i sorgenti (si riscaricano, e solo per i pacchetti ancora da
	# fare), i log e i resoconti (vanno negli artifact a parte), i file
	# temporanei dell'immagine, lo stato dei thread.
	tar -C "${W}" \
		--exclude="${TREE_NAME}/sources" \
		--exclude="${TREE_NAME}/target" \
		--exclude="${TREE_NAME}/build-rf35h-*" \
		--exclude="${TREE_NAME}/build.*/.threads" \
		--exclude="${TREE_NAME}/build.*/image" \
		-I 'zstd -T0 -3' -cf "${W}/state-${n}.tar.zst" "${TREE_NAME}"
	ls -la "${W}/state-${n}.tar.zst"
	size="$(du -h "${W}/state-${n}.tar.zst" | cut -f1)"
	if [ "${why}" = failed ]; then
		# l'ID da dare a "Run workflow" per ripartire da qui dopo la correzione
		summ "- stato della build fallita: ${size}; per riprenderla, Run workflow con resume_run ${GITHUB_RUN_ID:-}"
		note notice "Stato" "state-${n}.tar.zst ${size}: ripresa con resume_run=${GITHUB_RUN_ID:-} (3 giorni)"
	else
		summ "- stato per la parte $(( n + 1 )): ${size}"
		note notice "Stato" "state-${n}.tar.zst ${size}, albero $(du -sh "${W}/${TREE_NAME}" | cut -f1)"
	fi
}

cmd_unpack() {
	local n="${1:?parte}" f
	: "${W:?}"
	say "Riprendo lo stato della parte ${n}"
	# download-artifact salva un artifact non zip col nome che gli da' il
	# server (Content-Disposition), "artifact" se non ne da': si prende il
	# file che c'e' nella cartella del download.
	f="${W}/dl/state-${n}.tar.zst"
	[ -f "${f}" ] || f="$(find "${W}/dl" -maxdepth 1 -type f | head -1)"
	[ -n "${f}" ] && [ -f "${f}" ] || die "stato della parte ${n} non scaricato in ${W}/dl"
	tar -C "${W}" -I zstd -xf "${f}"
	rm -rf "${W}/dl"
	du -sh "${W}/${TREE_NAME}"
}

# I log della parte, compressi (quello completo di LibreELEC e' di centinaia
# di MB, ma e' testo): W/log-N.tar.zst
cmd_logs() {
	local n="${1:?parte}"
	: "${W:?}"
	cd "${W}/${TREE_NAME}" 2>/dev/null || return 0
	local f=()
	mapfile -t f < <(ls -d build-rf35h-* 2>/dev/null)
	[ "${#f[@]}" -gt 0 ] || { echo "nessun log"; return 0; }
	tar -I 'zstd -T0 -10' -cf "${W}/log-${n}.tar.zst" "${f[@]}"
	ls -la "${W}/log-${n}.tar.zst"
}

# Dopo un "unpack" da un altro run: l'albero torna a Lakka pulito, con i
# pacchetti costruiti (build.*), i sorgenti e i log; senza lo stamp
# dell'overlay "prepare" riapplica quello di questo commit, e la build rifa'
# solo i pacchetti i cui file sono cambiati. I comandi che il build script
# suggerisce dopo "overlay disallineato".
cmd_reset() {
	: "${W:?}"
	local t="${W}/${TREE_NAME}"
	[ -d "${t}/.git" ] || die "nessun albero da riportare in ${t}"
	say "Albero riportato a Lakka pulito, pacchetti costruiti tenuti"
	rm -f "${t}/.rf35h-applied"
	git -C "${t}" checkout -q -- .
	git -C "${t}" clean -qfd -e sources -e 'build.*' -e target -e '*.log' -e 'build-rf35h-*'
}

cmd_ccache_stats() {
	: "${W:?}"
	cd "${W}"
	# il ccache della toolchain, eseguito nel container (e' linkato li')
	local st
	st="$(./lakka-rf35h/build-in-docker.sh --sh \
		'for d in lakka-rf35h-build/build.*; do [ -x "$d/toolchain/bin/ccache" ] && "$d/toolchain/bin/ccache" -d "$d/.ccache" -s; done; true' \
		2>/dev/null | grep -v '^>>' || true)"
	echo "${st}"
	note notice "ccache" "$(echo "${st}" | grep -iE 'hits|misses|cache size' | tr -s ' ' | tr '\n' ';')"
}

cmd_collect() {
	: "${W:?}" "${RF35H_VERSION:?}"
	local t="${W}/${TREE_NAME}/target" dist="${W}/dist" img tarf sys
	[ -d "${t}" ] || die "manca ${t}: la build non ha prodotto immagini"
	img="$(find "${t}" -maxdepth 1 -name '*rf35h*.img.gz' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)"
	[ -n "${img}" ] || die "nessuna immagine in ${t}"
	tarf="${img%.img.gz}.tar"
	[ -f "${tarf}" ] || die "manca $(basename "${tarf}")"
	case "$(basename "${img}")" in
		*"-${RF35H_VERSION}-"*) ;;
		*) die "$(basename "${img}") non porta la versione ${RF35H_VERSION}" ;;
	esac

	# re3 (GTA III) non ha licenza: mai in un'immagine pubblica. La build non
	# lo ha (niente --re3), ma lo si guarda nel SYSTEM, non nelle opzioni.
	say "re3 assente dal SYSTEM"
	sys="$(tar -tf "${tarf}" | grep '/target/SYSTEM$' | head -1)"
	[ -n "${sys}" ] || die "SYSTEM non trovato in $(basename "${tarf}")"
	tar -xOf "${tarf}" "${sys}" > "${W}/SYSTEM.check"
	if unsquashfs -l "${W}/SYSTEM.check" | grep -qiE 're3_libretro|/re3([/.]|$)'; then
		rm -f "${W}/SYSTEM.check"
		die "re3 nel SYSTEM: questa immagine non si pubblica"
	fi
	unsquashfs -l "${W}/SYSTEM.check" | sed -n 's|.*usr/lib/libretro/\([^/]*\)_libretro\.so$|\1|p' | sort > "${W}/cores.txt"
	rm -f "${W}/SYSTEM.check"
	echo "  ok, $(wc -l < "${W}/cores.txt") core libretro nell'immagine"

	say "File della release in ${dist}"
	rm -rf "${dist}"; mkdir -p "${dist}"
	mv "${img}" "${tarf}" "${dist}/"
	cd "${dist}"
	local tb ts size
	tb="$(basename "${tarf}")"
	sha256sum -- *.img.gz *.tar > SHA256SUMS
	ts="$(sha256sum "${tb}" | cut -d' ' -f1)"
	size="$(stat -c%s "${tb}")"
	# Il file che le console leggono (rf35h-update): nome fisso, sempre
	# all'indirizzo .../releases/latest/download/update.txt
	{
		echo "version=${RF35H_VERSION}"
		echo "tar=${tb}"
		echo "url=https://github.com/${GITHUB_REPOSITORY:-debianita22/lakka-rf35h}/releases/download/${RF35H_VERSION}/${tb}"
		echo "sha256=${ts}"
		echo "size=${size}"
	} > update.txt
	# quello che la build ha lasciato fuori (--keep-going) e i core che ci sono
	cat "${W}/${TREE_NAME}"/build-rf35h-*-core-saltati.txt > dropped.txt 2>/dev/null || : > dropped.txt
	mv "${W}/cores.txt" cores.txt
	ls -la
	cat update.txt
	summ "- immagine: $(basename "${img}") ($(du -h "$(basename "${img}")" | cut -f1)), aggiornamento: ${tb} ($(du -h "${tb}" | cut -f1))"
	if [ -s dropped.txt ]; then summ "- core lasciati fuori: $(grep -oE '^  [a-z0-9_]+' dropped.txt | tr -d ' ' | tr '\n' ' ')"; fi
	note notice "Immagine" "$(basename "${img}") $(du -h "$(basename "${img}")" | cut -f1), ${tb} $(du -h "${tb}" | cut -f1), $(wc -l < cores.txt) core; fuori: $(grep -oE '^  [a-z0-9_]+' dropped.txt | tr -d ' ' | tr '\n' ' ')"
}

case "${1:-}" in
	disk)         cmd_disk ;;
	prepare)      cmd_prepare ;;
	build)        cmd_build ;;
	pack)         cmd_pack "${2:-}" "${3:-}" ;;
	unpack)       cmd_unpack "${2:-}" ;;
	reset)        cmd_reset ;;
	collect)      cmd_collect ;;
	logs)         cmd_logs "${2:-}" ;;
	ccache-stats) cmd_ccache_stats ;;
	*) sed -n '2,15p' "$0" >&2; exit 2 ;;
esac
