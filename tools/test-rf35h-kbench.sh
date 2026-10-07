#!/bin/bash
# test-rf35h-kbench.sh - prove di tools/rf35h-kbench.sh senza la console.
#
#   ./tools/test-rf35h-kbench.sh [percorso/rf35h-kbench.sh]
#
# perf, systemctl e retroarch sono finti; sysfs, vmstat e meminfo sono file.
# Il retroarch finto scrive quello che riceve (argomenti, config, ambiente),
# "costa" piu' CPU con THP always che con madvise e salva un .srm dove la
# config gli dice; perf finto scrive il tempo di CPU come perf stat -x.
# Lo script gira con la busybox se c'e', come sul device (gli applet della
# busybox prima nel PATH). Il retroarch finto e' uno script: il suo nome di
# processo e' "retroarch" ma argv[0] e' la shell, quindi ne' il pidof della
# busybox ne' pkill -x lo riconoscerebbero come il binario vero; pidof e pkill
# finti lo cercano dalla riga di comando. In piu', "confronta" sui numeri veri
# della console del 7/10/2026.
# Le verifiche sono stringhe che ok() esegue con eval.
# shellcheck disable=SC2034
set -u
K="${1:-$(cd "$(dirname "$0")" && pwd)/rf35h-kbench.sh}"
[ -f "${K}" ] || { echo "non trovo ${K}" >&2; exit 1; }
SH="sh"; command -v busybox >/dev/null && SH="busybox sh"
T="$(mktemp -d)"
PK="$(type -P pkill)"; [ -n "${PK}" ] || { echo "manca pkill" >&2; exit 1; }
RAPAT="^/bin/sh ${T}/bin/retroarch"
trap '"${PK}" -f "${RAPAT}" 2>/dev/null; rm -rf "${T}"' EXIT
mkdir -p "${T}/bin" "${T}/bb" "${T}/out" "${T}/cpufreq" "${T}/cores" "${T}/roms" "${T}/saves/sub" "${T}/states/Finto" "${T}/kb" "${T}/home"
if command -v busybox >/dev/null; then
	for a in $(busybox --list); do
		case "${a}" in sh|ash|busybox) continue ;; esac
		ln -s "$(command -v busybox)" "${T}/bb/${a}"
	done
fi

cat > "${T}/bin/systemctl" <<'EOF'
#!/bin/sh
case "$1" in
	is-active) [ -e "${T_OUT}/ra_attivo" ] ;;
	stop)      rm -f "${T_OUT}/ra_attivo"; echo "stop $2" >> "${T_OUT}/systemctl" ;;
	start)     : > "${T_OUT}/ra_attivo"; echo "start $2" >> "${T_OUT}/systemctl" ;;
	restart)   echo "restart $2" >> "${T_OUT}/systemctl" ;;
esac
EOF
cat > "${T}/bin/pidof" <<'EOF'
#!/bin/sh
[ "$1" = retroarch ] || exit 1
p="$(pgrep -f "${T_RAPAT}" | tr '\n' ' ')"
[ -n "${p}" ] || exit 1
echo "${p% }"
EOF
cat > "${T}/bin/pkill" <<'EOF'
#!/bin/sh
s=""
while [ $# -gt 1 ]; do case "$1" in -9) s="-9" ;; -x) ;; *) break ;; esac; shift; done
[ "$1" = retroarch ] || exit 1
"${T_PK}" ${s} -f "${T_RAPAT}"
EOF
# retroarch finto: 600 fotogrammi al secondo (come RF35H_KBENCH_FPS qui sotto)
cat > "${T}/bin/retroarch" <<'EOF'
#!/bin/sh
[ "${1:-}" = --dormi ] && { sleep 20; exit 0; }
n=$(( $(cat "${T_OUT}/ra_n" 2>/dev/null || echo 0) + 1 )); echo "${n}" > "${T_OUT}/ra_n"
cfg=""; frames=0; rom=""
for a in "$@"; do
	case "${a}" in
		--config=*) cfg="${a#--config=}" ;;
		--max-frames=*) frames="${a#--max-frames=}" ;;
		-*|*_libretro.so) ;;
		*) rom="${a}" ;;
	esac
