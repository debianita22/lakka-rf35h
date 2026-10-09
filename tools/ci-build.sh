#!/bin/bash
# ci-build.sh - i passi della build e della release in CI
# (.github/workflows/build-stage.yml e build.yml). Fuori dalla CI non serve: a
# mano si usa build-in-docker.sh.
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
#   ci-build.sh check-dist D    job release: i file scaricati in D (re3, core
#                               rotti, core e giochi che mancano)
#   ci-build.sh version         job setup: versione, release o prova, pre-release
#   ci-build.sh publish D       job release: la release dai file in D, "latest"
#                               solo se e' la versione piu' alta
#   ci-build.sh pack-sysroot    a build finita: l'albero costruito senza sorgenti,
#                               kernel e ccache (W/sysroot-<versione>.tar.zst),
#                               per compilare i soli core (cores.yml)
#   ci-build.sh cores-matrix "a b"  job cores: i core divisi fra i job paralleli
#                               (JSON per strategy.matrix), i pesanti da soli
#   ci-build.sh cores "a b"     prova a compilare i core dati, ai pin nuovi,
#                               sull'albero ripreso dal sysroot (W/cores)
#   ci-build.sh merge-cores P D "a b"  job cores: i risultati dei job (P/*) in D;
#                               un core senza risultato va fra i falliti
#   ci-build.sh pins-merge D NP job cores: i pin nuovi (NP) dei core riusciti
#                               in cores/pins.txt, commit e push
#   ci-build.sh issue-merge OLD F "a b"  job cores: l'elenco dei falliti per
#                               l'issue, dal vecchio (OLD) e da questa corsa
#   ci-build.sh coretest R RA D core.so...  ogni core si apre come in RetroArch?
#                               (rf35h-coretest sotto qemu, con le librerie
#                               della radice R e quelle del RetroArch RA); in D
#                               il risultato (anche cores e check-dist lo usano)
#
# Perche' a parti: un job dei runner gratuiti dura al massimo 6 ore e la build
# da zero (toolchain, llvm per l'host, Mesa, kernel, 162 core) ne chiede di
# piu'. Ogni parte costruisce fino a BUILD_MINUTES dall'inizio del job; se non
# ha finito si ferma, e la successiva riparte dallo stato: LibreELEC salta i
# pacchetti gia' fatti (stamp); quelli interrotti si rifanno da capo
# (drop_interrupted).
#
# Variabili (le mette il workflow): GITHUB_WORKSPACE, GITHUB_ENV,
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, JOB_START, BUILD_MINUTES, W,
# RF35H_VERSION, RF35H_CONTAINER; per check-dist RF35H_ALLOW_INCOMPLETE; per
# version e publish quelle scritte prima di cmd_version.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
TREE_NAME="lakka-rf35h-build"
# Le opzioni della build in CI. --keep-going lascia fuori un core o un gioco che
# non compila (anche per un errore di rete) e fa l'immagine senza: il job
# release poi la ferma (check-dist), se non si e' chiesto allow_incomplete.
# Quello che check-dist pretende: i core di CORES_DEFAULT (build-lakka-rf35h.sh)
# e i giochi accesi qui (extras_on: tutti, tranne i --no-<gioco> di questa riga).
CI_BUILD_OPTS=(--keep-going --jobs 4 --pkg-jobs 2)

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
gb()   { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }
out()  { echo "$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
summ() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
# Un'annotazione del job: si legge anche dall'API (check-runs/annotations),
# senza scaricare il log. Le righe vanno codificate (%0A); nel titolo, che e'
# una proprieta' del comando, anche "," e ":" (una virgola lo tagliava).
note() {
	local level="$1" title="$2" msg="$3"
	[ -n "${GITHUB_ACTIONS:-}" ] || return 0
	msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/}"; msg="${msg//$'\n'/'%0A'}"
	title="${title//'%'/'%25'}"; title="${title//$'\n'/ }"
	title="${title//:/'%3A'}"; title="${title//,/'%2C'}"
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
		[ -e "${d}" ] && sudo timeout 600 rm -rf "${d}" &
	done
	# con un limite: una pulizia appesa non deve fermare il job (il passo ha
	# comunque il suo timeout-minutes, vedi build-stage.yml)
	timeout 300 docker image prune -af >/dev/null 2>&1 &
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

	# config/options legge questo file dopo i suoi default.
	# - ccache: 6 GB invece dei 10 di LibreELEC, per stare nella cache delle
	#   actions (10 GB per repository).
	# - BUILD_REUSABLE non vuota: gli strumenti per l'host senza -march=native
	#   (config/functions, setup_toolchain). La ccache e lo stato passano da un
	#   runner all'altro, e i runner non hanno tutti la stessa CPU. I primi
	#   pacchetti per l'host (flag local-cc: make, cmake, ...) passano dal
	#   ccache di Ubuntu 24.04 (4.9.1, in .ccache-local), che di -march=native
	#   hasha il testo e non la CPU (il 4.13 che LibreELEC costruisce chiede
	#   al compilatore cosa vuol dire): il make dell'host compilato su un
	#   runner, ripreso dalla ccache su un altro, moriva con "Illegal
	#   instruction" (run #5 e #6, al primo make install). E anche col
	#   ccache giusto, la parte 2 puo' girare su una CPU diversa da quella che
	#   ha compilato gli strumenti nello stato. Il valore non nomina "all",
	#   "mesa:host" o "save-local", che chiederebbero a mesa i suoi strumenti
	#   "riusabili" (con upx).
	mkdir -p "${TREE_NAME}/.libreelec"
	printf '%s\n' 'CCACHE_CACHE_SIZE="6G"' 'BUILD_REUSABLE="yes"' > "${TREE_NAME}/.libreelec/options"
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
			./lakka-rf35h/build-in-docker.sh "${CI_BUILD_OPTS[@]}" 2>&1 \
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
		# da solo, e un errore di rete butterebbe ore di build; uno vero si
		# ripete in pochi minuti, perche' il costruito resta (stamp) e si
		# rifa' solo il pacchetto fallito.
		if [ "${result}" = failed ] && [ "${try}" -eq 1 ]; then
			note warning "Tentativo 1 fallito: riprovo" "$(failure_report)"
			drop_interrupted
			try=2
			continue
		fi
		break
	done
	dropped_logs
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
# *-fallito.log dei pacchetti). Niente "| head -1": con pipefail un lettore che
# esce prima fa fallire chi scrive (vedi check_system).
mainlog() {
	local l
	l="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].log 2>/dev/null || true)"
	printf '%s\n' "${l%%$'\n'*}"
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
# compilazione quelli di rete (un "fatal:" di git non contiene "error") e i
# processi morti ("Illegal instruction" di un make compilato per un'altra CPU).
failure_report() {
	local log pkg flog
	log="$(mainlog)"
	[ -n "${log}" ] || { echo "nessun log della build: e' fallita prima (vedi il passo)"; return 0; }
	pkg="$(sed -n 's|.*FAILURE: scripts/[a-z]* \([A-Za-z0-9_.+-]*\):[a-z]* has failed!.*|\1|p' "${log}" | tail -1)"
	flog="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-*-"${pkg:-nessuno}"-fallito.log 2>/dev/null | head -1)"
	echo "pacchetto: ${pkg:-?} (log: $(basename "${flog:-${log}}"))"
	grep -aE 'error|Error|FAILED|No such file|fatal:|Cannot get|curl: \(|unable to|Could not|Failed to|timed out|reset by peer|Illegal instruction|Segmentation fault|core dumped|Killed' "${flog:-${log}}" \
		| grep -av 'Werror\|error\.o\|_error\.' | tail -10 | cut -c1-180
	echo "--- coda:"
	tail -20 "${flog:-${log}}" | cut -c1-180
}

# I log dei pacchetti falliti in questa parte (build-rf35h-<data>-<pkg>-
# fallito.log: core e giochi lasciati fuori da --keep-going, o il pacchetto che
# ha fermato la build), errori e coda, uno per annotazione. Stanno anche
# nell'artifact dei log, ma le annotazioni si leggono dall'API senza scaricare
# niente: nella #28 i tre core in Rust risultavano solo "lasciati fuori", senza
# un perche' leggibile. Ogni parte ha i suoi: lo stato non li porta (pack).
dropped_logs() {
	local f pkg
	for f in "${W}/${TREE_NAME}"/build-rf35h-*-fallito.log; do
		[ -f "${f}" ] || continue
		pkg="${f##*/build-rf35h-}"; pkg="${pkg#*-*-}"; pkg="${pkg%-fallito.log}"
		note warning "Log di ${pkg}" "$( {
			grep -aE 'error|Error|FAILED|No such file|fatal:|Cannot get|curl: \(|unable to|Could not|could not compile|linking with|Failed to|timed out|Killed' "${f}" \
				| grep -av 'Werror\|error\.o\|_error\.' | tail -12 | cut -c1-200
			echo "--- coda:"
			tail -12 "${f}" | cut -c1-200
		} )"
	done
}

# I pacchetti che la build stava facendo quando si e' fermata (scadenza della
# parte, o un errore): via la loro cartella di build e i loro stamp di build, e
# la volta dopo LibreELEC li rifa' da un sorgente scompattato di nuovo (il
# sorgente si riscarica comunque: scripts/unpack chiama get, e sources/ non e'
# nello stato; la ccache aiuta). Altrimenti li riprende nella stessa cartella:
# un link ucciso con SIGKILL (docker kill alla scadenza) lascia un .so di 0 byte
# piu' nuovo dei suoi oggetti, make lo prende per buono e l'immagine lo
# installa. Si riconoscono dal lock del job,
# build.*/.threads/locks/<pacchetto>:<target>.build.owner (config/functions,
# pkg_lock_status), che solo la fine del job toglie; .threads si azzera a ogni
# make image. Gli stamp tutti, non solo quello del target interrotto: gcc:target,
# per dire, copia i suoi file dalla cartella di build di gcc:host.
drop_interrupted() {
	: "${W:?}"
	local b o job jobs d name n
	for b in "${W}/${TREE_NAME}"/build.*/; do
		jobs=""; n=0
		for o in "${b}.threads/locks/"*.build.owner; do
			[ -f "${o}" ] || continue
			job="${o##*/}"; job="${job%.build.owner}"
			# finito proprio mentre lo si fermava: lo stamp c'e'
			[ -f "${b}.stamps/${job%:*}/build_${job##*:}" ] && continue
			jobs="${jobs} ${job}"
		done
		[ -n "${jobs}" ] || continue
		# la cartella di un pacchetto la riconosce il nome che unpack ci scrive
		for d in "${b}build/"*/; do
			[ -f "${d}.libreelec-package" ] || continue
			name="$(sed -n 's/^INFO_PKG_NAME="\(.*\)"$/\1/p' "${d}.libreelec-package")"
			case " ${jobs} " in
				*" ${name}:"*) rm -rf "${d}"; n=$((n + 1)) ;;
			esac
		done
		for job in ${jobs}; do rm -f "${b}.stamps/${job%:*}/build_"*; done
		echo "  interrotti:${jobs}: si rifanno da capo (${n} cartelle di build tolte)"
		note notice "Pacchetti interrotti" "${jobs# }: si rifanno da capo (${n} cartelle di build tolte)"
	done
}

