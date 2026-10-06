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
	rm -rf "${chk}"
	echo "  ok, $(wc -l < "${d}/cores.txt") core libretro, nessuno vuoto o troncato"

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
	local version publish=false prerelease=false tag rels
	# una release si costruisce sempre da zero: la ripresa riusa pacchetti
	# fatti da un altro commit
	case "${IN_RESUME:-}" in
		'') ;;
		*[!0-9]*) fail "resume_run" "resume_run: un ID di run (numero)" ;;
		*) [ -z "${IN_VERSION:-}" ] || fail "resume_run" "resume_run solo per le build di prova, senza version" ;;
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
			on_default_branch "${GITHUB_SHA:-HEAD}" \
				|| fail "Versione" "${version}: il commit non e' su ${DEFAULT_BRANCH}; da altri rami solo pre-release (v1.1.0-rc1, o la casella prerelease)"
		fi
		if [ "${GITHUB_EVENT_NAME}" = workflow_dispatch ]; then
			tag="$(tag_commit "${version}")" || fail "Versione" "origin non risponde (git ls-remote)"
			[ -z "${tag}" ] || fail "Versione" "il tag ${version} esiste gia': per ricostruirlo si fa push del tag, oppure un'altra versione"
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
	} >> "${GITHUB_OUTPUT:-/dev/null}"
	{
		echo "### ${version}"
		if [ "${publish}" != true ]; then
			echo "Build di prova: nessuna release, l'immagine negli artifact."
		elif [ "${prerelease}" = true ]; then
			echo "Pre-release a fine build: le console non la vedono."
		else
			echo "Release a fine build: \"latest\" (la scaricano le console) se e' la versione piu' alta."
		fi
	} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
	echo "versione ${version}, release ${publish}, pre-release ${prerelease}"
}

# Job release: pubblica i file di <d> (dopo check-dist e le note). Bozza, file,
# poi pubblicata: una console che guarda proprio in quel momento non trova mai
# una release senza update.txt.
cmd_publish() {
	local d="${1:?cartella con i file della release}" pre="${PRERELEASE:-false}" latest=false sha tag rels id draft cur
	: "${VERSION:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${DEFAULT_BRANCH:?}"
	case "${VERSION}" in *-*) pre=true ;; esac
	sha="$(git -C "${O}" rev-parse --verify -q "${GITHUB_SHA}^{commit}")" || fail "Pubblica" "commit ${GITHUB_SHA} non trovato"
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
	# Una release gia' pubblicata con questo tag ferma tutto. Le bozze sono di
	# un tentativo fallito (il job rilanciato, o un run di prima della stessa
	# versione): via, e si rifa' da capo.
	rels="$(release_ids "${VERSION}")" || fail "Pubblica" "elenco delle release illeggibile"
	while read -r id draft; do
		[ -n "${id}" ] || continue
		[ "${draft}" = true ] || fail "Pubblica" "la release ${VERSION} e' gia' pubblicata"
		echo "  bozza ${id} di un tentativo precedente: la cancello"
		gh api -X DELETE "repos/${GITHUB_REPOSITORY}/releases/${id}" > /dev/null
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
	gh release create "${VERSION}" --repo "${GITHUB_REPOSITORY}" --draft \
		--target "${sha}" --title "Lakka RF35H ${VERSION}" \
		--notes-file RELEASE-NOTES.md "${flags[@]}"
	gh release upload "${VERSION}" --repo "${GITHUB_REPOSITORY}" --clobber \
		./*.img.gz ./*.tar update.txt SHA256SUMS
	gh release edit "${VERSION}" --repo "${GITHUB_REPOSITORY}" --draft=false --latest="${latest}"
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
	*) awk 'NR > 1 && /^#$/ && ++n == 2 { exit } NR > 1' "$0" >&2; exit 2 ;;
esac