done
{ printf '%s\n' "$@"; echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-}"; echo "HOME=${HOME}"; } > "${T_OUT}/ra.${n}.args"
cp "${cfg}" "${T_OUT}/ra.${n}.cfg"
mode="$(sed -n 's/.*\[\([a-z]*\)\].*/\1/p; t; p' "${RF35H_THP}")"
case "$(cat "${T_OUT}/ra_modo" 2>/dev/null)" in
	parte-male) echo "[ERROR] Failed to load content" ; exit 1 ;;
	lungo) sleep 30 ;;
esac
case "${mode}" in always) echo $((10000 + 10 * n)) ;; *) echo $((9000 + 10 * n)) ;; esac > "${T_OUT}/ra.cpu"
sleep "$(awk -v f="${frames}" 'BEGIN { printf "%.2f", f / 600 + 0.3 }')"
sd="$(sed -n 's/^savefile_directory = "\(.*\)"$/\1/p' "${cfg}")"
b="$(basename "${rom}")"; echo "scritto dal bench" > "${sd}/${b%.*}.srm"
[ "$(cat "${T_OUT}/ra_modo" 2>/dev/null)" = crash-alla-fine ] && exit 139
exit 0
EOF
cat > "${T}/bin/perf" <<'EOF'
#!/bin/sh
if [ "$1" = bench ]; then
	case "$2 $3" in
		"sched pipe")      echo "     7.500000 usecs/op" ;;
		"sched messaging") echo "     Total time: 0.396 [sec]" ;;
		"syscall basic")   echo "     0.426285 usecs/op" ;;
		"futex hash")      echo "Averaged 934997 operations/sec (+- 0.01%), total secs = 3" ;;
		"mem memcpy")      echo "       681.570312 MB/sec" ;;
	esac
	exit 0
fi
[ "$1" = stat ] || exit 2
shift; out=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--) shift; break ;;
		*) shift ;;
	esac
done
"$@"; rc=$?
{
	echo "# started on finto"; echo
	echo "$(cat "${T_OUT}/ra.cpu" 2>/dev/null || echo 0).50;msec;task-clock;1;100.00;1.0;CPUs utilized"
	echo "<not supported>;;cycles;0;100.00;;"
	echo "<not supported>;;instructions;0;100.00;;"
} > "${out}"
exit "${rc}"
EOF
chmod +x "${T}/bin/"*

echo "[always] madvise never" > "${T}/thp"
echo ondemand > "${T}/cpufreq/scaling_governor"
echo 1296000 > "${T}/cpufreq/scaling_cur_freq"; echo 1296000 > "${T}/cpufreq/scaling_max_freq"
printf 'thp_fault_alloc 10\nthp_fault_fallback 2\nthp_collapse_alloc 1\ncompact_stall 3\npswpout 7\npswpin 1\npgmajfault 4\n' > "${T}/vmstat"
printf 'MemTotal: 747608 kB\nMemAvailable: 300000 kB\nAnonHugePages: 0 kB\nSwapTotal: 373804 kB\nSwapFree: 373804 kB\n' > "${T}/meminfo"
echo 45000 > "${T}/temp"
printf "HOME=%s\nWAYLAND_DISPLAY='wayland-1'\nXDG_RUNTIME_DIR='%s'\n" "${T}/home" "${T}/xdg" > "${T}/ra-env.conf"
printf 'LD_LIBRARY_PATH="/usr/lib"\n' > "${T}/ra-run.conf"
: > "${T}/cores/finto_libretro.so"
ROM="${T}/roms/Gioco (USA) [!].bin"; : > "${ROM}"
echo "originale" > "${T}/saves/Gioco (USA) [!].srm"; echo "originale sub" > "${T}/saves/sub/Gioco (USA) [!].srm"
echo "altro" > "${T}/saves/Gioco (USA) (Rev 1).srm"
echo "stato" > "${T}/states/Finto/Gioco (USA) [!].state2"
cat > "${T}/ra.cfg" <<EOF
config_save_on_exit = "true"
savestate_auto_save = "true"
cheevos_enable = "true"
log_to_file = "true"
savefile_directory = "${T}/saves"
savestate_directory = "${T}/states"
video_vsync = "true"
EOF
cp "${T}/ra.cfg" "${T}/ra.cfg.prima"
: > "${T}/out/ra_attivo"