cmd_pack() {
	local n="${1:?parte}" why="${2:-}" size
	: "${W:?}"
	cd "${W}"
	say "Stato della parte ${n}"
	drop_interrupted
	du -sh "${TREE_NAME}" "${TREE_NAME}"/build.*/* "${TREE_NAME}"/build.*/.ccache* 2>/dev/null | sort -h | tail -12 || true
	# Fuori: i sorgenti (si riscaricano, e solo per i pacchetti ancora da
	# fare), i log e i resoconti (vanno negli artifact a parte), i file
	# temporanei dell'immagine, lo stato dei thread.
	# --anchored --no-wildcards-match-slash: senza, per tar le esclusioni
	# valgono a ogni profondita' e "*" attraversa le "/", quindi
	# build.*/image toglieva OGNI cartella "image" sotto build.*: nel
	# sorgente del kernel drivers/usb/image (build #25: olddefconfig fallito
	# su un kernel scompattato nella parte prima) e in install_pkg quelle
	# dei pacchetti fatti nelle parti prima, che sparivano dall'immagine.
	tar -C "${W}" --anchored --no-wildcards-match-slash \
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
	# ccache 4 ripete Hits e Misses sotto "Local storage": una volta sola
	note notice "ccache" "$(echo "${st}" | grep -iE 'hits|misses|cache size' | tr -s ' ' | awk '!seen[$0]++' | tr '\n' ';')"
}

# --- il SYSTEM di un'immagine (collect qui, check-dist nel job release) ------

# Il SYSTEM di un .tar di aggiornamento, in <dir>/SYSTEM. L'elenco del tar va in
# un file: niente pipe con un lettore che esce prima (vedi check_system).
system_of() {
	local tarf="$1" dir="$2" sys
	tar -tf "${tarf}" > "${dir}/tar.list"
	sys="$(grep -m1 '/target/SYSTEM$' "${dir}/tar.list" || true)"
	[ -n "${sys}" ] || die "SYSTEM non trovato in $(basename "${tarf}")"
	tar -xOf "${tarf}" "${sys}" > "${dir}/SYSTEM"
}

# un numero little-endian dai byte in esadecimale ("e803" -> 1000)
le() {
	local x="$1" r=""
	while [ -n "${x}" ]; do r="${x:0:2}${r}"; x="${x:2}"; done
	echo "$(( 16#${r:-0} ))"
}

# Una libreria ELF a 64 bit little-endian per aarch64 (ET_DYN, EM_AARCH64),
# intera: la tabella delle sezioni (e_shoff + e_shnum * e_shentsize), che il
# linker scrive in fondo, sta dentro il file. Provata sui 34 core della v1.0.0.
# Un e_shoff col bit alto acceso in bash e' negativo: fuori anche quello.
elf_ok() {
	local so="$1" h size off end
	size="$(stat -c%s "${so}")"
	[ "${size}" -ge 64 ] || return 1
	h="$(od -An -v -tx1 -N64 "${so}" | tr -d ' \n')"
	[ "${h:0:12}" = 7f454c460201 ] && [ "${h:32:8}" = 0300b700 ] || return 1
	off="$(le "${h:80:16}")"
	end=$(( off + $(le "${h:120:4}") * $(le "${h:116:4}") ))
	[ "${off}" -ge 0 ] && [ "${end}" -ge "${off}" ] && [ "${end}" -le "${size}" ]
}

# Il SYSTEM prima di darlo alle console. Scrive <dir>/cores.txt (i nomi dei
# core: mednafen_pce_fast per mednafen_pce_fast_libretro.so).
#  - re3 (GTA III) non ha licenza: mai in un'immagine pubblica. La build non lo
#    ha (niente --re3), ma lo si guarda nel SYSTEM, non nelle opzioni.
#  - In usr/lib/libretro nessun file vuoto e ogni .so un ELF aarch64 intero: un
#    link ucciso alla scadenza di una parte lascia un .so di 0 byte (o a meta')
#    piu' nuovo dei suoi oggetti, e nella parte dopo make lo prende per buono e
#    LibreELEC lo installa.
# Un solo elenco, in un file, per re3 e per i core: "unsquashfs -l | grep -q"
# sotto pipefail perdeva re3 proprio quando c'era (grep esce alla prima riga,
# unsquashfs muore di SIGPIPE, la condizione risulta falsa).
check_system() {
	local sys="$1" dir="$2" lst="$2/system.list" lr="$2/libretro" so bad=""
	unsquashfs -l "${sys}" > "${lst}" || die "SYSTEM illeggibile (unsquashfs)"
	grep -q '^squashfs-root/usr/lib/libretro$' "${lst}" || die "SYSTEM senza usr/lib/libretro"
	if grep -qiE 're3_libretro|/re3([/.]|$)' "${lst}"; then
		die "re3 nel SYSTEM: questa immagine non si pubblica ($(grep -ciE 're3_libretro|/re3([/.]|$)' "${lst}") file)"
	fi
	sed -n 's|.*usr/lib/libretro/\([^/]*\)_libretro\.so$|\1|p' "${lst}" | sort > "${dir}/cores.txt"
	rm -rf "${lr}"
	unsquashfs -n -no-xattrs -d "${lr}" "${sys}" usr/lib/libretro > /dev/null \
		|| die "usr/lib/libretro non si estrae dal SYSTEM"
	while IFS= read -r -d '' so; do
		if [ ! -s "${so}" ]; then
			bad="${bad} ${so##*/} (0 byte)"
		elif [ "${so%.so}" != "${so}" ] && ! elf_ok "${so}"; then
			bad="${bad} ${so##*/} ($(stat -c%s "${so}") byte, non un ELF aarch64 intero)"
		fi
	done < <(find "${lr}" -type f -print0)
	rm -rf "${lr}"
	[ -z "${bad}" ] || die "core rotti nel SYSTEM, l'immagine non si pubblica:${bad}"
}

# --- l'immagine e' completa? (collect avvisa, check-dist decide) --------------

# I giochi che la build in CI costruisce, coi nomi dei loro core
# (<nome>_libretro.so): tutti, tranne quelli spenti in CI_BUILD_OPTS
extras_on() {
	local g o on=""
	for g in ikemen gtasa openxeenng deva_adventures; do
		for o in "${CI_BUILD_OPTS[@]}"; do
			[ "${o}" = "--no-${g//_/-}" ] && continue 2
		done
		on="${on} ${g}"
	done
	echo "${on# }"
}

# I core che la build in CI deve mettere nell'immagine: CORES_DEFAULT di
# build-lakka-rf35h.sh, con i nomi dei pacchetti di Lakka (beetle_pce_fast)
default_cores() {
	sed -n 's/^CORES_DEFAULT="\(.*\)"$/\1/p' "${O}/build-lakka-rf35h.sh"
}

# Quale pacchetto ha installato quale core, registrato alla build: i .so in
# build.*/install_pkg/<pacchetto>-<versione>/usr/lib/libretro, col nome del
# pacchetto da .libreelec-package (lo scrive scripts/build a fine build).
# Righe "<pacchetto> <core>", per esempio "beetle_pce_fast mednafen_pce_fast":
# CORES_DEFAULT ha i nomi dei pacchetti, cores.txt quelli dei .so.
core_packages() {
	local i pkg so
	for i in "$1"/build.*/install_pkg/*/; do
		[ -f "${i}.libreelec-package" ] || continue
		pkg="$(sed -n 's/^INFO_PKG_NAME="\(.*\)"$/\1/p' "${i}.libreelec-package")"
		[ -n "${pkg}" ] || continue
		for so in "${i}usr/lib/libretro/"*_libretro.so; do
			[ -e "${so}" ] || [ -L "${so}" ] || continue
			so="${so##*/}"
			echo "${pkg} ${so%_libretro.so}"
		done
	done | sort -u
}

# Cosa manca all'immagine in <d> rispetto alla build completa: per ogni core di
# CORES_DEFAULT i .so che il suo pacchetto ha installato (core-packages.txt), o
# il pacchetto stesso se non ha installato niente; poi i giochi accesi. Scrive
# <d>/missing.txt, una riga per pezzo ("beetle_pce_fast", "mgba (mgba_libretro.so)",
# "ikemen"). Torna 1 se manca qualcosa o se la build ha lasciato fuori qualcosa
# (dropped.txt).
completeness() {
	local d="$1" cores pkg p c found g
	[ -f "${d}/core-packages.txt" ] || die "manca ${d}/core-packages.txt: artifact di una build di prima di questo controllo?"
	cores="$(default_cores)"
	[ -n "${cores}" ] || die "CORES_DEFAULT non trovato in ${O}/build-lakka-rf35h.sh"
	: > "${d}/missing.txt"
	for pkg in ${cores}; do
		found=no
		while read -r p c; do
			[ "${p}" = "${pkg}" ] || continue
			found=yes
			grep -qxF "${c}" "${d}/cores.txt" || echo "${pkg} (${c}_libretro.so)" >> "${d}/missing.txt"
		done < "${d}/core-packages.txt"
		[ "${found}" = yes ] || echo "${pkg}" >> "${d}/missing.txt"
	done
	for g in $(extras_on); do
		grep -qxF "${g}" "${d}/cores.txt" || echo "${g}" >> "${d}/missing.txt"
	done
	[ ! -s "${d}/missing.txt" ] && [ ! -s "${d}/dropped.txt" ]
}