export T_OUT="${T}/out" T_PK="${PK}" T_RAPAT="${RAPAT}" PATH="${T}/bin:${T}/bb:${PATH}" \
	RF35H_KBENCH_DIR="${T}/kb" RF35H_CPUFREQ="${T}/cpufreq" RF35H_THP="${T}/thp" RF35H_VMSTAT="${T}/vmstat" \
	RF35H_MEMINFO="${T}/meminfo" RF35H_TEMP="${T}/temp" RF35H_RA="${T}/bin/retroarch" RF35H_RA_CFG="${T}/ra.cfg" \
	RF35H_RA_ENV="${T}/ra-env.conf" RF35H_RA_RUNENV="${T}/ra-run.conf" RF35H_CORES="${T}/cores" RF35H_KBENCH_FPS=600
pass=0; fail=0
ok() { if eval "$2"; then pass=$((pass + 1)); echo "  ok    $1"; else fail=$((fail + 1)); echo "  FALLITO $1"; fi; }
thp() { sed -n 's/.*\[\([a-z]*\)\].*/\1/p; t; p' "${T}/thp"; }
kb() { ${SH} "${K}" "$@"; }
echo "script: ${K}  (con ${SH})"

# ---- core: A/B alternato ------------------------------------------------------
kb core ab finto "${ROM}" --thp always,madvise --giri 3 --frames 600 --stato 2 > "${T}/out/core.txt" 2>&1; rc=$?
ok "core: esce con 0" '[ ${rc} = 0 ]'
ok "core: riscaldamento + 3 giri x 2 modalita' = 7 corse" '[ "$(cat "${T}/out/ra_n")" = 7 ]'
ok "core: alternate (giro 1 always, giro 1 madvise...)" '[ "$(grep -c "^  always   giro" "${T}/out/core.txt")" = 3 ] && [ "$(grep -c "^  madvise  giro" "${T}/out/core.txt")" = 3 ] && grep -A1 "always   giro 1" "${T}/out/core.txt" | grep -q "madvise  giro 1"'
ok "core: un file per modalita'" '[ -f "${T}/kb/ab-always.txt" ] && [ -f "${T}/kb/ab-madvise.txt" ]'
ok "core: mediana e giri della CPU, riscaldamento escluso" 'grep -qx "cpu_s_basso 10.04" "${T}/kb/ab-always.txt" && grep -qx "cpu_s_giri 10.02 10.04 10.06" "${T}/kb/ab-always.txt" && grep -qx "cpu_s_giri 9.03 9.05 9.07" "${T}/kb/ab-madvise.txt"'
ok "core: confronto in fondo, madvise meglio sulla CPU" 'grep -qE "^  cpu_s_basso .* meglio$" "${T}/out/core.txt"'
ok "core: memoria del processo letta (Rss da smaps_rollup)" 'grep -qE "^memoria_mb_basso [0-9]+$" "${T}/kb/ab-always.txt"'
ok "core: IPC assente se perf non ha i contatori" '! grep -q "^ipc_alto" "${T}/kb/ab-always.txt"'
ok "core: argomenti a RetroArch" 'a="${T}/out/ra.2.args"; grep -qx -- "--verbose" "${a}" && grep -qx -- "-L" "${a}" && grep -qx "${T}/cores/finto_libretro.so" "${a}" && grep -qx -- "--entryslot=2" "${a}" && grep -qx -- "--max-frames=600" "${a}" && grep -qxF "${ROM}" "${a}"'
ok "core: ambiente del servizio (Wayland, HOME)" 'grep -qx "WAYLAND_DISPLAY=wayland-1" "${T}/out/ra.2.args" && grep -qx "HOME=${T}/home" "${T}/out/ra.2.args"'
ok "core: config di prova senza salvataggi, una sola riga per chiave" 'c="${T}/out/ra.2.cfg"; grep -qx "config_save_on_exit = \"false\"" "${c}" && grep -qx "savestate_auto_save = \"false\"" "${c}" && grep -qx "cheevos_enable = \"false\"" "${c}" && grep -qx "history_list_enable = \"false\"" "${c}" && grep -qx "log_to_file = \"false\"" "${c}" && [ "$(grep -c "^config_save_on_exit" "${c}")" = 1 ] && [ "$(grep -c "^savefile_directory" "${c}")" = 1 ] && grep -qx "video_vsync = \"true\"" "${c}"'
ok "core: .srm del gioco copiati (anche nella sottocartella), non gli altri" 'grep -q "salvataggi del gioco: 2 file copiati da ${T}/saves" "${T}/out/core.txt"'
ok "core: i salvataggi veri non toccati" 'grep -qx originale "${T}/saves/Gioco (USA) [!].srm" && grep -qx "originale sub" "${T}/saves/sub/Gioco (USA) [!].srm"'
ok "core: retroarch.cfg vero non toccato" 'cmp -s "${T}/ra.cfg" "${T}/ra.cfg.prima"'
ok "core: alla fine THP, governor e RetroArch come prima" '[ "$(thp)" = always ] && [ "$(cat "${T}/cpufreq/scaling_governor")" = ondemand ] && [ -e "${T}/out/ra_attivo" ] && grep -qx "stop retroarch" "${T}/out/systemctl" && grep -qx "start retroarch" "${T}/out/systemctl"'
ok "core: cartella temporanea (config e salvataggi di prova) tolta" 'd="$(sed -n "s/^savefile_directory = \"\(.*\)\"$/\1/p" "${T}/out/ra.2.cfg")"; [ -n "${d}" ] && ! [ -e "${d}" ]'
ok "core: condizioni nel file (core, gioco, stato, misura)" 'grep -q "^info_gioco .*(stato 2)$" "${T}/kb/ab-madvise.txt" && grep -qx "info_misura 600 fotogrammi, 3 giri" "${T}/kb/ab-madvise.txt" && grep -qx "info_thp madvise" "${T}/kb/ab-madvise.txt"'