# GitHub non accetta in una release un file da 2 GiB in su: con tutti i core
# il .tar e' cresciuto, e scoprirlo a meta' della pubblicazione lascerebbe una
# bozza a meta'. I file della release in <d> oltre il limite, uno per parola.
ASSET_MAX=$(( 2 * 1024 * 1024 * 1024 ))
too_big() {
	local d="$1" f big=""
	for f in "${d}"/*.img.gz "${d}"/*.tar; do
		[ -f "${f}" ] || continue
		[ "$(stat -c%s "${f}")" -lt "${ASSET_MAX}" ] || big="${big} ${f##*/}:$(stat -c%s "${f}")"
	done
	echo "${big# }"
}

# una riga: cosa manca e cosa la build ha lasciato fuori
incomplete() {
	local d="$1" m f
	m="$(tr '\n' ';' < "${d}/missing.txt" | sed 's/;$//; s/;/, /g')"
	f="$( { grep -oE '^  [A-Za-z0-9_.+-]+' "${d}/dropped.txt" 2>/dev/null || true; } | tr -d ' ' | tr '\n' ' ' | sed 's/ $//; s/ /, /g')"
	echo "mancano: ${m:-niente}; lasciati fuori dalla build: ${f:-niente}"
}

# rm -rf di un albero estratto o fatto da un utente qualunque (il runner): una
# cartella senza permesso di scrittura (un SYSTEM che ne ha, una copiata cosi'
# da install_pkg) fermerebbe rm, e con set -e lo script, a lavoro finito
rm_tree() {
	chmod -R u+w "$1" 2>/dev/null || true
	rm -rf "$1"
}

# Job release: ogni core del SYSTEM (estratto in <radice>) si apre come in
# RetroArch, con le librerie e il RetroArch dell'immagine (cmd_coretest, i
# file in <cartella>). La v1.4.1 e' uscita con quattro core che compilavano e
# non si aprivano (dosbox e dosbox_core senza glib, scummvm senza fluidsynth,
# DoubleCherryGB senza parte di libretro-common): un core che non si apre
# ferma la release, come uno che manca, a meno di allow_incomplete; allora
# finisce in <dist>/noload.txt ("<file> <perche'>"), che le note della release
# nominano. Un avviso (crash chiuso senza contenuto) no. RF35H_CORETEST=no in
# check-dist: senza (le immagini finte delle prove).
dist_coretest() {
	local root="$1" d="$2" dist="$3" nolist
	: > "${dist}/noload.txt"
	if cmd_coretest "${root}" "${root}/usr/bin/retroarch" "${d}" "${root}/usr/lib/libretro/"*_libretro.so; then
		echo "  ok: $(grep -c '^ok' "${d}/coretest.txt") core si aprono$(grep -q '^avviso' "${d}/coretest.txt" && echo ", $(grep -c '^avviso' "${d}/coretest.txt") con un avviso")"
		return 0
	fi
	nolist="$(awk '$1 == "NO" { printf "%s%s", (n++ ? ", " : ""), $2 }' "${d}/coretest.txt")"
	sed -n -E 's/^NO +//p' "${d}/coretest.txt" > "${dist}/noload.txt"
	if [ "${RF35H_ALLOW_INCOMPLETE:-false}" = true ]; then
		note warning "Core che non si aprono" "${nolist}. Pubblicata lo stesso: allow_incomplete"
		summ "- core che non si aprono, pubblicata con allow_incomplete: ${nolist}"
		return 0
	fi
	note error "Core che non si aprono" "${nolist}: in RetroArch \"Failed to open libretro core\". Correggerli, o Run workflow con allow_incomplete"
	die "core che non si aprono: ${nolist}"
}

# Il job release (build.yml), sui file scaricati in <d> prima di pubblicarli:
# re3 e core rotti come in collect (un artifact si puo' anche sostituire), poi
# la completezza. Un'immagine a cui mancano core o giochi aggiornerebbe ogni
# console togliendoglieli: si ferma, a meno di RF35H_ALLOW_INCOMPLETE=true
# (Run workflow, allow_incomplete).
cmd_check_dist() {
	local d="${1:?cartella con i file della release}" chk tarf
	[ -f "${d}/update.txt" ] || die "manca ${d}/update.txt"
	tarf="${d}/$(sed -n 's/^tar=//p' "${d}/update.txt")"
	[ -f "${tarf}" ] || die "manca ${tarf}"
	say "SYSTEM di $(basename "${tarf}"): re3 assente, core interi"
	chk="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rf35h-check.XXXXXX")"
	system_of "${tarf}" "${chk}"
	check_system "${chk}/SYSTEM" "${chk}"
	if ! cmp -s "${chk}/cores.txt" "${d}/cores.txt"; then
		note warning "cores.txt" "diverso dai core del SYSTEM: vale il SYSTEM"
		cp "${chk}/cores.txt" "${d}/cores.txt"
	fi
	echo "  ok, $(wc -l < "${d}/cores.txt") core libretro, nessuno vuoto o troncato"
	if [ "${RF35H_CORETEST:-yes}" != no ]; then
		say "Core: si caricano come in RetroArch? (rf35h-coretest sotto qemu)"
		unsquashfs -n -no-xattrs -d "${chk}/root" "${chk}/SYSTEM" > /dev/null || die "SYSTEM non si estrae"
		dist_coretest "${chk}/root" "${chk}/coretest" "${d}"
	fi
	rm_tree "${chk}"

	say "Dimensioni: ogni file sotto i 2 GiB"
	local big
	big="$(too_big "${d}")"
	if [ -n "${big}" ]; then
		note error "File troppo grande" "${big} (byte): GitHub accetta nella release solo file sotto i 2 GiB"
		die "file oltre i 2 GiB, la release non si pubblica: ${big}"
	fi
	echo "  ok: $(cd "${d}" && du -h -- *.img.gz *.tar | tr '\t\n' ' ;')"

	say "Core e giochi della build completa"
	if completeness "${d}"; then
		echo "  ok: i $(default_cores | wc -w) core di CORES_DEFAULT, giochi: $(extras_on)"
		return 0
	fi
	cat "${d}/missing.txt" "${d}/dropped.txt" 2>/dev/null || true
	if [ "${RF35H_ALLOW_INCOMPLETE:-false}" = true ]; then
		note warning "Release incompleta" "$(incomplete "${d}"). Pubblicata lo stesso: allow_incomplete"
		summ "- release incompleta, pubblicata con allow_incomplete: $(incomplete "${d}")"
		return 0
	fi
	note error "Release incompleta" "$(incomplete "${d}"). Le console che aggiornano li perderebbero: ricostruire, o Run workflow con allow_incomplete"
	die "release incompleta: $(incomplete "${d}")"
}

cmd_collect() {
	: "${W:?}" "${RF35H_VERSION:?}"
	local t="${W}/${TREE_NAME}/target" dist="${W}/dist" chk="${W}/check" img tarf
	[ -d "${t}" ] || die "manca ${t}: la build non ha prodotto immagini"
	img="$(find "${t}" -maxdepth 1 -name '*rf35h*.img.gz' -printf '%T@ %p\n' | sort -rn | sed -n '1s/^[^ ]* //p')"
	[ -n "${img}" ] || die "nessuna immagine in ${t}"
	tarf="${img%.img.gz}.tar"
	[ -f "${tarf}" ] || die "manca $(basename "${tarf}")"
	case "$(basename "${img}")" in
		*"-${RF35H_VERSION}-"*) ;;
		*) die "$(basename "${img}") non porta la versione ${RF35H_VERSION}" ;;
	esac

	say "SYSTEM: re3 assente, core interi"
	rm -rf "${chk}"; mkdir -p "${chk}"
	system_of "${tarf}" "${chk}"
	check_system "${chk}/SYSTEM" "${chk}"
	echo "  ok, $(wc -l < "${chk}/cores.txt") core libretro nell'immagine, nessuno vuoto o troncato"

	say "File della release in ${dist}"
	rm -rf "${dist}"; mkdir -p "${dist}"
	mv "${img}" "${tarf}" "${dist}/"
	mv "${chk}/cores.txt" "${dist}/cores.txt"
	rm -rf "${chk}"
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
	# quello che la build ha lasciato fuori (--keep-going): il resoconto della
	# build che ha fatto l'immagine, l'ultima. Un tentativo fallito prima (la
	# seconda prova di cmd_build) puo' averne lasciato un altro, di pacchetti
	# che poi si sono costruiti.
	local log
	log="$(mainlog)"
	if [ -n "${log}" ] && [ -f "${log%.log}-core-saltati.txt" ]; then
		cp "${log%.log}-core-saltati.txt" dropped.txt
	else
		: > dropped.txt
	fi
	# quale pacchetto ha installato quale core: check-dist confronta i nomi dei
	# pacchetti di CORES_DEFAULT con i .so dell'immagine
	core_packages "${W}/${TREE_NAME}" > core-packages.txt
	ls -la
	cat update.txt
	summ "- immagine: $(basename "${img}") ($(du -h "$(basename "${img}")" | cut -f1)), aggiornamento: ${tb} ($(du -h "${tb}" | cut -f1))"
	if [ -s dropped.txt ]; then summ "- lasciati fuori dalla build: $(grep -oE '^  [A-Za-z0-9_.+-]+' dropped.txt | tr -d ' ' | tr '\n' ' ')"; fi
	note notice "Immagine" "$(basename "${img}") $(du -h "$(basename "${img}")" | cut -f1), ${tb} $(du -h "${tb}" | cut -f1), $(wc -l < cores.txt) core; fuori: $(grep -oE '^  [A-Za-z0-9_.+-]+' dropped.txt | tr -d ' ' | tr '\n' ' ')"
	# la decisione e' del job release (check-dist); qui l'avviso, gia' sul run
	local big
	big="$(too_big "${dist}")"
	if [ -n "${big}" ]; then
		note warning "File troppo grande" "${big} (byte): oltre i 2 GiB, il job release non lo pubblica"
		summ "- oltre i 2 GiB, non pubblicabile: ${big}"
	fi
	if ! completeness "${dist}"; then
		note warning "Immagine incompleta" "$(incomplete "${dist}"): il job release non la pubblica senza allow_incomplete"
		summ "- immagine incompleta: $(incomplete "${dist}")"
	fi
}

# --- versione e release (build.yml) ---------------------------------------------
# Le console si aggiornano dalla release "latest" (update.txt): chi la decide e'
# qui, non GitHub. Variabili: GITHUB_* del runner, DEFAULT_BRANCH, GH_TOKEN; per
# version IN_VERSION, IN_PRERELEASE, IN_RESUME (gli input di Run workflow); per
# publish VERSION e PRERELEASE (dal job setup).

# un errore che si legge anche fra le annotazioni del run, poi l'uscita
fail() { note error "$1" "$2"; die "$2"; }

# Il commit $1 e' nella storia del ramo principale di origin, letto adesso?
on_default_branch() {
	local c
	c="$(git -C "${O}" rev-parse --verify -q "$1^{commit}")" || return 1
	if [ "$(git -C "${O}" rev-parse --is-shallow-repository)" = true ]; then
		git -C "${O}" fetch -q --unshallow origin || return 1
	fi
	git -C "${O}" fetch -q --no-tags origin "+refs/heads/${DEFAULT_BRANCH}:refs/remotes/origin/${DEFAULT_BRANCH}" || return 1
	git -C "${O}" merge-base --is-ancestor "${c}" "refs/remotes/origin/${DEFAULT_BRANCH}"
}

# I .github/workflows del commit $1 sono diversi da quelli del ramo principale
# di origin, letto adesso? Allora il GITHUB_TOKEN, che non ha il permesso
# "workflows", puo' non riuscire a creare il tag (ne' quindi la release) su
# quel commit: HTTP 403 "Resource not accessible by integration". Visto con
# la v1.4.0 (9/10/2026): il commit della build (0dc6872) non toccava i
# workflow, ma durante la build su main era cambiato cores.yml (62d1aaf), e il
# job Release si e' fermato li'; riportato su main il cores.yml di 0dc6872,
# lo stesso job rilanciato ha pubblicato. La regola esatta di GitHub non e'
# questa: la v1.3.0 (e563026) e' passata con main gia' diverso, ma c'erano
# rami (ci-test/*) coi suoi stessi workflow; la v1.3.1 (b3c49f3) no. Quindi
# non si ferma niente in anticipo: si prova, e se gh risponde 403 il messaggio
# dice le due strade. Esce 2 se main non si legge.
workflows_unlike_main() {
	git -C "${O}" fetch -q --no-tags origin "+refs/heads/${DEFAULT_BRANCH}:refs/remotes/origin/${DEFAULT_BRANCH}" || return 2
	! git -C "${O}" diff --quiet "$1" "refs/remotes/origin/${DEFAULT_BRANCH}" -- .github/workflows
}

# Il commit del tag $1 su origin, vuoto se il tag non c'e': il ^{} di un tag
# annotato, il tag stesso per uno leggero
tag_commit() {
	local out
	out="$(git -C "${O}" ls-remote --tags origin "refs/tags/$1" "refs/tags/$1^{}")" || return 1
	awk -v t="refs/tags/$1" '$2 == t "^{}" { p = $1 } $2 == t { l = $1 } END { print (p != "" ? p : l) }' <<< "${out}"
}

# Le release con il tag $1, righe "<id> <bozza: true|false>". Dall'API REST: le
# bozze le vede solo chi puo' scrivere (il job release, non setup).
release_ids() {
	RF35H_TAG="$1" gh api --paginate "repos/${GITHUB_REPOSITORY}/releases?per_page=100" \
		--jq '.[] | select(.tag_name == env.RF35H_TAG) | "\(.id) \(.draft)"'
}

# Il tag della release "latest" di adesso; vuoto se non ce n'e' una
latest_tag() {
	local out
	if out="$(gh api "repos/${GITHUB_REPOSITORY}/releases/latest" --jq .tag_name 2>&1)"; then
		printf '%s\n' "${out}"
	else
		case "${out}" in *"HTTP 404"*) return 0 ;; esac
		echo "${out}" >&2
		return 1
	fi
}

# $1 e' una versione piu' alta di $2? sort -V (v1.10.0 dopo v1.9.0), col
# trattino come ~ perche' v1.1.0-rc1 venga prima di v1.1.0 (una rc promossa a
# mano a latest non deve fermare la v1.1.0)
newer() {
	local a b
	a="$(printf '%s' "$1" | sed 's/-/~/g')"; b="$(printf '%s' "$2" | sed 's/-/~/g')"
	[ "${a}" != "${b}" ] && [ "$(printf '%s\n' "${a}" "${b}" | sort -V | tail -n 1)" = "${a}" ]
}

# Job setup: la versione, se si pubblica, se e' una pre-release
# (GITHUB_OUTPUT: version, publish, prerelease, resume).
cmd_version() {
	: "${GITHUB_EVENT_NAME:?}" "${GITHUB_REF_NAME:?}" "${GITHUB_RUN_NUMBER:?}" "${GITHUB_REPOSITORY:?}" "${DEFAULT_BRANCH:?}"
	local version publish=false prerelease=false tag rels from="${IN_PUBLISH_FROM:-}" bsha info rpath rstatus art
	bsha="${GITHUB_SHA:-$(git -C "${O}" rev-parse HEAD)}"
	# una release si costruisce sempre da zero: la ripresa riusa pacchetti
	# fatti da un altro commit
	case "${IN_RESUME:-}" in
		'') ;;
		*[!0-9]*) fail "resume_run" "resume_run: un ID di run (numero)" ;;
		*) [ -z "${IN_VERSION:-}" ] || fail "resume_run" "resume_run solo per le build di prova, senza version" ;;
	esac
	# publish_from: i file di una build di release gia' fatta (run <from>),
	# pubblicati dal job Release di questo run, con gli script di questo
	# commit. Per quando il job Release di quel run non puo' riuscire neanche
	# rilanciato (un rilancio rifa' lo stesso codice). Il commit della release
	# resta quello della build.
	case "${from}" in
		'') ;;
		*[!0-9]*) fail "publish_from" "publish_from: un ID di run (numero)" ;;
		*)
			[ "${GITHUB_EVENT_NAME}" = workflow_dispatch ] && [ -n "${IN_VERSION:-}" ] \
				|| fail "publish_from" "publish_from solo da Run workflow, con la version della build"
			[ -z "${IN_RESUME:-}" ] || fail "publish_from" "publish_from e resume_run insieme no"
			info="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${from}" --jq '[.path, .status, .head_sha] | @tsv' 2>&1)" \
				|| fail "publish_from" "il run ${from} non si legge: ${info}"
			IFS=$'\t' read -r rpath rstatus bsha <<< "${info}"
			[ "${rpath}" = ".github/workflows/build.yml" ] || fail "publish_from" "il run ${from} non e' una build (${rpath})"
			[ "${rstatus}" = completed ] || fail "publish_from" "il run ${from} non e' finito (${rstatus})"
			case "${bsha}" in *[!0-9a-f]*|'') fail "publish_from" "commit del run ${from} illeggibile: ${bsha}" ;; esac
			# l'artifact di una release di questa versione: lo carica solo una
			# build con version (una prova si chiama lakka-rf35h-ci-<n>-<commit>,
			# e la ripresa con resume_run e' solo per le prove)
			art="$(RF35H_ART="lakka-rf35h-${IN_VERSION}" gh api --paginate "repos/${GITHUB_REPOSITORY}/actions/runs/${from}/artifacts?per_page=100" \
				--jq '.artifacts[] | select(.name == env.RF35H_ART and (.expired | not)) | .id' 2>&1)" \
				|| fail "publish_from" "gli artifact del run ${from} non si leggono: ${art}"
			[ -n "${art}" ] || fail "publish_from" "il run ${from} non ha i file della ${IN_VERSION} (artifact lakka-rf35h-${IN_VERSION}, 14 giorni): non era una release di questa versione, o non e' arrivato in fondo"
			;;
	esac
	if [ "${GITHUB_EVENT_NAME}" = push ] && [ "${GITHUB_REF_TYPE:-}" = tag ]; then
		version="${GITHUB_REF_NAME}"; publish=true
	elif [ "${GITHUB_EVENT_NAME}" = workflow_dispatch ] && [ -n "${IN_VERSION:-}" ]; then
		version="${IN_VERSION}"; publish=true
		prerelease="${IN_PRERELEASE:-false}"
	else
		version="ci-${GITHUB_RUN_NUMBER}-$(git -C "${O}" rev-parse --short=7 HEAD)"
	fi
	case "${version}" in
		''|*[!A-Za-z0-9._+-]*) fail "Versione" "versione '${version}': solo lettere, cifre e . _ + -" ;;
	esac
	if [ "${publish}" = true ]; then
		# con un trattino (v1.1.0-rc1) e' una pre-release, dal tag come da Run
		# workflow, anche senza la casella: le console non la vedono
		case "${version}" in *-*) prerelease=true ;; esac
		# le altre le scaricano tutte le console: solo dal ramo principale
		if [ "${prerelease}" != true ]; then
			if [ "${GITHUB_EVENT_NAME}" = workflow_dispatch ] && [ "${GITHUB_REF_NAME}" != "${DEFAULT_BRANCH}" ]; then
				fail "Versione" "da ${GITHUB_REF_NAME} solo pre-release: le console aggiornano all'ultima release"
			fi
			on_default_branch "${bsha}" \
				|| fail "Versione" "${version}: il commit non e' su ${DEFAULT_BRANCH}; da altri rami solo pre-release (v1.1.0-rc1, o la casella prerelease)"
		fi
		if [ "${GITHUB_EVENT_NAME}" = workflow_dispatch ]; then
			tag="$(tag_commit "${version}")" || fail "Versione" "origin non risponde (git ls-remote)"
			if [ -n "${tag}" ]; then
				# con publish_from il tag puo' esserci gia', ma sul commit della
				# build (vedi sotto: va creato a mano se i suoi workflow non
				# sono piu' quelli di main)
				[ -n "${from}" ] && [ "${tag}" = "${bsha}" ] \
					|| fail "Versione" "il tag ${version} esiste gia': per ricostruirlo si fa push del tag, oppure un'altra versione"
			elif workflows_unlike_main "${bsha}"; then
				# Il GITHUB_TOKEN potrebbe non creare il tag
				# (workflows_unlike_main): un avviso, non un errore. Da Run
				# workflow su main non succede (il commit e' la punta); con
				# publish_from di una build vecchia si'.
				echo "attenzione: i .github/workflows di ${bsha:0:12} non sono piu' quelli di ${DEFAULT_BRANCH}" >&2
				note warning "Versione" "i .github/workflows di ${bsha:0:12} non sono piu' quelli di ${DEFAULT_BRANCH}: il job Release potrebbe non riuscire a creare il tag ${version} (403). Se succede, il suo messaggio dice cosa fare; per evitarlo, crea prima il tag (git push origin ${bsha}:refs/tags/${version})"
			fi
		fi
		rels="$(release_ids "${version}")" || fail "Versione" "elenco delle release illeggibile"
		if grep -q ' false$' <<< "${rels}"; then
			fail "Versione" "la release ${version} esiste gia'"
		fi
	fi
	{
		echo "version=${version}"
		echo "publish=${publish}"
		echo "prerelease=${prerelease}"
		echo "resume=${IN_RESUME:-}"
		echo "from=${from}"
		echo "build_sha=${bsha}"
	} >> "${GITHUB_OUTPUT:-/dev/null}"
	{
		echo "### ${version}"
		if [ "${publish}" != true ]; then
			echo "Build di prova: nessuna release, l'immagine negli artifact."
		elif [ -n "${from}" ]; then
			echo "Nessuna build: si pubblicano i file del run ${from} (commit ${bsha:0:12})."
		elif [ "${prerelease}" = true ]; then
			echo "Pre-release a fine build: le console non la vedono."
		else
			echo "Release a fine build: \"latest\" (la scaricano le console) se e' la versione piu' alta."
		fi
	} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
	echo "versione ${version}, release ${publish}, pre-release ${prerelease}${from:+, file del run ${from} (${bsha:0:12})}"
}