# una sola modalita': un file col nome dato, niente confronto
rm -f "${T}/out/ra_n"
kb core uno finto "${ROM}" --giri 1 --frames 600 > "${T}/out/core1.txt" 2>&1; rc=$?
ok "core senza --thp: la modalita' attiva, un file, niente confronto" '[ ${rc} = 0 ] && [ -f "${T}/kb/uno.txt" ] && grep -qx "info_thp always" "${T}/kb/uno.txt" && ! grep -q " -> " "${T}/out/core1.txt"'

# crash dopo i fotogrammi: la corsa vale
echo crash-alla-fine > "${T}/out/ra_modo"
kb core crash finto "${ROM}" --giri 1 --frames 600 > "${T}/out/core2.txt" 2>&1; rc=$?
ok "core: crash in chiusura dopo i fotogrammi, la corsa vale" '[ ${rc} = 0 ] && grep -q "uscito con 139" "${T}/out/core2.txt"'

# il gioco non parte: si ferma con il log, e rimette tutto
echo parte-male > "${T}/out/ra_modo"
kb core male finto "${ROM}" --giri 1 --frames 600 > "${T}/out/core3.txt" 2>&1; rc=$?
ok "core: gioco che non parte, si ferma e mostra il log" '[ ${rc} != 0 ] && grep -q "corsa non riuscita" "${T}/out/core3.txt" && grep -q "Failed to load content" "${T}/out/core3.txt"'
ok "core: dopo l'errore THP, governor e RetroArch come prima" '[ "$(thp)" = always ] && [ "$(cat "${T}/cpufreq/scaling_governor")" = ondemand ] && [ -e "${T}/out/ra_attivo" ]'

# interrotto a meta' corsa (TERM: un job in background ha SIGINT ignorato)
echo lungo > "${T}/out/ra_modo"; : > "${T}/out/systemctl"
${SH} "${K}" core stop finto "${ROM}" --thp madvise --giri 1 --frames 600 > "${T}/out/core4.txt" 2>&1 &
kp=$!
for _ in $(seq 50); do pgrep -f "${RAPAT}" >/dev/null && break; sleep 0.2; done
sleep 0.5; kill -TERM "${kp}"; wait "${kp}"; rc=$?
sleep 0.3
ok "core interrotto: esce con 130" '[ ${rc} = 130 ]'
ok "core interrotto: RetroArch di prova chiuso" '! pgrep -f "${RAPAT}" >/dev/null'
ok "core interrotto: THP, governor e servizio rimessi" '[ "$(thp)" = always ] && [ "$(cat "${T}/cpufreq/scaling_governor")" = ondemand ] && grep -qx "start retroarch" "${T}/out/systemctl"'
rm -f "${T}/out/ra_modo"