# Job release: pubblica i file di <d> (dopo check-dist e le note). Bozza, file,
# poi pubblicata: una console che guarda proprio in quel momento non trova mai
# una release senza update.txt.
# Un comando gh del job release: se fallisce, il suo messaggio in
# un'annotazione (il log del job non si legge dall'API). Il 8/10/2026 la
# v1.3.1 si e' fermata due volte su "gh release create" senza un perche'
# leggibile.
gh_step() {
	local what="$1" out hint=""
	shift
	if ! out="$("$@" 2>&1)"; then
		printf '%s\n' "${out}" >&2
		if [ -n "${GH_403_HINT:-}" ] && grep -q 'HTTP 403' <<< "${out}"; then
			hint=" -- ${GH_403_HINT}"
		fi
		fail "Pubblica" "${what}: $(printf '%s\n' "${out}" | grep -v '^[[:space:]]*$' | tail -n 5)${hint}"
	fi
	[ -z "${out}" ] || printf '%s\n' "${out}"
}

cmd_publish() {
	local d="${1:?cartella con i file della release}" pre="${PRERELEASE:-false}" latest=false sha tag rels id draft cur
	: "${VERSION:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${DEFAULT_BRANCH:?}"
	# il commit della build: questo run, o quello di publish_from
	local bsha="${RF35H_BUILD_SHA:-${GITHUB_SHA}}"
	case "${VERSION}" in *-*) pre=true ;; esac
	sha="$(git -C "${O}" rev-parse --verify -q "${bsha}^{commit}")" || fail "Pubblica" "commit ${bsha} non trovato"
	# di nuovo, adesso: una release che non e' pre-release solo dal ramo principale
	if [ "${pre}" != true ] && ! on_default_branch "${sha}"; then
		fail "Pubblica" "${sha:0:12} non e' su ${DEFAULT_BRANCH}: da qui solo pre-release"
	fi
	# il tag, se c'e' gia' (push del tag, o creato nel frattempo), deve essere
	# sul commit della build
	tag="$(tag_commit "${VERSION}")" || fail "Pubblica" "origin non risponde (git ls-remote)"
	if [ -n "${tag}" ] && [ "${tag}" != "${sha}" ]; then
		fail "Pubblica" "il tag ${VERSION} e' su ${tag:0:12}, la build su ${sha:0:12}: non pubblico"
	fi
	# durante la build qualcuno puo' aver cambiato i workflow su main: allora il
	# tag puo' non crearsi (workflows_unlike_main). Si prova lo stesso; se gh
	# risponde 403, il messaggio (GH_403_HINT, in gh_step) dice le due strade
	# (la v1.4.0 e' uscita con la seconda, 9/10/2026)
	GH_403_HINT=""
	if [ -z "${tag}" ] && workflows_unlike_main "${sha}"; then
		GH_403_HINT="su ${DEFAULT_BRANCH} i .github/workflows non sono piu' quelli di ${sha:0:12}, e il GITHUB_TOKEN non puo' creare il tag ${VERSION}. Due strade, poi Re-run failed jobs di questo run (o Run workflow con version ${VERSION} e publish_from ${RF35H_FROM_RUN:-${GITHUB_RUN_ID:-<il run della build>}}): 1) il tag dal proprietario, git push origin ${sha}:refs/tags/${VERSION} (ferma la build che il push fa partire); 2) su ${DEFAULT_BRANCH}, per il tempo della pubblicazione, git checkout ${sha:0:12} -- .github/workflows, commit e push, poi si rimettono"
	fi
	# Una release gia' pubblicata con questo tag ferma tutto. Le bozze sono di
	# un tentativo fallito (il job rilanciato, o un run di prima della stessa
	# versione): via, e si rifa' da capo.
	rels="$(release_ids "${VERSION}")" || fail "Pubblica" "elenco delle release illeggibile"
	while read -r id draft; do
		[ -n "${id}" ] || continue
		[ "${draft}" = true ] || fail "Pubblica" "la release ${VERSION} e' gia' pubblicata"
		echo "  bozza ${id} di un tentativo precedente: la cancello"
		# senza ridirigere: l'annotazione di un errore va su stdout
		gh_step "bozza ${id} non cancellata" gh api -X DELETE "repos/${GITHUB_REPOSITORY}/releases/${id}"
	done <<< "${rels}"
	# "latest" solo alla versione piu' alta: GitHub fa "latest" ogni release
	# appena pubblicata, e una versione piu' bassa (una v1.0.1 dopo la v1.1.0,
	# o il job di una release vecchia rilanciato) farebbe tornare indietro le
	# console. Mai una pre-release.
	if [ "${pre}" != true ]; then
		cur="$(latest_tag)" || fail "Pubblica" "la release latest non si legge"
		if [ -z "${cur}" ] || newer "${VERSION}" "${cur}"; then latest=true; fi
	fi
	local flags=()
	if [ "${pre}" = true ]; then flags+=(--prerelease); fi
	cd "${d}"
	gh_step "gh release create" gh release create "${VERSION}" --repo "${GITHUB_REPOSITORY}" --draft \
		--target "${sha}" --title "Lakka RF35H ${VERSION}" \
		--notes-file RELEASE-NOTES.md "${flags[@]}"
	gh_step "gh release upload" gh release upload "${VERSION}" --repo "${GITHUB_REPOSITORY}" --clobber \
		./*.img.gz ./*.tar update.txt SHA256SUMS
	gh_step "gh release edit" gh release edit "${VERSION}" --repo "${GITHUB_REPOSITORY}" --draft=false --latest="${latest}"
	if [ "${pre}" = true ]; then
		cur="pre-release: le console non la vedono"
	elif [ "${latest}" = true ]; then
		cur="latest: le console si aggiornano a questa"
	else
		cur="non latest: resta ${cur}, piu' alta"
	fi
	echo "  pubblicata, ${cur}"
	summ "### Pubblicata: https://github.com/${GITHUB_REPOSITORY}/releases/tag/${VERSION} (${cur})"
	note notice "Release" "${VERSION} pubblicata, ${cur}"
}

# --- i core da soli (cores.yml) ---------------------------------------------------
# Un core nuovo si compila sull'albero di una release (toolchain e sistema
# fatti), non da zero: lo stato della build finita, senza quello che si
# riscarica o non serve. Fuori: sources (si riscaricano, solo per i core da
# fare), target, log, .threads, image, le ccache (nella cache delle actions),
# il sorgente del kernel (build/linux-*, tenuto da AUTOREMOVE solo per
# verify-kernel). Restano toolchain, install_pkg e gli stamp: scripts/build di
# un core trova le dipendenze fatte e compila solo lui.
# Il nome del file e' quello dell'artifact (upload con archive: false):
# sysroot-<versione>.tar.zst, che cores.yml cerca per prefisso.
cmd_pack_sysroot() {
	: "${W:?}" "${RF35H_VERSION:?}"
	local f="${W}/sysroot-${RF35H_VERSION}.tar.zst"
	cd "${W}"
	say "Sysroot per le build dei core"
	drop_interrupted
	# --anchored --no-wildcards-match-slash come in cmd_pack: senza, build.*/image
	# toglierebbe ogni cartella "image" dell'albero
	tar -C "${W}" --anchored --no-wildcards-match-slash \
		--exclude="${TREE_NAME}/sources" \
		--exclude="${TREE_NAME}/target" \
		--exclude="${TREE_NAME}/build-rf35h-*" \
		--exclude="${TREE_NAME}/build.*/.threads" \
		--exclude="${TREE_NAME}/build.*/image" \
		--exclude="${TREE_NAME}/build.*/.ccache" \
		--exclude="${TREE_NAME}/build.*/.ccache-local" \
		--exclude="${TREE_NAME}/build.*/build/linux-[0-9]*" \
		-I 'zstd -T0 -3' -cf "${f}" "${TREE_NAME}"
	ls -la "${f}"
	summ "- sysroot per i core: $(du -h "${f}" | cut -f1) (artifact, 90 giorni)"
	note notice "Sysroot" "$(basename "${f}") $(du -h "${f}" | cut -f1): le build dei core (cores.yml) partono da qui"
}