ok "core: core inesistente rifiutato" '! kb core x nessuno "${ROM}" 2>/dev/null'
ok "core: modalita' THP sconosciuta rifiutata" '! kb core x finto "${ROM}" --thp always,sempre 2>/dev/null'
ok "core: nome con caratteri strani rifiutato" '! kb core "a/b" finto "${ROM}" 2>/dev/null'
kb core x finto "${ROM}" --stato 5 > "${T}/out/core5.txt" 2>&1; rc=$?
ok "core: stato che non c'e' rifiutato prima di partire" '[ ${rc} != 0 ] && grep -q "non trovo lo stato 5" "${T}/out/core5.txt" && ! grep -q "^fermo RetroArch" "${T}/out/core5.txt"'
ok "core: lo stato 0 e' <gioco>.state" 'echo s > "${T}/states/Gioco (USA) [!].state" && kb core zero finto "${ROM}" --stato 0 --giri 1 --frames 600 >/dev/null 2>&1 && grep -qx -- "--entryslot=0" "${T}/out/ra.$(cat "${T}/out/ra_n").args"'

# ---- gioco ------------------------------------------------------------------------
: > "${T}/out/systemctl"
"${T}/bin/retroarch" --dormi &
fp=$!
sleep 0.3
kb gioco partita 0 --thp madvise > "${T}/out/gioco.txt" 2>&1; rc=$?
kill "${fp}" 2>/dev/null; wait "${fp}" 2>/dev/null
ok "gioco --thp: rc 0, RetroArch riavviato, THP rimesso" '[ ${rc} = 0 ] && grep -qx "restart retroarch" "${T}/out/systemctl" && [ "$(thp)" = always ]'
ok "gioco: durante la misura THP madvise" 'grep -qx "info_thp madvise" "${T}/kb/partita.txt"'
ok "gioco: contatori, memoria di sistema e di RetroArch" 'grep -qx "compact_stall_delta_basso 0" "${T}/kb/partita.txt" && grep -q "^mem_MemTotal 747608" "${T}/kb/partita.txt" && grep -qE "^ra_memoria_mb_basso [0-9]+$" "${T}/kb/partita.txt" && grep -qE "^ra_cpu_pct [0-9.]+$" "${T}/kb/partita.txt"'
kb gioco senza 0 > /dev/null 2>&1
ok "gioco senza RetroArch acceso: lo dice nel file" 'grep -q "^info_retroarch non letto" "${T}/kb/senza.txt"'

# ---- salva --------------------------------------------------------------------------
: > "${T}/out/systemctl"; : > "${T}/out/ra_attivo"
kb salva s1 --giri 3 --thp madvise > "${T}/out/salva.txt" 2>&1; rc=$?
ok "salva: rc 0, sei prove con mediana e giri" '[ ${rc} = 0 ] && [ "$(grep -cE "_(basso|alto) " "${T}/kb/s1.txt")" = 6 ] && grep -qx "memcpy_gbs_alto 0.6656" "${T}/kb/s1.txt" && grep -qx "pipe_usecs_giri 7.500000 7.500000 7.500000" "${T}/kb/s1.txt"'
ok "salva: THP madvise durante, poi rimesso; RetroArch fermato e riavviato" 'grep -qx "info_thp madvise" "${T}/kb/s1.txt" && [ "$(thp)" = always ] && grep -qx "stop retroarch" "${T}/out/systemctl" && grep -qx "start retroarch" "${T}/out/systemctl"'