# I core pesanti, ognuno in un job suo: quelli che CORES_DEFAULT mette in
# testa (partono per primi nella build dell'immagine) e citra, flycast e play.
# mame da zero sono quasi 5 ore. Gli altri a gruppi di CORES_PER_JOB.
CORES_HEAVY="mame scummvm mame2015 mame2010 same_cdi vice dolphin ppsspp fbneo citra flycast play"
CORES_PER_JOB=12

# Job cores, setup: i core da compilare divisi fra i job paralleli, come JSON
# per strategy.matrix: {"include":[{"g":"01","cores":"mame"},...]}. "g" da'
# il nome ai job e ai loro artifact.
cmd_cores_matrix() {
	local cores="${1:-}" c n=0 g=0 batch="" items=""
	add() { g=$((g + 1)); items="${items:+${items},}$(printf '{"g":"%02d","cores":"%s"}' "${g}" "$1")"; }
	for c in ${cores}; do
		case " ${CORES_HEAVY} " in *" ${c} "*) add "${c}" ;; esac
	done
	for c in ${cores}; do
		case " ${CORES_HEAVY} " in *" ${c} "*) continue ;; esac
		batch="${batch:+${batch} }${c}"; n=$((n + 1))
		if [ "${n}" -ge "${CORES_PER_JOB}" ]; then add "${batch}"; batch=""; n=0; fi
	done
	[ -z "${batch}" ] || add "${batch}"
	printf '{"include":[%s]}\n' "${items}"
}

# Job cores, pin: i risultati dei job paralleli in <d>: built.txt e
# failed.txt. download-artifact con "pattern" mette ogni artifact
# in una cartella col suo nome sotto <parts>, ma se ne trova uno solo lo
# scompatta direttamente in <parts> (artifacts.length === 1, nel suo
# sorgente): si leggono tutte e due. Con un gruppo solo la prima corsa vera
# non aveva trovato niente, e i tre core erano finiti nell'issue come senza
# risultato. Un core senza risultato (il job del suo gruppo si e' fermato
# prima: tempo, disco, un errore della CI) va fra i falliti: resta al commit
# vecchio e finisce nell'issue come gli altri.
cmd_merge_cores() {
	local parts="${1:?cartella dei risultati}" d="${2:?cartella di uscita}" cores="${3:-}" p c
	rm -rf "${d}"; mkdir -p "${d}"
	: > "${d}/built.txt"; : > "${d}/failed.txt"
	for p in "${parts}/" "${parts}"/*/; do
		[ -d "${p}" ] || continue
		if [ -f "${p}built.txt" ]; then cat "${p}built.txt" >> "${d}/built.txt"; fi
		if [ -f "${p}failed.txt" ]; then cat "${p}failed.txt" >> "${d}/failed.txt"; fi
	done
	for c in ${cores}; do
		grep -q "^core=${c} " "${d}/built.txt" && continue
		grep -q "^== ${c}:" "${d}/failed.txt" && continue
		echo "== ${c}: nessun risultato (il job del suo gruppo si e' fermato prima: vedi il run)" >> "${d}/failed.txt"
	done
	echo "  riusciti: $(grep -c '^core=' "${d}/built.txt" || true), falliti: $(grep -c '^==' "${d}/failed.txt" || true)"
}

# Il repository e il commit di un core in cores/pins.txt
pin_of() { awk -v c="$1" '$1 == c && $2 ~ /^https?:/ { print $2, $3 }' "${O}/cores/pins.txt"; }

# Le dipendenze pinnate di un core, le righe "+<pacchetto>" subito sotto la sua
# in cores/pins.txt (o nel file $2): "<pacchetto> <repository> <commit>"
deps_of() {
	awk -v c="$1" '
		/^\+/ { if (on && $2 ~ /^https?:/) print substr($1, 2), $2, $3; next }
		{ on = ($1 == c && $2 ~ /^https?:/) }
	' "${2:-${O}/cores/pins.txt}"
}

# Il pin di un core in un file di pin, cosi' com'e': la sua riga e quelle
# delle sue dipendenze
pin_block() {
	awk -v c="$1" '
		/^\+/ { if (on) print; next }
		{ on = ($1 == c && $2 ~ /^https?:/) }
		on
	' "$2"
}

# I riusciti di built.txt come <core>@<commit>, con le dipendenze provate
# insieme: "easyrpg@0de2a9a+liblcf@6854310 fceumm@1111111 "
built_list() {
	awk '{
		s = substr($1, 6) "@" substr($2, 8, 7)
		for (i = 3; i <= NF; i++) if ($i ~ /^deps=/) {
			n = split(substr($i, 6), a, ",")
			for (j = 1; j <= n; j++) { split(a[j], b, "@"); s = s "+" b[1] "@" substr(b[2], 1, 7) }
		}
		printf "%s ", s
	}' "$1"
}

# Perche' un core non compila, dal suo *-fallito.log: le righe d'errore
# (compilatore, make, patch, cmake, git), il passo di LibreELEC che si e'
# fermato ("FAILURE: ... during make_target") e il comando sotto il primo
# banner "FAILED COMMAND", il piu' interno (con una patch: quello di
# scripts/unpack, non la chiamata a scripts/unpack). Se nessuna riga e' un
# errore riconoscibile, le ultime prima del banner. Nella corsa dell'8/10/2026
# per meta' dei falliti si vedevano solo i banner: un "make: *** No rule to
# make target", una patch gia' entrata upstream ("Reversed (or previously
# applied) patch detected") o un errore di gcc marcato [-Werror=...] non
# contengono "error" o lo contenevano solo dentro "Werror", che si scartava per
# togliere le righe di comando del compilatore. Ora "error" conta solo come
# parola ("error:", "Error 1"); restano fuori le righe di comando (un flag
# " -Werror" o " -Wno-error", non il "[-Werror=...]" in coda a un errore), il
# codice citato da gcc ("  147 |") e i banner. Senza i colori di print_color,
# righe a 180 caratteri.
core_why() {
	local f="$1" plain errs
	plain="$(sed 's/\x1b\[[0-9;]*m//g' "${f}")"
	errs="$(printf '%s\n' "${plain}" \
		| grep -aE '(^|[^A-Za-z_])(error|Error|ERROR)( |:)|FAILED|fatal:|Cannot get|undefined reference|Reversed \(or previously applied\)|hunk ignored|No rule to make target|No such file or directory|cannot stat|command not found|No package .* found|Stop\.$|Killed|Segmentation fault|Illegal instruction' \
		| grep -avE '^ *[0-9]+ \||^ *\| |FAILED COMMAND|^FAILURE: |(^| )-W(no-)?error' | tail -8 || true)"
	{
		if [ -n "${errs}" ]; then
			printf '%s\n' "${errs}"
		else
			echo "(nessuna riga d'errore riconosciuta, le ultime prima del FAILED COMMAND:)"
			printf '%s\n' "${plain}" | awk '/\*+ FAILED COMMAND \*+/ { exit } NF && !/^FAILURE: / { b[++n] = $0 } END { for (i = (n > 6 ? n - 5 : 1); i <= n; i++) print b[i] }'
		fi
		printf '%s\n' "${plain}" | awk '/^FAILURE: / { sub(/^FAILURE: /, ""); print "passo: " $0; exit }'
		printf '%s\n' "${plain}" | awk 'c { print "comando: " $0; exit } /\*+ FAILED COMMAND \*+/ { c = 1 }'
	} | cut -c1-180
}

# Il test di caricamento dei core (tools/rf35h-coretest.c): ogni core aperto
# come lo apre RetroArch (dlopen con tutti i simboli risolti, i 25 retro_*,
# retro_init, retro_deinit), sotto qemu-aarch64, con le librerie dell'albero
# <radice> (il SYSTEM della release, o il sysroot della build dei core) e
# quelle che RetroArch ha gia' caricato: le NEEDED di <retroarch>, precaricate.
# Un core che conta su libm o libstdc++ di RetroArch va, come sulla console;
# uno che chiama glib senza averla fra le sue librerie no (dosbox della v1.4.1:
# compilava, e sulla console non si apriva).
# In <dir>: coretest.txt (una riga per core: ok, avviso, NO), coretest.err, il
# log di ogni core in log/. Un'annotazione per NO (errore) e per avviso. Esce
# 0 se nessun NO, 1 se no; muore se il test stesso non parte.
# CORETEST_CC (aarch64-linux-gnu-gcc), CORETEST_QEMU ("qemu-aarch64 -L
# <radice>"; vuota: sull'host), CORETEST_LOADER (il loader della radice),
# CORETEST_LIBPATH (/usr/lib), CORETEST_TIMEOUT (secondi per core): le prove
# lo fanno girare sull'host, con core finti.
cmd_coretest() {
	local root="${1:?radice aarch64}" ra="${2:?binario di RetroArch}" d="${3:?cartella}" bin pre loader rc l
	local -a run
	shift 3
	[ "$#" -gt 0 ] || die "coretest: nessun core"
	[ -f "${ra}" ] || die "coretest: manca ${ra}"
	mkdir -p "${d}"
	bin="${d}/rf35h-coretest"
	"${CORETEST_CC:-aarch64-linux-gnu-gcc}" -O2 -Wall -I"${O}/tools/libretro" -o "${bin}" "${O}/tools/rf35h-coretest.c" -ldl \
		|| die "coretest: rf35h-coretest non compila (${CORETEST_CC:-aarch64-linux-gnu-gcc})"
	pre="$(readelf -d "${ra}" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
	pre="${pre% }"
	loader="${CORETEST_LOADER:-}"
	if [ -z "${loader}" ]; then
		for l in "${root}/usr/lib/ld-linux-aarch64.so.1" "${root}/lib/ld-linux-aarch64.so.1"; do
			[ -e "${l}" ] && { loader="${l}"; break; }
		done
		[ -n "${loader}" ] || die "coretest: nessun ld-linux-aarch64.so.1 in ${root}"
	fi
	if [ -n "${CORETEST_QEMU+x}" ]; then
		read -r -a run <<< "${CORETEST_QEMU}"
	else
		run=(qemu-aarch64 -L "${root}")
	fi
	run+=("${loader}" --library-path "${CORETEST_LIBPATH:-/usr/lib}")
	[ -z "${pre}" ] || run+=(--preload "${pre}")
	set +e
	"${run[@]}" "${bin}" -t "${CORETEST_TIMEOUT:-300}" -l "${d}/log" "$@" > "${d}/coretest.txt" 2> "${d}/coretest.err"
	rc=$?
	set -e
	if [ "${rc}" -gt 1 ]; then
		cat "${d}/coretest.err" >&2
		die "coretest: il test non e' partito (uscita ${rc})"
	fi
	sed 's/^/  /' "${d}/coretest.txt"
	while IFS= read -r l; do
		case "${l}" in
			NO\ *)     note error "Core $(awk '{ print $2 }' <<< "${l}")" "non si carica: $(sed -E 's/^NO +[^ ]+ //' <<< "${l}")" ;;
			avviso\ *) note warning "Core $(awk '{ print $2 }' <<< "${l}")" "parte, ma chiuso senza contenuto: $(sed -E 's/^avviso +[^ ]+ //' <<< "${l}")" ;;
		esac
	done < "${d}/coretest.txt"
	return "${rc}"
}

# Job cores, dopo la build: i core compilati (compiled.txt) si aprono come in
# RetroArch? cmd_coretest su una radice come quella dell'immagine: /usr/lib
# fatta di link ai file che ogni pacchetto installa (install_pkg/*/usr/lib,
# quello che va nell'immagine), e il RetroArch di install_pkg (le sue NEEDED,
# precaricate). Non il sysroot della toolchain, che serve a compilare: nella
# prima corsa (9/10/2026, run 37979316735) li' mancavano libz, glib e
# libstdc++ (questa sta in toolchain/<target>/lib64), e nemmeno mgba si apriva.
# Chi compila ma non si carica va fra i falliti col perche' (il pin resta,
# l'issue lo dice); un avviso (crash chiuso senza contenuto) e' solo
# un'annotazione. Prima che ci fosse, il pin del dosbox nuovo e' passato e la
# v1.4.1 ne ha uno che non si apre. RF35H_CORETEST=no: senza il test (le prove
# di questo script); CORETEST_ROOT e CORETEST_RA al posto di quelli dell'albero.
cores_load() {
	local out="$1" t="${W}/${TREE_NAME}" root ra p so line why d n=0
	local -a sos=()
	[ -f "${out}/compiled.txt" ] || return 0
	if [ "${RF35H_CORETEST:-yes}" = no ]; then
		cat "${out}/compiled.txt" >> "${out}/built.txt"
		return 0
	fi
	ra="${CORETEST_RA:-$(ls "${t}"/build.*/install_pkg/retroarch-*/usr/bin/retroarch 2>/dev/null | head -1 || true)}"
	[ -n "${ra}" ] || die "test di caricamento: nell'albero manca il RetroArch di install_pkg"
	root="${CORETEST_ROOT:-}"
	if [ -z "${root}" ]; then
		# fuori da ${out}, che diventa un artifact (seguirebbe i link)
		root="${W}/coretest-root"
		rm_tree "${root}"
		mkdir -p "${root}/usr/lib"
		ln -s usr/lib "${root}/lib"
		for d in "${t}"/build.*/install_pkg/*/usr/lib; do
			[ -d "${d}" ] || continue
			# un file che due pacchetti installano: resta il primo (e cp non si
			# ferma per lui)
			cp -Rs --update=none "${d}/." "${root}/usr/lib/" 2>/dev/null || true
			n=$((n + 1))
		done
		[ -e "${root}/usr/lib/ld-linux-aarch64.so.1" ] \
			|| die "test di caricamento: in install_pkg nessun ld-linux-aarch64.so.1 (${n} pacchetti con usr/lib)"
		echo "  radice: usr/lib di ${n} pacchetti di install_pkg, $(find "${root}/usr/lib" -maxdepth 1 -name '*.so*' | wc -l) librerie"
	fi
	for p in $(awk '{ print substr($1, 6) }' "${out}/compiled.txt"); do
		for so in "${t}/target/cores/${p}/"*_libretro.so; do
			[ -f "${so}" ] && sos+=("${so}")
		done
	done
	say "Core: si caricano come in RetroArch? (rf35h-coretest sotto qemu)"
	cmd_coretest "${root}" "${ra}" "${out}/coretest" "${sos[@]}" || true
	[ -n "${CORETEST_ROOT:-}" ] || rm_tree "${root}"
	while IFS= read -r line; do
		p="$(awk '{ print substr($1, 6) }' <<< "${line}")"
		why=""
		for so in "${t}/target/cores/${p}/"*_libretro.so; do
			why="$(awk -v f="${so##*/}" '$1 == "NO" && $2 == f { sub(/^NO +[^ ]+ /, ""); print; exit }' "${out}/coretest/coretest.txt")"
			[ -z "${why}" ] || break
		done
		if [ -n "${why}" ]; then
			echo "== ${p}: compila, ma non si carica come in RetroArch: ${why} [run ${GITHUB_RUN_ID:-?}]" >> "${out}/failed.txt"
		else
			echo "${line}" >> "${out}/built.txt"
		fi
	done < "${out}/compiled.txt"
}

# Job cores: i core dati, al commit nuovo dei loro pin, con lo script di build
# in --build-packages (stesso overlay, stesse verifiche, stessi flag della
# release), sull'albero di una build finita. Una prova, non un'uscita: i .so
# non vanno da nessuna parte, conta che il core compili, perche' allora il
# pin nuovo entra in cores/pins.txt e la prossima release lo costruisce. In
# W/cores una riga per riuscito in built.txt, i falliti in failed.txt con la
# coda del loro log. Esce 0 anche con qualche fallito (restano al commit
# vecchio, nell'issue), diverso da 0 se nessuno e' riuscito.
# Le dipendenze pinnate di un core (cores/pins.txt, "+<pacchetto>": liblcf di
# easyrpg) si puliscono e si compilano prima di lui, al loro commit nuovo: il
# core riesce solo se riescono anche loro, a quel commit, e built.txt le
# nomina (deps=). Il pin del gruppo si sposta tutto insieme (pins-merge).
cmd_cores() {
	local pkgs="${1:?core da compilare}" out="${W}/cores" rc=0 rep p so sha site lakka c7 f d n
	local list="" dl dd dsite dsha dwhy dlog dpins
	: "${W:?}" "${RF35H_CONTAINER:?}" "${RF35H_SYSROOT_VERSION:?}"
	cd "${W}"
	rm -rf "${out}"; mkdir -p "${out}"
	: > "${out}/built.txt"; : > "${out}/failed.txt"
	for p in ${pkgs}; do
		for d in $(deps_of "${p}" | cut -d' ' -f1); do
			case " ${list} " in *" ${d} "*) ;; *) list="${list} ${d}" ;; esac
		done
		list="${list} ${p}"
	done
	list="${list# }"
	say "Core: ${pkgs}"
	[ "${list}" = "$(tr -s ' ' <<< "${pkgs}" | sed 's/^ //; s/ $//')" ] || echo "  con le dipendenze, in quest'ordine: ${list}"
	set +e
	./lakka-rf35h/build-in-docker.sh --build-packages "${list}" --jobs 4 2>&1 \
		| grep --line-buffered -aE '^\[[0-9]+/[0-9]+\] \[(INIT|DONE|FAIL|ACTV|IDLE)|==>|\[!\]|\[x\]|FAILURE|ERROR|^  [a-z0-9_]+ (ok|fallito|assente|compilato)'
	rc=${PIPESTATUS[0]}
	set -e
	docker rm -f "${RF35H_CONTAINER}" >/dev/null 2>&1 || true
	# "|| true": con pipefail un ls senza file fermerebbe lo script qui, prima
	# del messaggio
	rep="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-*-pacchetti.txt 2>/dev/null | head -1 || true)"
	[ -n "${rep}" ] || { note error "Core" "nessun resoconto: la build e' fallita prima dei pacchetti (uscita ${rc})"; die "nessun resoconto dei pacchetti"; }
	lakka="$(git -C "${W}/${TREE_NAME}" rev-parse HEAD)"
	for p in ${pkgs}; do
		# prima le dipendenze: se una non compila (al commit del suo pin) non
		# vale nemmeno il core, e il perche' e' il suo
		dwhy=""; dlog=""; dpins=""
		while read -r d dsite dsha; do
			[ -n "${d}" ] || continue
			dl="$(grep "^${d} " "${rep}" || true)"
			case "${dl}" in
				"${d} ok:"*)
					dd="$(sed -n "s/^${d} ok: .*(install_pkg\/\(.*\))\$/\1/p" <<< "${dl}")"
					case "${dd}" in
						"${d}-${dsha}"|nessuna) dpins="${dpins:+${dpins},}${d}@${dsha}" ;;
						*) dwhy="la dipendenza ${d} e' compilata da install_pkg/${dd:-?}, non dal commit del pin ${dsha:0:7}"; break ;;
					esac ;;
				*)
					dwhy="la dipendenza ${d} (${dsite##*/} ${dsha:0:7}) non compila: ${dl:-non compilata}"
					dlog="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-*-"${d}"-fallito.log 2>/dev/null | head -1 || true)"
					break ;;
			esac
		done < <(deps_of "${p}")
		if [ -n "${dwhy}" ]; then
			{
				echo "== ${p}: ${dwhy} [run ${GITHUB_RUN_ID:-?}]"
				[ -n "${dlog}" ] && core_why "${dlog}"
			} >> "${out}/failed.txt"
			continue
		fi
		if ! grep -q "^${p} ok:" "${rep}"; then
			# un core senza log (assente, senza .so, in piu' versioni) non ne ha
			f="$(ls -t "${W}/${TREE_NAME}"/build-rf35h-*-"${p}"-fallito.log 2>/dev/null | head -1 || true)"
			{
				echo "== ${p}: $(grep "^${p} " "${rep}" || echo 'non compilato') [run ${GITHUB_RUN_ID:-?}]"
				[ -n "${f}" ] && core_why "${f}"
			} >> "${out}/failed.txt"
			continue
		fi
		read -r site sha <<< "$(pin_of "${p}")"
		[ -n "${sha}" ] || { echo "== ${p}: non in cores/pins.txt" >> "${out}/failed.txt"; continue; }
		c7="${sha:0:7}"
		# il .so deve venire dalla build del commit pinnato: install_pkg si
		# chiama <pacchetto>-<PKG_VERSION>, e PKG_VERSION e' il commit del pin
		# (apply.sh). Altrimenti il pin nuovo passerebbe senza che quel commit
		# sia stato compilato.
		d="$(sed -n "s/^${p} ok: .*(install_pkg\/\(.*\))\$/\1/p" "${rep}")"
		if [ "${d}" != "${p}-${sha}" ]; then
			echo "== ${p}: compilato da install_pkg/${d:-?}, non dal commit del pin ${c7}" >> "${out}/failed.txt"
			continue
		fi
		n=0
		for so in "${W}/${TREE_NAME}/target/cores/${p}/"*_libretro.so; do
			[ -f "${so}" ] || continue
			elf_ok "${so}" || { echo "== ${p}: $(basename "${so}") non e' un ELF aarch64 intero" >> "${out}/failed.txt"; continue 2; }
			n=$((n + 1))
		done
		[ "${n}" -gt 0 ] || { echo "== ${p}: nessun _libretro.so" >> "${out}/failed.txt"; continue; }
		echo "core=${p} commit=${sha} site=${site} lakka=${lakka} sysroot=${RF35H_SYSROOT_VERSION} date=$(date -u +%Y%m%d)${dpins:+ deps=${dpins}}" >> "${out}/compiled.txt"
	done
	cores_load "${out}"
	echo; echo "riusciti:"; cut -d' ' -f1,2 "${out}/built.txt" | sed 's/^/  /' || true
	echo "falliti:"; grep '^==' "${out}/failed.txt" | sed 's/^/  /' || true
	# riusciti come <core>@<commit>: con dry_run (o su un altro ramo) il commit
	# provato si legge dall'annotazione, senza scaricare built.txt
	summ "- core riusciti: $(built_list "${out}/built.txt")"
	[ ! -s "${out}/failed.txt" ] || summ "- core falliti: $(grep '^==' "${out}/failed.txt" | sed 's/^== //; s/:.*//' | tr '\n' ' ')"
	note notice "Core" "riusciti: $(built_list "${out}/built.txt"); falliti: $(grep '^==' "${out}/failed.txt" | sed 's/^== //; s/:.*//' | tr '\n' ' ')"
	# il perche' di ogni fallito in un'annotazione: si legge dall'API, il
	# failed.txt solo scaricando l'artifact (la prima corsa completa ne aveva
	# sedici, e da fuori se ne vedevano solo i nomi)
	for c in $(sed -n 's/^== \([^:]*\):.*/\1/p' "${out}/failed.txt"); do
		note warning "Core ${c}" "$(awk -v c="${c}" '/^== / { on = (index($0, "== " c ":") == 1) } on' "${out}/failed.txt")"
	done
	[ -s "${out}/built.txt" ] || { note error "Core" "nessun core compilato"; die "nessun core compilato"; }
}