# ---- confronta, sui numeri veri della console (7/10/2026) ---------------------------------
cat > "${T}/kb/base.txt" <<'EOF'
info_kernel Linux version 7.2.9 (b@c90b8da6af51) #1 SMP PREEMPT Tue Oct  6 19:08:56 UTC 2026
info_thp always
info_temperatura_inizio 40 C
pipe_usecs_basso 7.666270
pipe_usecs_giri 8.446600 8.171710 7.264550 7.666270 6.480460
messaging_sec_basso 0.396
messaging_sec_giri 0.395 0.393 0.396 0.411 0.401
syscall_usecs_basso 0.426285
syscall_usecs_giri 0.431456 0.426285 0.426030 0.426320 0.426236
futex_ops_alto 934997
futex_ops_giri 866645 935765 936191 934826 934997
dd_mbs_alto 1500.4
dd_mbs_giri 1494.9 1500.4 1500.4 1494.9 1500.4
memcpy_gbs_alto 0.6656
memcpy_gbs_giri 0.6653 0.6652 0.6656 0.6663 0.6661
vm0 thp_fault_alloc 1
EOF
cat > "${T}/kb/mtune.txt" <<'EOF'
info_kernel Linux version 7.2.9 (b@3887da5cc85e) #1 SMP PREEMPT Wed Oct  7 12:44:54 UTC 2026
info_thp always
info_temperatura_inizio 50 C
pipe_usecs_basso 8.837250
pipe_usecs_giri 8.969700 7.866620 8.567200 8.837250 9.318120
messaging_sec_basso 0.389
messaging_sec_giri 0.388 0.391 0.382 0.389 0.391
syscall_usecs_basso 0.428291
syscall_usecs_giri 0.428403 0.427810 0.428584 0.428291 0.427985
futex_ops_alto 932607
futex_ops_giri 933973 934570 932607 929535 932181
dd_mbs_alto 1494.9
dd_mbs_giri 1489.5 1494.9 1478.7 1494.9 1522.7
memcpy_gbs_alto 0.6651
memcpy_gbs_giri 0.6652 0.6645 0.6634 0.6654 0.6651
EOF
cat > "${T}/kb/madvise.txt" <<'EOF'
info_kernel Linux version 7.2.9 (b@c90b8da6af51) #1 SMP PREEMPT Tue Oct  6 19:08:56 UTC 2026
info_thp madvise
info_temperatura_inizio 43 C
pipe_usecs_basso 8.112570
pipe_usecs_giri 8.112570 7.989510 8.596690 9.277240 6.016320
messaging_sec_basso 0.396
messaging_sec_giri 0.396 0.392 0.392 0.398 0.401
syscall_usecs_basso 0.431428
syscall_usecs_giri 0.431437 0.449377 0.430996 0.431428 0.425777
futex_ops_alto 935423
futex_ops_giri 934655 935423 935423 935338 935765
dd_mbs_alto 1500.4
dd_mbs_giri 1500.4 1511.4 1505.9 1500.4 1494.9
memcpy_gbs_alto 0.6972
memcpy_gbs_giri 0.7065 0.7261 0.6972 0.6964 0.6883
EOF
kb confronta base mtune > "${T}/out/c1.txt" 2>&1
v() { awk -v k="$2" '$1 == k { print $NF }' "${T}/out/$1"; }
ok "confronta base->mtune: solo messaging meglio, il resto rumore" '[ "$(v c1.txt messaging_sec_basso)" = meglio ] && for k in pipe_usecs_basso syscall_usecs_basso futex_ops_alto dd_mbs_alto memcpy_gbs_alto; do [ "$(v c1.txt ${k})" = rumore ] || exit 1; done'
ok "confronta: probabilita' per 5 giri contro 5 (0,8%)" 'grep -q "al massimo il 0.8% delle volte" "${T}/out/c1.txt"'
ok "confronta: condizioni affiancate, uguali una volta sola" 'grep -qx "  temperatura_inizio   40 C | 50 C" "${T}/out/c1.txt" && grep -qx "  thp                  always (uguale)" "${T}/out/c1.txt"'
kb confronta base madvise > "${T}/out/c2.txt" 2>&1
ok "confronta base->madvise: solo memcpy meglio, il resto rumore" '[ "$(v c2.txt memcpy_gbs_alto)" = meglio ] && for k in pipe_usecs_basso messaging_sec_basso syscall_usecs_basso futex_ops_alto dd_mbs_alto; do [ "$(v c2.txt ${k})" = rumore ] || exit 1; done'
cat > "${T}/kb/g1.txt" <<'EOF'
info_thp always
compact_stall_delta_basso 28
thp_fault_alloc_delta 217
mem_AnonHugePages 192512 kB
EOF
cat > "${T}/kb/g2.txt" <<'EOF'
info_thp madvise
compact_stall_delta_basso 3
thp_fault_alloc_delta 0
mem_AnonHugePages 2048 kB
EOF
kb confronta g1 g2 > "${T}/out/c3.txt" 2>&1
ok "confronta partite: una misura sola, altri numeri senza giudizio" 'grep -qE "compact_stall_delta_basso +28 +3 +-89.3%  \(una misura sola\)" "${T}/out/c3.txt" && grep -qE "^  mem_AnonHugePages +192512 +2048$" "${T}/out/c3.txt" && grep -qE "^  thp_fault_alloc_delta +217 +0$" "${T}/out/c3.txt"'
ok "confronta: file mancante rifiutato" '! kb confronta base nessuno 2>/dev/null'

echo
echo "${pass} ok, ${fail} falliti"
[ "${fail}" = 0 ]