# Job cores, l'issue dei core che non compilano: l'elenco nuovo da quello
# dell'issue aperta (<old>, i blocchi "== <core>: ..." fra i ``` del corpo;
# vuoto se non ce n'e'), dai falliti di questa corsa (<failed>, failed.txt) e
# dai core provati (<cores>). Un core provato adesso esce se ha compilato e
# rientra coi motivi nuovi se no; uno non provato resta com'era. Prima l'issue
# era solo questa corsa: una prova a mano su tre core che compilavano chiudeva
# l'issue dei 22 ("Tutti i core compilano", run 37832143102, 8/10/2026), e la
# successiva la riapriva con il solo easyrpg. Elenco vuoto: si chiude.
cmd_issue_merge() {
	local old="${1:?elenco vecchio}" failed="${2:?failed.txt}" cores="${3:-}"
	[ -f "${old}" ] || die "manca ${old}"
	[ -f "${failed}" ] || die "manca ${failed}"
	awk -v tested=" ${cores} " '
		/^== / { c = $2; sub(/:$/, "", c); keep = (index(tested, " " c " ") == 0) }
		keep { print }
	' "${old}"
	cat "${failed}"
}

# Job cores, a build finite: in cores/pins.txt entrano i pin nuovi
# (<newpins>, da cores-bump.sh) dei soli core riusciti (built.txt in <d>); gli
# altri restano al commit vecchio. Il commit va sulla punta del ramo com'e'
# adesso, in un worktree a parte, non sul commit da cui e' partito il run: il
# run dura ore, e se intanto sul ramo e' arrivato altro il push di quel HEAD
# veniva rifiutato (non fast-forward), il job falliva e i pin compilati
# andavano persi, issue compresa. Se il ramo si muove fra fetch e push, si
# riprova (3 volte). Un push del GITHUB_TOKEN non avvia altri workflow.
# Un core con dipendenze pinnate ("+<pacchetto>" sotto di lui) si sposta con
# loro, righe del gruppo tutte insieme: il core riuscito le ha compilate a quei
# commit (cmd_cores). Se sul ramo il gruppo ha intanto altre dipendenze, resta.
cmd_pins_merge() {
	local d="${1:?cartella con built.txt}" np="${2:?pins nuovi}" c line cur n try wt wtp cores
	[ -f "${np}" ] || die "manca ${np}"
	: "${DEFAULT_BRANCH:?}"
	cores="$(awk '{ print substr($1, 6) }' "${d}/built.txt" | sort -u)"
	wtp="$(mktemp -d)"; wt="${wtp}/pins"
	for try in 1 2 3; do
		git -C "${O}" fetch -q --no-tags origin "+refs/heads/${DEFAULT_BRANCH}:refs/remotes/origin/${DEFAULT_BRANCH}"
		git -C "${O}" worktree remove --force "${wt}" 2>/dev/null || rm -rf "${wt}"
		git -C "${O}" worktree add -q --detach "${wt}" "refs/remotes/origin/${DEFAULT_BRANCH}"
		n=0
		for c in ${cores}; do
			line="$(pin_block "${c}" "${np}")"
			[ -n "${line}" ] || { echo "  ${c}: non nei pin nuovi, resta"; continue; }
			cur="$(pin_block "${c}" "${wt}/cores/pins.txt")"
			[ -n "${cur}" ] || { echo "  ${c}: non e' piu' fra i pin del ramo, resta fuori"; continue; }
			[ "${line}" != "${cur}" ] || continue
			if [ "$(awk '{ print $1 }' <<< "${line}")" != "$(awk '{ print $1 }' <<< "${cur}")" ]; then
				echo "  ${c}: sul ramo il gruppo e' cambiato ($(awk '{ print $1 }' <<< "${cur}" | tr '\n' ' ')invece di $(awk '{ print $1 }' <<< "${line}" | tr '\n' ' ' | sed 's/ $//')): resta"
				continue
			fi
			PIN_BLOCK="${line}" awk -v c="${c}" '
				skip && /^\+/ { next }
				{ skip = 0 }
				$1 == c && $2 ~ /^https?:/ { print ENVIRON["PIN_BLOCK"]; skip = 1; next }
				{ print }
			' "${wt}/cores/pins.txt" > "${wt}/cores/pins.txt.new"
			mv "${wt}/cores/pins.txt.new" "${wt}/cores/pins.txt"
			n=$((n + 1))
			echo "  ${c}: $(awk '{ printf "%s%s", (NR > 1 ? " " $1 " " : ""), substr($3, 1, 7) }' <<< "${line}")"
		done
		if [ "${n}" -eq 0 ]; then
			echo "  nessun pin da cambiare"
			git -C "${O}" worktree remove --force "${wt}"; rm -rf "${wtp}"
			out "changed=false"
			return 0
		fi
		git -C "${wt}" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
			commit -q -m "cores: ${n} core all'upstream" \
			-m "$(tr '\n' ' ' <<< "${cores}")" \
			-m "Compilati da cores.yml (run ${GITHUB_RUN_ID:-?}) al commit nuovo: la prossima release li ha." -- cores/pins.txt
		if git -C "${wt}" push -q origin "HEAD:${DEFAULT_BRANCH}"; then
			git -C "${O}" worktree remove --force "${wt}"; rm -rf "${wtp}"
			out "changed=true"
			echo "  ${n} pin aggiornati e pushati su ${DEFAULT_BRANCH}"
			note notice "Pin" "${n} core aggiornati in cores/pins.txt: la prossima immagine li avra'"
			return 0
		fi
		echo "  push rifiutato (tentativo ${try} di 3): il ramo si e' mosso, riprovo dalla punta nuova"
		[ "${try}" -lt 3 ] && sleep "${PINS_RETRY_SLEEP:-10}"
	done
	git -C "${O}" worktree remove --force "${wt}" 2>/dev/null || true
	rm -rf "${wtp}"
	fail "Pin" "push dei pin su ${DEFAULT_BRANCH} non riuscito dopo 3 tentativi"
}

case "${1:-}" in
	disk)         cmd_disk ;;
	prepare)      cmd_prepare ;;
	build)        cmd_build ;;
	pack)         cmd_pack "${2:-}" "${3:-}" ;;
	unpack)       cmd_unpack "${2:-}" ;;
	reset)        cmd_reset ;;
	collect)      cmd_collect ;;
	check-dist)   cmd_check_dist "${2:-}" ;;
	version)      cmd_version ;;
	publish)      cmd_publish "${2:-}" ;;
	logs)         cmd_logs "${2:-}" ;;
	ccache-stats) cmd_ccache_stats ;;
	pack-sysroot) cmd_pack_sysroot ;;
	cores-matrix) cmd_cores_matrix "${2:-}" ;;
	cores)        cmd_cores "${2:-}" ;;
	merge-cores)  cmd_merge_cores "${2:-}" "${3:-}" "${4:-}" ;;
	pins-merge)   cmd_pins_merge "${2:-}" "${3:-}" ;;
	issue-merge)  cmd_issue_merge "${2:-}" "${3:-}" "${4:-}" ;;
	coretest)     shift; cmd_coretest "$@" ;;
	*) awk 'NR > 1 && /^#$/ && ++n == 2 { exit } NR > 1' "$0" >&2; exit 2 ;;
esac
