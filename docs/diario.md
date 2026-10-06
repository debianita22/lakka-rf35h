# Lakka sull'XiFan RF35H

Overlay per aggiungere il device `rf35h` all'albero **Lakka-LibreELEC, branch
`devel`** (`projects/Rockchip/devices/RK3326`, kernel mainline 7.2.7, Mesa +
Panfrost, Wayland + sway). OpenGL ES di default, Vulkan (PanVK) selezionabile
in RetroArch; IKEMEN GO incluso, in OpenGL ES o OpenGL (vedi "Vulkan" e
"IKEMEN GO" piu' sotto).

Non sostituisce devaOS: prende i pezzi hardware di devaOS — device tree, patch
kernel, i due driver out-of-tree, il loader — e li monta dentro il build system
di LibreELEC.

## Perche' la build dura ore, e come accorciarla

Non sono i driver. `brcmfmac` e compagni sono moduli del kernel: si compilano
in secondi e quello che scorre a schermo non e' quello che costa.

Le ore stanno in **247 core libretro**, e in testa alla lista Lakka mette i
piu' pesanti - `mame`, `dolphin`, `ppsspp`, `panda3ds`, `scummvm`, `fbneo`.
Per una prima immagine, che serve a vedere se il device parte e se pad, audio
e tasto power funzionano, sono zavorra:

    --cores "gambatte fceumm genesis_plus_gx snes9x2010 mgba"

Cinque core piccoli, tutti verificati presenti nella lista di Lakka. Quando
l'immagine gira, si rifa senza `--cores` e si ha tutto.

### E un secondo motivo, meno ovvio

LibreELEC ha **due** livelli di parallelismo che si moltiplicano:

    THREADCOUNT             quanti pacchetti insieme      default nproc
    CONCURRENCY_MAKE_LEVEL  il -j dentro ciascuno         default nproc

Su 16 core il default sono fino a **256 processi di compilazione insieme**.
`CONCURRENCY_LOAD` esiste ma in `pkgbuilder.py` non compare: e' solo un
numero che finisce nel log, non un freno. Se la macchina va in swap la build
rallenta di molto piu' di quanto il parallelismo faccia guadagnare.

    --pkg-jobs <nproc> --jobs 2      oppure    --pkg-jobs 4 --jobs 4

Il prodotto dei due dovrebbe stare vicino al numero di core, non al suo
quadrato.

## Se l'host e' Arch o CachyOS: container

`${TOOLCHAIN}/bin/host-gcc` di LibreELEC non e' un compilatore suo, e' un
wrapper attorno a quello di sistema (`packages/devel/ccache/package.mk`), che
su Arch/CachyOS e' gcc 15+. E' la stessa classe di guai che devaOS ha gia'
incontrato con Buildroot.

    ./lakka-rf35h/build-in-docker.sh --deva ~/devaos/.../boards/rf35h --dry-run
    ./lakka-rf35h/build-in-docker.sh --deva ~/devaos/.../boards/rf35h
    ./lakka-rf35h/build-in-docker.sh --deva ~/devaos/.../boards/rf35h --verify-only
    ./lakka-rf35h/build-in-docker.sh --sh 'ls lakka-rf35h-build/target'

`--verify-only` non costruisce e non tocca l'albero: controlla l'ultima
immagine in `target/` (`verify-image.sh`) e il sorgente del kernel
(`verify-kernel.sh`), gli stessi controlli di fine build. Serve per
un'immagine gia' fatta. `--sh` vale in qualunque posizione, anche insieme a
`--deva` (che allora viene montato su `/deva`).

Dentro il container la cartella di lavoro e' `/work`: i comandi che il build
script suggerisce di incollare (riapplicare l'overlay, `scp`, `dd`) escono
comunque con i percorsi dell'host, che `build-in-docker.sh` gli passa in
`RF35H_HOST_WORK`.

Ubuntu 24.04, gcc 13: abbastanza moderno per Lakka devel, abbastanza vecchio da
non inciampare. Stessa struttura del `build-in-docker.sh` di devaOS.

L'utente nel container prende UID e GID dell'host, e non e' comodita':
`config/options` di LibreELEC comincia con *"Do not build as root. Ever."* e si
ferma se `EUID` e' 0.

`--deva` puo' stare ovunque sull'host - viene montato in sola lettura su
`/deva` e l'argomento riscritto. `--workdir` invece deve restare relativo:
dentro si vede solo la cartella di lavoro. La ccache sta in
`${BUILD}/.ccache`, cioe' dentro l'albero montato, quindi sopravvive da sola
fra un'esecuzione e l'altra.

`checkdeps` non riconoscerebbe CachyOS comunque: legge `ID=` da
`/etc/os-release` e cerca `arch|endeavouros`. Nel container non serve, le
dipendenze le installa il Dockerfile.

## Aggiornare l'overlay senza perdere la build

L'overlay e l'albero di build sono **fratelli**, non uno dentro l'altro:

    ~/build-lakka/
      lakka-rf35h/          <- l'overlay: si puo' buttare e riscompattare
      lakka-rf35h-build/    <- l'albero Lakka: qui c'e' tutto il lavoro

Per prendere una versione nuova dell'overlay:

    cd ~/build-lakka
    rm -rf lakka-rf35h
    tar xzf lakka-rf35h-overlay.tar.gz

Cancellare la cartella dell'overlay e' giusto: scompattare *sopra* la vecchia
lascerebbe indietro i file che nel frattempo sono stati rinominati o ritirati,
e `apply.sh` copia con un glob. (Da questa versione `apply.sh` si difende da
solo: toglie dall'albero i patch `r-*` e `z-*` prima di rimettere i suoi. I
patch di Lakka usano altri prefissi - `0*`, `1000*`, `uvc-*` - quindi non
vengono toccati.)

Quello che **non** va cancellato e' `lakka-rf35h-build/`: dentro ci sono la
toolchain, i sorgenti scaricati e i pacchetti gia' costruiti. Buttarlo
significa ricominciare.

Se l'overlay nuovo cambia cio' che finisce nell'albero, la build si ferma con
"overlay disallineato" e stampa i tre comandi per riapplicarlo:

    rm -f ~/build-lakka/lakka-rf35h-build/.rf35h-applied
    git -C ~/build-lakka/lakka-rf35h-build checkout -- .
    git -C ~/build-lakka/lakka-rf35h-build clean -fd -e sources -e 'build.*' -e target -e '*.log' -e 'build-rf35h-*'

Sorgenti, toolchain, pacchetti costruiti, log e resoconti
`build-rf35h-*` restano; LibreELEC ricostruisce solo cio' che e' cambiato
(i suoi stamp sono sul contenuto). La firma nello stamp (`overlay-sig2`)
copre esattamente cio' che `apply.sh` porta nell'albero - `apply.sh`,
`autoconfig/`, `integration/`, `optional/`, `packages/`, `patches/`, i
permessi dei file e le opzioni che `apply.sh` legge (`--no-core-lto`) - su percorsi
relativi: README, `tools/` e gli altri script non la cambiano, e host e
container danno la stessa firma. Uno stamp della versione precedente
(`overlay-sig:`) va riapplicato una volta.

## Applicare

    ./apply.sh /percorso/Lakka-LibreELEC /percorso/devaos/buildroot-external/boards/rf35h
    cd /percorso/Lakka-LibreELEC
    PROJECT=Rockchip DEVICE=RK3326 ARCH=aarch64 UBOOT_SYSTEM=rf35h make image

Output: `target/Lakka-Rockchip.aarch64-*-rf35h.img.gz`.

Serve il clone del branch giusto:

    git clone --depth 1 -b devel https://github.com/libretro/Lakka-LibreELEC.git

Prima build: alcune ore, ~100 GB di disco.

## Cosa contiene

    patches/linux/            8 patch kernel, tutte a fuzz 0 sulla 7.2.9:
                              r-024/r-025 (rk915 SDIO, MIPI), r-034 (CRU
                              rimesso al risveglio: di ROCKNIX), z-034 (GPLL
                              al risveglio), z-002 (pannello, init dopo
                              l'accensione del DSI), z-036 (accensione del
                              DSI nel log), z-010 (i due
                              device tree xf35h/rf35h, GPU fino a 600 MHz),
                              0000 (batteria rinominata: di Lakka,
                              rigenerata). Nessuna al codec.
    patches/linux-default/    9901 di Lakka (suspend asincrono), rigenerata
    packages/rk915/           driver Wi-Fi SDIO + firmware, patch per 7.0 e 7.2
    packages/rocknix-joypad/  driver joypad ADC multiplexato (of_gpio per 7.2)
    packages/rf35h-utils/     19 script e 18 unit: volume DAC, tasti volume,
                              LED, luminosita', sospensione, idle, zram, USB,
                              caricamento Wi-Fi, crash log, override per-core
                              (overrides/: 10 .cfg portatili + 1 .opt N64),
                              ripiego da Vulkan a gl per RetroArch,
                              aggiornamento dalle release (rf35h-update)
    packages/ikemen-go/       IKEMEN GO 1.0 (3 patch: OpenGL ES su Linux, fix
                              GLES/Vulkan, Vulkan spegnibile), lanciatore
                              rf35h-ikemen, servizio, core ikemen_libretro per
                              Core senza contenuto
    packages/ikemen-screenpack/  screenpack ufficiale con Kung Fu Man
    packages/ikemen-sdl2/     SDL2 completa, statica e privata (per IKEMEN)
    packages/libxmp/          libxmp 4.6.3 statica (musica a moduli di IKEMEN)
    packages/golang-bin/      Go 1.26.2 ufficiale per l'host (niente bootstrap)
    packages/gtasa/           GTA: San Andreas (Android 2.11.311) dai propri
                              APK/OBB: loader, lanciatore, servizio, core per
                              Core senza contenuto
    (re3)                     GTA III (re3) non e' qui: codice senza licenza,
                              pacchetto nel repository privato re3-rf35h,
                              nell'immagine solo con --re3 <cartella>
    packages/openxeenng/      OpenXeenNG (World of Xeen, Rust) come core
                              libretro; sorgente dal suo repository, commit
                              afe41a1
    packages/rust-bin/        Rust 1.95.0 ufficiale per l'host (per openxeen),
    packages/rust-std-aarch64/  e la sua libreria standard per aarch64
    packages/deva_adventures/ Deva's Awesome Adventures 1.0.0, gioco didattico,
                              core senza contenuto; sorgente dal suo
                              repository, commit della 1.0.0
    packages/wpa_supplicant/  2.11 con SAE e PMF: Lakka e' iwd-only, la RK915 no
    autoconfig/               autoconfig RetroArch del pad interno
    patches/retroarch/        8 patch a RetroArch (menu Device Settings; NEON
                              e CPU model; attesa Wi-Fi; passi del volume;
                              toggle dei servizi che non svuota la config;
                              connmanctl che non va in SEGV; lock sulla lista
                              delle reti; salvataggio atomico della config)
    integration/              36 patch all'albero Lakka (kernel 7.2.y, perf,
                              sorgente del kernel tenuto per verify-kernel,
                              sway snello, Vulkan, IKEMEN e giochi nelle options,
                              wlroots senza Vulkan, SDL host, core riparati,
                              stamp di RetroArch, Samba senza condivisioni
                              da root, ...)
    tools/                    generatori delle patch RetroArch, checker (#if, @@),
                              verify-claims.sh (le modifiche dichiarate sono
                              presenti?), verify-image.sh, recupero e reflash,
                              test-rf35h-ikemen.sh (il lanciatore, con finti),
                              test-ikemen-libretro.c (il core, frontend finto),
                              test-rf35h-ra-guard.sh (ripiego Vulkan -> gl),
                              test-verify-tools.sh (verify-kernel, verify-image,
                              --verify-only, firma dell'overlay),
                              rf35h-ikdiag.sh e rf35h-ikbench.sh (misure di
                              IKEMEN sulla console, da ssh)
    optional/                 NON applicate di default: kms-no-compositor (si
                              ferma su EGL, --kms), r-026/r-027 (codec e I2S,
                              non servono con la kconfig di AURKNIX),
                              all-cores (RF35H_ALL_CORES=1)
    apply.sh

## Device tree

Il DTS non viene copiato a mano: `z-010-add-rf35h-dts.patch` aggiunge i due
file e la riga nel Makefile dei dts rockchip, cosi' il kernel lo compila da
solo e il package `linux` lo installa in `usr/share/bootloader`, da dove
`release` lo prende. Verificato: la patch applica, il DTB si compila.

`retrogame_joypad_s2_f1.dtsi` non e' nell'overlay: nel tuo albero non e'
incluso da nessuno. Il nodo attivo e' dentro `rk3326-xifan-xf35h.dts`.

## Adattamenti userspace

Lakka su RK3326 abilita per tutti i device due servizi scritti per l'Odroid
Go Advance. Sull'RF35H sono sbagliati, uno dei due in modo distruttivo.

**Audio.** `odroidgo2-utils` lancia
`headphone-sense 'rk817_int Headphones'`, che alla rimozione delle cuffie fa
`amixer cset name='Playback Mux' SPK`. Due cose non tornano:

- la scheda dell'RF35H si chiama `rk817_ext`, non `rk817_int`, quindi il
  device del jack non verrebbe nemmeno trovato;
- soprattutto, il device tree instrada `HPOL`/`HPOR` sia su `Headphones` sia
  sull'ingresso dell'amplificatore esterno (`Speaker Amp INL`/`INR`). Il mux
  deve restare su **HP** sempre: portarlo su SPK manda l'audio su `SPKO`, che
  su questa board non e' collegato a niente. Risultato: silenzio totale.

Lo speaker qui si spegne con il pin switch della simple-card
(`simple-audio-card,pin-switches = "Internal Speakers"`). `odroidgo2-utils-rf35h.patch` fa due cose: rende i due comandi `amixer`
parametri di `argv[2]`/`argv[3]` (sei righe di C, nessuna copia del
programma), e mette una guardia nel `post_install` di quel package perche' su
`rf35h` non abiliti il proprio servizio.

La guardia sta li' e non in un `rm` dentro `rf35h-utils` per un motivo
preciso: `${INSTALL}` e' l'albero condiviso, ma `scripts/install` installa le
dipendenze prima del dipendente **solo** se `is_sequential_build`, e il
builder multithread gira con `MTWITHLOCKS=yes`. Quel `rm` poteva quindi
eseguire prima che il file esistesse, lasciando attivi entrambi i servizi.

**Tasti volume.** `odroidgoa-volkeys` lancia
`spkeys-service odroidgo3-keys`, che cerca un input device con quel nome
esatto (`EVIOCGNAME`). Sull'Odroid Go quel nome viene dal nodo `gpio-keys`
chiamato letteralmente `odroidgo3-keys`. L'RF35H ha invece un nodo `adc-keys`
su `saradc 2`, e `adc-keys.c` fa `input->name = pdev->name`. Il servizio
`rf35h-volkeys.service` passa i nomi plausibili; `spkeys-service` accetta una
lista.

**Autoconfig joypad: indici verificati sul sorgente.** `udev_joypad.c` di
RetroArch scorre due range:

    for (i = KEY_UP;   i <= KEY_DOWN; i++)  if (bit) button_bind[i] = n++;
    for (i = BTN_MISC; i <  KEY_MAX;  i++)  if (bit) button_bind[i] = n++;

Il primo copre `KEY_UP..KEY_DOWN` (103..108) **prima** di `BTN_MISC`: se il pad
dichiarasse un tasto freccia, tutti gli indici slitterebbero. Questo non lo fa
- i 17 pulsanti del device tree sono tutti `BTN_*` - quindi la numerazione
parte dal secondo ciclo in ordine di codice evdev, e vengono 0..16.

Gli assi: `pad->axes_bind[i] = axes++`, binding **denso**, quindi
`ABS_X/Y/RX/RY` -> 0/1/2/3 e lo stick destro e' 2 e 3.

Il conteggio combacia col device: `adc key cnt = 4, gpio key cnt = 17` nel suo
dmesg. La tabella e' stata poi ricalcolata da DTS + `input-event-codes.h` e
confrontata a macchina con il `.cfg`: 17 pulsanti e 4 assi, zero
disallineamenti.

**Dove va il file.** In
`retroarch_joypad_autoconfig/sources/udev/retrogame_joypad.cfg` e basta:
`scripts/unpack` copia `${PKG_DIR}/sources/*` dentro l'albero di build e il
Makefile a monte installa tutti i `.cfg` di `udev/`. E' lo stesso meccanismo
con cui Lakka aggiunge `GameForceChi-joypad.cfg`. Nessuna patch al
`package.mk`: un `cp` in piu' in `makeinstall_target` avrebbe installato due
volte lo stesso config.

Il pad interno si presenta come `retrogame_joypad`,
vendor `18507`, product `4353`. Gli indici sono l'ordine evdev crescente da
`BTN_MISC`, che e' come `udev_joypad.c` assegna i pulsanti: A=1, B=0, X=2,
Y=3, croce direzionale 13-16 come **pulsanti** (`BTN_DPAD_*`), non come hat.
Lo stick destro e' sugli assi **2 e 3**: RetroArch indicizza gli assi in modo
denso, non per codice evdev, e il driver riporta `ABS_X/Y/RX/RY` senza
`ABS_Z`. La stessa forma di `Nintendo_Switch_Pro_Controller.cfg`, che infatti
usa `+2`.

Nota: `config/joypads/rocknix-singleadc-joypad.cfg` di devaOS non si puo'
riusare qui — e' scritto per `input_driver = "sdl2"`, dove la croce arriva
come hat (`h0up`) e l'ordine dei pulsanti e' quello rimappato da SDL. Con
`udev` non funziona.

## Patch di devaOS escluse, e perche'

| Esclusa | Motivo |
|---|---|
| `r-001-panel-updates` | byte-identica a `0101-panel-updates` di Lakka |
| `r-007-ogs-panel-timings` | stessa cosa di `0107` |
| `r-020-elida-refresh-rates` | stessa cosa di `0120` |
| `r-004-input-drivers` | aggiunge i joypad odroidgo2/3, rgb20s, xu10, gameforce (Lakka li ha gia' in `0003`/`0004`/`0005`) e rinomina la batteria rk817 (Lakka lo fa in `0000`). L'RF35H non usa nessuno di quei driver |
| `g001-imon_pad_ignore_diagonal` | patch a `drivers/media/rc/imon.c`, il ricevitore infrarossi iMON dei case HTPC. `CONFIG_RC_CORE` non e' nemmeno abilitato: quel file non viene mai compilato. Ereditata da LibreELEC via ROCKNIX, datata linux-3.16 |
| `r-005-unigue-gpio-guid` | cambia product/version dell'input device di `gpio_keys.c`. L'RF35H non ha **nessun** nodo `gpio-keys` - joypad e volume sono altri driver - mentre odroidgo3 e rg351v ne hanno uno ciascuno: applicarla cambierebbe l'identita' del **loro** input device senza dare niente a noi |
| `g001-imon_pad_ignore_diagonal` (seconda ragione) | e' **byte per byte identica** a `packages/linux/patches/default/linux-062-imon_pad_ignore_diagonal.patch`, che LibreELEC applica da se'. Tenerla avrebbe significato applicarla due volte |
| `g002-pm-disable-async-suspend-resume` | sostituita: `/sys/power/pm_async` e' una manopola runtime (`power_attr(pm_async)`), quindi la imposta `rf35h-state.service` invece di patchare `kernel/power/main.c` per tutti gli RK3326 dell'albero |
| `r-022-usb-role-switch` | sostituita da il device tree (`z-010`): le stesse due proprieta', ma nel DTS della board invece che in `px30.dtsi`. dwc2 legge `usb-role-switch` dal nodo del controller (`drivers/usb/dwc2/drd.c:179`), quindi funziona uguale senza toccare odroidgo2/3 e rg351m/v |
| `r-0026-phy-rockchip-inno-usb2` | espone `usb_switch_gpio` e `usb_switch_ext` in sysfs sulla phy USB2. Il device tree dell'RF35H non dichiara ne' una switch-gpio ne' un ext supply, e nessuno script di devaOS legge quei file: la patch e' inerte su questa board. Rimetterla e' un `cp` se dovesse servire |
| `r-000-rk3326-dts` | riscrive `px30.dtsi` e va in conflitto con `0012-px30-and-rk3326-odroid-go-more-adjustment` di Lakka: entrambe aggiungono `dfi@ff610000`, `dmc` e `dmc_opp_table`, e il DTB non compila (`ERROR: duplicate_node_names`). **Le sue OPP pero' servono** e sono state recuperate in il device tree (`z-010`) (vedi sotto). Restano fuori l'alias `ethernet0` e le proprieta' Mali vendor (`power_policy`, `power_model@0/1`, `clock-names`, `resets`), che Panfrost non legge |

## USB: ruolo a riposo host

La porta dati e' OTG vera e il DTS base mette `dr_mode = "otg"`. Con dwc2 in
otg e senza role switch il ruolo lo decide il pin ID, che su una USB-C
flottante significa device: **un pad USB non enumererebbe**. il device tree (`z-010`) mette il
ruolo a riposo su host; il gadget resta possibile, semplicemente non e' il
default.

Verificato nel DTB compilato: `dr_mode = "otg"` piu' `usb-role-switch` e
`role-switch-default-mode = "host"` sullo stesso nodo.

## Frequenze: scala piena, per scelta

Con le sole patch di Lakka la scala e' **1008 / 1296 / 1416(turbo)** per la CPU
e un punto solo a **560** per la GPU. La CPU non scende mai sotto 1008 MHz e la
GPU resta fissa.

Non e' una dimenticanza di Lakka: e' la sua `0012-px30-and-rk3326-odroid-go-
more-adjustment.patch` che taglia 600, 816 e 1200 e aggiunge il turbo. La
`r-000` di devaOS fa **la stessa identica cosa** - stessa origine ROCKNIX,
stessi valori. Verificato sui due patch riga per riga, e confermato dal boot
log del device:

    cpufreq: CPU0: Running at unlisted initial frequency: 600000 kHz,
                   changing to: 1008000 kHz

Il loader lascia la CPU a 600, il kernel non la trova in tabella e salta a
1008: su devaOS le frequenze basse non ci sono.

`z-010` le rimette, con i valori esatti che `px30.dtsi` di
mainline 7.0.1 dichiara - ripresi dalle righe che `0012` rimuove, nessun numero
inventato. Risultato sull'RF35H:

    CPU   600(suspend) / 816 / 1008 / 1200 / 1296 / 1416(turbo)
    GPU   200 / 300 / 400 / 480 / 560

E' locale alla board: `rk3326-odroid-go2.dtb` e `rk3326-anbernic-rg351v.dtb`
ricompilati restano a 3 OPP CPU e 1 GPU.

Cosa cambia in pratica: consumo a riposo piu' basso, `ondemand` ha di nuovo
qualcosa su cui scalare, il throttling termico ha margine sotto i 1008 MHz
invece di avere quello come pavimento prima del trip critico a 115 gradi, e
`opp-suspend` torna sui 600 MHz - il kernel ha di nuovo una frequenza definita
per la sospensione.

Se una delle due meta' dovesse dare problemi si toglie da sola: il blocco
`&cpu0_opp_table` e quello `&gpu_opp_table` sono indipendenti.

## Core libretro: sei condizioni morte, da lasciare morte

Diversi core hanno percorsi di build accordati su Cortex-A35 dietro
`[ "${DEVICE}" = "OdroidGoAdvance" ]`. Su `devel` quel device non esiste piu'
(i device Rockchip sono RK3288, RK3326, RK3328, RK3399, RK356X, RK3576,
RK3588), quindi sono codice morto per ogni build RK3326.

Sembra un refuso da correggere in `RK3326`. **Non lo e'**, verificato core per
core ai commit pinnati:

| Core | Perche' va lasciato stare |
|---|---|
| `libretro-pcsx-rearmed`, `libretro-fbneo`, `mupen64plus_next` | il blocco sta dentro `if [ "${ARCH}" = "arm" ]`: irrilevante per una build aarch64 |
| `libretro-snes9x` | `classic_armv8_a35` esiste, ma i suoi flag sono `-marm -mfpu=neon-fp-armv8 -mfloat-abi=hard`: ARM a 32 bit, la compilazione aarch64 non parte |
| `libretro-snes9x2010` | stessa cosa, e in piu' `goa_armv8_a35` non esiste piu' nel Makefile (oggi e' `classic_armv8_a35`) |
| `libretro-scummvm` | `oga_a35_neon_hardfloat` non esiste nel Makefile del backend, e quel Makefile deduce i 64 bit da `findstring 64,$(platform)`: passare quella stringa farebbe una build a 32 bit |

Il ramo `else` attuale (`platform=${TARGET_NAME}`) contiene "64" e funziona.
Questa tabella sta qui perche' la prossima persona che nota il nome stantio
non ci perda un pomeriggio.

## Ordine di applicazione: un glob solo

`scripts/unpack` riga 158 applica
`projects/Rockchip/devices/RK3326/patches/linux/*.patch` con **un solo glob**,
quindi le nostre otto e le diciotto di Lakka si mescolano in ordine ASCII. Le
loro cominciano per cifra, le nostre per lettera minuscola, quindi quasi tutte
le loro vengono prima - tranne una:

    ... 1000-serial2-speed ... r-024 r-025 uvc-bandwidth_cap_param z-001 ...

`uvc-` cade fra `r-025` e `z-001`. Non conta: tocca solo
`drivers/media/usb/uvc/`, le nostre toccano DTS, pannelli, `dw-mipi-dsi` e
`mmc`. Insiemi di file disgiunti, verificato.

Conta invece che `0002-add-input-polldev.patch` di Lakka - quella che
reintroduce `of_gpio.h` - venga prima delle nostre: e' cosi', e il package
`rocknix-joypad` ci fa affidamento (vedi `patches/0002`).

## Le otto patch kernel rimaste, e cosa tocca cosa

Sette su otto riguardano solo questo device. Una tocca un driver condiviso,
`r-025`, ma in modo appropriato anche per gli altri. Nella tabella
c'e' anche `kconfig-pwrkey`, che sta in `integration/` ma tocca gli stessi
device, quindi vale elencarla qui.

| Patch | Ambito |
|---|---|
| `z-010` device tree, il device tree (`z-010`) OPP, il device tree (`z-010`) USB OTG | **solo rf35h**: sono nel DTS della board |
| `z-002` `panel-generic-dsi` (include la vecchia z-003, l'include di hex.h) | nuovo driver, `obj-y`: viene compilato per tutti ma probe solo su chi lo dichiara nel DT. Nessun altro lo fa |
| `r-024` `MMC_CAP2_WIFI_RK912` | tutto dietro la proprieta' `supports-rk912`, che ha solo il nostro `&sdio` |
| `z-001` ST7703 per `xifan,xf35h-panel` | **ritirata** col passaggio alla 7.2.7: era inerte (il DT lega `rocknix,generic-dsi`), e senza la `0101` di Lakka finiva nel punto sbagliato del file. |
| `kconfig-pwrkey` (in `integration/`) | abilita `INPUT_RK805_PWRKEY` per **tutti** gli RK3326. Innocuo: gli altri hanno lo stesso PMIC, e se il tasto non e' cablato li' il driver registra un input device che non emette mai |
| `r-025` fix MIPI | tocca un driver condiviso, ma tutti i pannelli RK3326 dell'albero dichiarano `MIPI_DSI_MODE_LPM`: e' lo stesso caso per tutti. Vedi sotto |

### `r-025`: cosa fa davvero

Sostituisce `dw_mipi_dsi_set_mode(dsi, 0)` con la sola riga
`dsi_write(dsi, DSI_PWR_UP, POWERUP)`. Seguendo il codice, delle quattro
scritture che quella funzione fa, **tre erano gia' state fatte o sono
ridondanti**:

    DSI_PWR_UP = RESET        l'host e' gia' in reset da dw_mipi_dsi_init()
    DSI_MODE_CFG = CMD_MODE   gia' scritto a riga 765 da
                              dw_mipi_dsi_command_mode_config(), chiamata prima
    DSI_LPCLK_CTRL = ...      <-- l'unica differenza vera
    DSI_PWR_UP = POWERUP      quello che r-025 fa direttamente

Resta quindi una cosa sola: **non asserire `PHY_TXREQUESTCLKHS`**, cioe' la
richiesta del clock in high-speed, prima della sequenza di init del pannello.

Il pannello dell'RF35H dichiara `flags=0xe03`, che decodificato e':

    MODE_VIDEO | MODE_VIDEO_BURST | MODE_NO_EOT_PACKET
    | CLOCK_NON_CONTINUOUS | MODE_LPM

`MIPI_DSI_MODE_LPM` significa che la sequenza di init si manda in **low power**.
Mandare comandi LP mentre la corsia di clock viene portata in HS, per giunta
con clock non continuo, e' esattamente il caso in cui i pannelli si rifiutano
di inizializzarsi.

E la richiesta HS non viene persa, solo rimandata: `DSI_LPCLK_CTRL` si scrive
in un punto solo di tutto il file (riga 645, dentro `set_mode`), e
`atomic_enable` chiama `set_mode(MIPI_DSI_MODE_VIDEO)` **dopo** che il pannello
e' inizializzato, subito prima che parta il video.

Quindi non e' un hack: e' un ordine corretto per un pannello LPM su un
controller il cui codice upstream assume di poter chiedere il clock HS prima.

**E non mette a rischio gli altri device.** Avevo scritto che questa e' l'unica
patch che cambia il bring-up DSI per tutti; e' vero, ma tutti e tre i pannelli
degli altri RK3326 dichiarano gli stessi flag:

    panel-elida-kd35t133      LPM | CLOCK_NON_CONTINUOUS | VIDEO | BURST | NO_EOT
    panel-newvision-nv3051d   LPM | CLOCK_NON_CONTINUOUS | VIDEO | BURST | NO_EOT
    panel-sitronix-st7701     LPM | CLOCK_NON_CONTINUOUS | VIDEO | BURST

Sono lo stesso caso. La patch e' appropriata anche per loro.

L'esperimento "toglila e vedi" non serve piu': ora si sa cosa fa e perche'.

## Kernel config: un solo buco, e quale

Diff completo dei simboli attivi: **283** sono a `y`/`m` in devaOS e non in
Lakka. Passati al setaccio, uno solo serviva davvero.

| Simbolo | Esito |
|---|---|
| `INPUT_RK805_PWRKEY` | **serviva** - vedi la sezione sul tasto power |
| `PINCTRL_RK805` | no: questa board non usa nessun GPIO del PMIC. L'enable dell'ampli e' `&gpio3 RK_PA7`, un GPIO del SoC |
| `NVMEM_ROCKCHIP_OTP` | no: ne' il DTS della board ne' le tabelle OPP referenziano celle nvmem |
| `USB_CONFIGFS*`, `USB_F_*`, `USB_U_ETHER` | no: stack gadget, serve al `deva-provision-net` di devaOS. Lakka non lo usa |
| `SND_SOC_ES83xx`, `MAX98357A`, `AK4613`, `BATTERY_CW2015`, `ATH10K_LEDS`, `CLK_RK3576`, HDMI/DP Rockchip | no: hardware di altre board |
| ~200 simboli `INLINE_SPIN_*`, helper DRM, `LRU_GEN`, workaround ARM64 | rumore da versioni di kernel diverse |

Backlight, LED, PWM, rfkill e charger sono **identici** nei due config:

    BACKLIGHT_PWM=y   PWM_ROCKCHIP=y   LEDS_GPIO=y   RFKILL=y   CHARGER_RK817=y

E il resto che serve all'RF35H c'era gia'.

    MMC_DW_ROCKCHIP=y   PWRSEQ_SIMPLE=y     USB_DWC2_DUAL_ROLE=y
    USB_ROLE_SWITCH=y   PHY_ROCKCHIP_INNO_USB2=y
    CFG80211=m          MAC80211=m          (rk915.ko ci si lega)
    DRM_PANFROST=y      VIDEO_ROCKCHIP_RGA=y

`panel-generic-dsi` non ha un simbolo Kconfig: `z-002` lo mette a `obj-y`,
quindi viene sempre compilato. `rk915` e `rocknix-singleadc-joypad` sono
moduli fuori albero, nessun simbolo da abilitare.

I due moduli si autocaricano, non servono voci in `modules-load.d`. Gli alias
nei `.ko` compilati qui:

    rocknix-singleadc-joypad.ko   alias=of:N*T*Crocknix-singleadc-joypadC*
    rk915.ko                      alias=sdio:c*v0296d5348*

`scripts/image` di Lakka lancia `depmod` sul base overlay, dove i due package
installano, quindi `modules.alias` li copre e udev fa il resto.

## Patch kernel indispensabili, non cosmetiche

Due patch di devaOS non sono tuning: senza, il device non funziona. Le ho
compilate contro 7.0.1, non solo applicate.

- `r-024-mainline-linux-hacks-for-rk915` implementa `MMC_CAP2_WIFI_RK912` nel
  core SDIO. E' cio' che da' senso alla proprieta' `supports-rk912` sul nodo
  `&sdio` del tuo device tree: salta il reset di alimentazione, allenta il
  controllo sulla dimensione del CIS e la revisione SDIO, e tratta a parte i
  `SD_IO_RW_DIRECT` in `dw_mmc`. Senza, la RK915 non enumera.
- `r-025-mainline-linux-fix-for-mipi` aggiunge la scrittura `DSI_PWR_UP`
  in `dw-mipi-dsi.c`. Senza, il pannello non si accende.

`drivers/mmc/core/`, `dw_mmc.o` e `dw-mipi-dsi.o` compilano puliti dopo le
patch, zero warning nei file toccati.

## Vulkan: accanto a OpenGL ES, non al suo posto

Lakka lo spegne per tutto il progetto Rockchip (`projects/Rockchip/options`:
`VULKAN="no"`). Per l'RF35H lo riaccende `integration/options-vulkan-ikemen-rf35h.patch`
(`VULKAN="vulkan-loader"`), e da li' a cascata:

    config/graphic      VULKAN_SUPPORT="yes", VULKAN_DRIVERS_MESA="panfrost"
    mesa                -Dvulkan-drivers=panfrost: PanVK (+ vulkan-tools: vulkaninfo, vkcube)
    retroarch           --enable-vulkan, HAVE_VULKAN=1: driver "vulkan" in Driver > Video
    core                nel set di default nessuno cambia renderer: flycast il suo
                        Vulkan lo compila comunque (USE_VULKAN e' ON nel suo CMake),
                        parallel_n64 ha sempre ParaLLEl-RDP (HAVE_PARALLEL=1),
                        mupen64plus_next lo avrebbe solo su Generic, melonds e
                        melondsds non ne hanno: cambia solo la dipendenza da
                        vulkan-loader. Fuori dal default (--all-cores) ppsspp
                        prende -DVULKAN=ON
    retroarch.cfg       video_driver = "gl" come prima: OpenGL ES resta il predefinito

Il kernel non cambia: PanVK usa lo stesso driver DRM `panfrost`.

**Con "gl" cambia una cosa sola, e solo a richiesta.** Il `retroarch.cfg` di
Lakka ha `driver_switch_enable = "true"`: un core che chiede un contesto
Vulkan fa passare RetroArch al driver vulkan per quella partita. Prima la
richiesta falliva, ora va a PanVK. Con le opzioni di default non succede:
parallel_n64 in "auto" apre sempre un contesto GL (Glide64) e flycast chiede
quello preferito dal frontend, cioe' GL.
Succede se in parallel_n64 scegli a mano il plugin "parallel": ParaLLEl-RDP e'
calcolo pesante su Vulkan, non provato sulla G31; se non va, rimetti "auto"
nelle opzioni del core.

**PanVK su questa GPU.** La Mali-G31 e' Bifrost (arch 7). Per Mesa (26.x) il
Vulkan di Bifrost e' "non conforme": il driver si presenta al loader solo con
`PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1` e dichiara Vulkan 1.0 (1.4 solo da arch
10, Valhall CSF). Estensioni che interessano qui, lette nel sorgente
(`panvk_vX_physical_device.c`): dynamic rendering, synchronization2, push
descriptor e multiview ci sono su tutte le arch; geometry shader e
`shaderOutputLayer` no. La variabile la mettono: il drop-in
`retroarch.service.d/rf35h-vulkan.conf` (RetroArch) e
`/etc/profile.d/99-rf35h-vulkan.conf` (shell, per `vulkaninfo`). ROCKNIX fa lo
stesso sull'RK3326 in modalita' panfrost.

**Sulla console (25/9/2026):** `vulkaninfo` vede "Mali-G31 MC1", `apiVersion
1.0`, driver 26.1.0; `vkcube` gira a schermo; **RetroArch in vulkan funziona**.
IKEMEN invece no, e da IKEMEN Vulkan e' stato tolto: vedi "IKEMEN GO".

**Se Vulkan non parte, non si resta al buio.** `retroarch.service` ha
`Restart=always`: un driver video che fallisce all'avvio sarebbe un ciclo di
riavvii a schermo nero. `rf35h-ra-guard` (ExecStartPre/ExecStopPost dello
stesso drop-in) conta le morti entro 30 s dall'avvio con `video_driver =
"vulkan"`: alla seconda di fila rimette `"gl"` in `retroarch.cfg` (file
temporaneo + rename) e lascia `vulkan-fallback-*.txt` in `/storage/rf35h-logs`
con il journal. Uno stop di systemd, un'uscita normale o una morte dopo 30 s
azzerano il conto. Legge `video_driver` come RetroArch: se la chiave e'
ripetuta vale la prima. Provato con finti (`tools/test-rf35h-ra-guard.sh`): 9
casi, compresi il formato senza spazi, la chiave ripetuta e il file assente.

**Sway resta su GLES.** `integration/wlroots-no-vulkan-rf35h.patch` non aggiunge
il renderer Vulkan a wlroots sull'RF35H: RetroArch a schermo intero scavalca il
compositore (direct scanout) e il renderer Vulkan di wlroots vuole `glslang`
sull'host, che nel piano di build arriva solo con vulkan-tools, senza un ordine
garantito rispetto a wlroots.

**Ricompilare quando cambia l'opzione.** `calculate_stamp` hasha la cartella del
package e `PKG_STAMP`, non le options: senza un aiuto, attivare o spegnere
Vulkan su un albero gia' compilato riuserebbe Mesa, RetroArch e i core di
prima. `apply.sh` aggiunge `PKG_STAMP+=" VULKAN=${VULKAN}"` in coda a Mesa,
RetroArch e a ogni core che legge `VULKAN_SUPPORT` (21 package), cosi' anche
`--no-vulkan` (`RF35H_VULKAN=no`) ricompila solo cio' che serve.

Piano di build verificato con `tools/viewplan` di LibreELEC sull'albero
patchato, set di default: mesa, retroarch, ikemen-go e i cinque core che
leggono `VULKAN_SUPPORT` (flycast, mupen64plus_next, parallel_n64, melonds,
melondsds) dipendono da `vulkan-loader`, wlroots no; `golang-bin:host` e i
quattro package di IKEMEN sono nel piano.

## IKEMEN GO

Motore di picchiaduro compatibile MUGEN, versione 1.0.0 (tag del 11/9/2026),
con lo screenpack ufficiale e Kung Fu Man. Sta in **Core senza contenuto**
(Contentless Cores), accanto agli altri giochi che partono senza ROM: si sceglie
*IKEMEN GO*, RetroArch si chiude e torna quando si esce dal menu principale di
IKEMEN.

    /storage/roms/ikemen/            cartella di gioco (condivisa in rete: ROMs/ikemen)
      chars/  stages/  data/select.def   personaggi e stage si aggiungono qui
      save/config.ini                    configurazione di IKEMEN
    /storage/rf35h-logs/ikemen.log       log dell'ultima partita (e ikemen.prev.log)
    /usr/share/ikemen/                   motore e screenpack di fabbrica (sola lettura)

Come funziona (`packages/ikemen-go`):

- **`ikemen_libretro.so`** (`launcher/`) e' un core libretro che non emula
  niente: e' il modo per stare in *Core senza contenuto*, che elenca solo core
  libretro con `supports_no_game` e, col filtro predefinito di RetroArch
  (*Monouso*), `single_purpose`. Entrambi stanno nel suo `.info`, installato
  accanto al core in `/usr/lib/libretro` come fa ScummVM. All'avvio mostra per
  2 s un fotogramma nero e un avviso: il tempo per aprire il Menu rapido
  (Select+Start) e cambiare il renderer nelle **Opzioni del core**. Col menu
  aperto RetroArch non fa girare il core, quindi l'attesa si ferma, e *Chiudi
  contenuto* annulla. Poi esegue `rf35h-ikemen start <renderer>`; se il
  comando fallisce, o RetroArch non viene chiuso entro 15 s, torna al menu con
  un messaggio. Icona: `IKEMEN GO.png` nel tema monochrome di XMB (lo stesso
  di Ozone), ricavata dal logo di IKEMEN.
- **Tempo di gioco.** RetroArch lo registra per il core lanciatore
  (`<playlist>/logs/IKEMEN GO/IKEMEN GO.lrtl`), ma per lui la sessione dura i
  2 s prima dell'avvio. All'uscita di IKEMEN `rf35h-ikemen` ci somma la durata
  vera, e RetroArch al giro dopo rilegge il file e aggiunge i suoi secondi: il
  sottotitolo in *Core senza contenuto* mostra le ore giocate davvero. Il
  file lo aggiorna solo se esiste (log disattivati: niente), leggendo
  `retroarch.cfg` come RetroArch (prima occorrenza, `~` = HOME).
- **`rf35h-ikemen.service`** e' in `Conflicts=` con `retroarch.service`: avviarlo
  ferma RetroArch (che salva la configurazione uscendo), e `ExecStopPost`
  lo riavvia, tranne durante lo spegnimento. `rf35h-ikemen start` fa
  `systemctl --no-block start`, perche' il job non aspetti proprio il processo
  che systemd sta fermando.
- **`rf35h-ikemen`** prepara la cartella di gioco: i file del motore (script
  Lua, stati comuni, shader: devono corrispondere al binario) si
  sovrascrivono quando cambia la versione dell'immagine; quelli dello
  screenpack si copiano solo se mancano, quindi un `select.def` modificato
  resta. Al primo avvio scrive un `config.ini` per la console: 640x480
  (il pannello, a 1:1), schermo intero, VSync, MSAA spento.
- Imposta Wayland (o KMS se sway non c'e'), la mappatura SDL del joypad
  (`external/gamecontrollerdb.txt`, con e senza CRC nel GUID), e
  `GOMEMLIMIT` al 60% della RAM, perche' il GC di Go lavori prima di arrivare
  all'OOM killer.

**Due renderer, OpenGL ES predefinito.** Si scelgono nelle *Opzioni del core*
di IKEMEN GO (Menu rapido, nei 2 s dopo averlo scelto) o dal menu Opzioni >
Video di IKEMEN: e' la stessa chiave (`Video.RenderMode`), e l'opzione del core
mostra quella vera anche se l'hai cambiata dentro IKEMEN (a ogni avvio la
legge da `rf35h-ikemen renderer`).

    opengles  OpenGL ES 3.2  MESA_GLES_VERSION_OVERRIDE=3.2 (Panfrost espone 3.1: manca
                             il geometry shader, che IKEMEN usa solo per le ombre 3D)
    opengl    OpenGL 3.3     MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330

**Vulkan tolto (25/9/2026, dopo la prova sulla console).** PanVK sul Mali-G31
espone Vulkan 1.0; il renderer Vulkan di IKEMEN vuole la 1.3, e con la
versione forzata (`MESA_VK_VERSION_OVERRIDE=1.3`) parte senza errori ("We are
GOOD" nel log) ma lo schermo resta nero, e dalla console non se ne esce. Il
driver non c'entra: `vkcube` e RetroArch in vulkan funzionano. Tolto da tre
parti: dalle opzioni del core; da `rf35h-ikemen` (`renderer vulkan` rifiutato
col motivo, uno stato o un `config.ini` con Vulkan lasciati da una versione
precedente tornano a `opengles`); e da IKEMEN stesso: `rf35h-ikemen` esporta
`IKEMEN_DISABLE_VULKAN=1`, che con la patch *0003* toglie Vulkan dal menu
Opzioni > Video e fa tornare un RenderMode Vulkan a OpenGL ES.

Se `opengl` fa uscire IKEMEN con errore entro 20 s, il lanciatore torna a
`opengles`, riprova una volta e lascia `ikemen-fallback-*.txt`. Uno stop (o lo
spegnimento) nei primi secondi non conta come errore. Le ombre dei modelli 3D
restano spente a ogni avvio: su Mali-G31 non esiste il geometry shader, e con
l'override di versione GL Mesa lo accetterebbe comunque.

**Cosa e' stato cambiato nel motore** (`patches/`, a fuzz 0 sul tag):

- *0001* - il renderer OpenGL ES esisteva solo per Android: ora anche su Linux
  col tag `gles` (le funzioni GL arrivano da SDL/EGL). Dialoghi senza GTK col
  tag `nodialog` (su una console non c'e' un desktop, e GTK non e' in Lakka).
  Il menu Opzioni di IKEMEN elenca solo i renderer compilati.
- *0002* - difetti trovati facendo girare questa build:
  - GLES: le texture di post-processing erano `RGBA8_SNORM` con tipo
    `UNSIGNED_BYTE`, che GLES rifiuta: framebuffer incompleti e
    `GL_INVALID_FRAMEBUFFER_OPERATION` a ogni `glClear`. Ora `RGBA8`.
  - GLES: gli shader esterni (Scanline, HQ2x, HQ4x) non dichiarano la
    precisione, obbligatoria in GLSL ES: non compilavano, e IKEMEN andava in
    panic all'avvio su un puntatore nullo. Ora hanno l'intestazione giusta, e
    uno che non compila viene saltato.
  - Vulkan: i limiti della GPU (allineamento degli uniform buffer, anisotropia)
    si leggevano solo per una GPU discreta; su una integrata restavano a 0.
  - Vulkan: lo scissor "senza finestra" arrivava come rettangolo di 131072x131072.
    Legale, ma lavapipe lo riduce a vuoto: gli stage a 8 bit scalati erano
    neri. Ora e' limitato al render target. PanVK su Bifrost interseca gia' lo
    scissor col viewport, quindi sull'RF35H non si sarebbe visto; la correzione
    e' giusta comunque.
- *0003* - `IKEMEN_DISABLE_VULKAN` (qualunque valore non vuoto): Vulkan sparisce
  dal menu Opzioni > Video (`isRendererAvailable` della 0001 risponde no), e un
  RenderMode "Vulkan 1.3" parte in OpenGL ES 3.2 (o 3.3 se ES non e'
  compilato), dicendolo nel log. Senza la variabile non cambia niente.
  Provata qui (x86, Xvfb, llvmpipe/lavapipe): con la variabile e RenderMode
  Vulkan parte in GLES e disegna; senza, Vulkan come prima; da Lua
  `isRendererAvailable("Vulkan 1.3")` risponde false con la variabile e true
  senza. Le tre patch applicano a fuzz 0 sul tag, in ordine, e danno
  esattamente l'albero compilato e provato.

**Build.** `ikemen-go` compila il motore con il Go ufficiale 1.26.2
(`golang-bin:host`, binario con sha256 fissato: il `go:host` di LibreELEC
vorrebbe un Go >= 1.24.6 sull'host per il bootstrap, e le immagini Docker di
Lakka hanno 1.21-1.24), `GOEXPERIMENT=arenas` come i rilasci ufficiali, tag
`egl gles nodialog`. SDL2 completa (Wayland, KMS, EGL/GLES/GL, Vulkan, ALSA,
joystick) e libxmp sono **statiche e private** (`ikemen-sdl2`, `libxmp`):
Lakka ha solo SDL2_input, senza video, installata come `libSDL2-2.0.so.0`, e
una SDL2 completa con lo stesso nome l'avrebbe sostituita. FFmpeg e' quello di
Lakka (8.1). Sorgenti fissati per commit (motore, screenpack, libxmp: LibreELEC
li scarica con git). I moduli Go li scarica `go build` al momento della build
(proxy.golang.org), verificati da `go.sum`: serve la rete anche in quella fase.
`--no-ikemen` (`RF35H_IKEMEN=no`) fa un'immagine senza.

Licenze: motore MIT; screenpack CC BY 3.0 per grafica e suoni, CC BY-NC 3.0 per
i font Elecbyte (uso non commerciale). I testi sono in `/usr/share/ikemen`.

**Verificato qui**, su x86_64 (il device non l'ho):

- motore patchato compilato contro FFmpeg 8.1 (API di reisen compatibile), e
  **cross-compilato per arm64** con SDL2 e libxmp statiche: ELF aarch64, dipende
  solo da libEGL, dalle librerie FFmpeg 8.1 (`libavcodec.so.62` & co.), libm e
  libc; sotto qemu-aarch64 parte e si ferma, come deve, dove manca una GPU;
- fatto girare con Mesa software (llvmpipe/lavapipe) sotto Xvfb con tutti e tre
  i renderer, una partita KFM contro KFM su tre stage: nessun errore GL con
  `MESA_DEBUG=1`, nessun errore dal validation layer Vulkan, shader Scanline e
  HQ2x funzionanti su GLES e Vulkan;
- il lanciatore vero con il binario vero (x86, Xvfb, Mesa software): GLES;
  stato `vulkan` e `config.ini` con "Vulkan 1.3" lasciati da una versione
  precedente: parte in GLES con `IKEMEN_DISABLE_VULKAN=1` e disegna (la
  demo del titolo); `renderer vulkan` rifiutato col motivo.
  `tools/test-rf35h-ikemen.sh`: 34 casi con finti
  (primo avvio, aggiornamenti, config CRLF, stop, ripiego, spegnimento,
  Vulkan rifiutato e Vulkan lasciato da una versione precedente, `start` dal
  core, tempo di gioco);
- il core lanciatore: compila senza warning con `-Wall -Wextra -Werror` per
  x86_64 e per aarch64 (Cortex-A35) ed esporta solo le 25 funzioni `retro_*`;
  `tools/test-ikemen-libretro.c` lo carica con un frontend finto, 18 casi
  (attesa di 2 s, renderer cambiato dal Menu rapido, allineamento allo stato,
  niente Vulkan fra le opzioni nemmeno col loader presente, stato o valore
  `vulkan` vecchi che non passano, opzioni legacy, comando che fallisce,
  RetroArch che non si chiude, SIGCHLD ignorato, lanciatore assente,
  RetroArch che risonda il core gia' avviato);
- il core con **RetroArch vero** (questa catena di patch, compilata qui, driver
  null): lo carica senza contenuto, registra le opzioni (`SET_CORE_OPTIONS_INTL`),
  mostra gli avvisi in italiano, allinea il renderer allo stato; con stato e
  `IKEMEN GO.opt` a `vulkan` di una versione precedente, dopo l'attesa esegue
  `start opengles` e riscrive l'opzione a `opengles`; a un TERM come quello
  di systemd esce con codice 0 e salva `IKEMEN GO.opt`. La cache `core_info.cache` che scrive riporta
  `supports_no_game` e `single_purpose` veri: e' la condizione del filtro
  *Monouso* di *Core senza contenuto*. Il `.lrtl` che scrive, aggiornato da
  `rf35h-ikemen` e riletto al giro dopo, somma le due durate;
- RetroArch: la 1003 e' di nuovo quella di prima di IKEMEN, byte per byte (i
  generatori sono tornati alla loro versione), quindi Impostazioni
  dispositivo non cambia; l'intera catena di patch, applicata come fa
  LibreELEC (ordine alfabetico in locale C, fuzz di default, 99 e 999 di Lakka
  comprese), compila con Wayland, KMS, GLES3 e Vulkan accesi.

**Sulla console** (25/9/2026) gira in OpenGL ES e OpenGL, ma lento: le misure
sono in fondo, "IKEMEN sulla console: misure".

## Il blob Mali non viene costruito

`GRAPHIC_DRIVERS="mali panfrost"` sembra mettere il driver proprietario
accanto a Mesa. Non lo fa, verificato da tre lati:

- `config/graphic` non gestisce affatto la stringa `mali`: gestisce solo
  `panfrost`, che aggiunge il driver Gallium;
- nessun package dipende da `libmali` per noi. Gli unici che lo nominano sono
  `mupen64plus_next` e `retroarch`, e ramificano su `OPENGLES = "libmali"` -
  il nostro e' `"mesa"`;
- `MALI_FAMILY="g31"` lo leggono solo `libmali` (non costruito) e il core
  `vircon32`, che con g31 prende correttamente il ramo panfrost.

Se il blob fosse stato costruito avrebbe installato `libEGL`/`libGLESv2` in
conflitto con quelle di Mesa. Non succede.

## Verificato e a posto, nessun intervento

- **Mali vs Mesa.** `GRAPHIC_DRIVERS="mali panfrost"` sembra mettere il blob
  accanto a Mesa, ma `config/graphic` non gestisce affatto la stringa `mali`:
  solo `panfrost`, che aggiunge il driver Gallium. Con `OPENGLES="mesa"` lo
  stack e' Mesa/Panfrost puro, come devaOS.
- **Termica.** Trip passivi a 70 e 85 gradi, critico a 115, `cpu0` come
  cooling device: mainline px30 standard, compatibile con la scala nuova.
- **Tasti volume e RetroArch.** `spkeys-service` scrive su un socket UNIX
  `retroarch/cmd`, non sulla porta TCP: `network_cmd_enable = "false"` nel
  config di Lakka non c'entra e non va toccato.
- **usb-modeswitch-RK3326.** Regole udev per dongle Wi-Fi USB RTL8812BU e
  MT7601. Innocue qui, utili se ne colleghi uno.
- **Splash.** `splash-640x480.png` esiste gia' nel target e corrisponde al
  pannello.
- **Espansione di `/storage`.** `scripts/mkimage` riga 102 crea
  `.please_resize_me` nel percorso comune, lontano dalle nostre modifiche, e
  `fs-resize.service` al primo avvio fa `parted resizepart 2 100%` piu'
  `resize2fs`. Senza, resteresti con i 32 MB di `STORAGE_SIZE` di default.
- **Rumble.** Funziona senza aggiungere niente: il device tree ha
  `rumble-gpio = <&gpio3 RK_PA6>`, il driver fa `input_set_capability(EV_FF,
  FF_RUMBLE)` e `input_ff_create_memless()`, Lakka ha `INPUT_FF_MEMLESS=y`, e
  `udev_joypad.c` di RetroArch e' - parole loro - "the only Linux driver which
  can support joypad rumble". Il dmesg del device conferma: "has gpio rumble".
  L'autoconfig non deve dichiarare nulla.
- **Combo del menu.** Lakka mette `input_menu_toggle_gamepad_combo = "4"` per
  RK3326, che nell'enum di RetroArch e' `INPUT_COMBO_START_SELECT`. Nessuna
  collisione con L1+volume: i tasti volume sono `adc-keys`, un altro input
  device, e RetroArch non li vede come pulsanti del pad. Restano due modi di
  aprire il menu: il pulsante F (`input_menu_toggle_btn = "10"`) e Start+Select.
- **Ripristino ALSA via udev.** `90-alsa-restore.rules` lancia `soundconfig`
  quando compare la scheda. Sulla nostra non fa niente, ma per un pelo: prova
  `amixer sset 'Internal Speaker' 0% mute` - **singolare**, mentre il nostro
  controllo e' `Internal Speakers`. `sset` usa il nome esatto dell'elemento,
  quindi non matcha e fallisce in silenzio. Nemmeno `Speaker` o `Playback`
  esistono sulla nostra scheda. In piu' i nostri comandi usano `cset name=`
  con il nome esatto del kcontrol, che salta del tutto il mixer "simple", e
  `rf35h-audio.service` gira a `multi-user.target`, cioe' dopo la regola udev.
  Se un giorno il nome del widget nel DT diventasse singolare, qui si
  litigherebbe.
- **Audio.** `PULSEAUDIO_SUPPORT="no"` nelle opzioni di Lakka e
  `audio_driver = "alsathread"` con `audio_device` vuoto: RetroArch va su ALSA
  diretto, scheda di default. La nostra e' l'unica, `0 [rk817ext]`.
- **`librga`.** Gli unici consumatori erano i due `package.mk` di RetroArch, e
  per `rf35h` la dipendenza e' tolta: non viene costruito.

## L1+volume per la luminosita'

Il combo attraversa due device: `vol+`/`vol-` sono `adc-keys` (saradc 2),
Select e' sul joypad. Due conseguenze:

- un ascoltatore nuovo accanto a `spkeys-service` non basta: L1+vol+
  alzerebbe **sia** la luminosita' **sia** il volume, perche' il servizio
  esistente continuerebbe a mandare `VOLUME_UP` a RetroArch;
- `spkeys-service` pero' accetta gia' una lista di nomi e apre fino a 8 device,
  quindi legge entrambi senza modifiche.

`eventservice-modifier-rf35h.patch` aggiunge tre opzioni, e senza quelle il
programma si comporta esattamente come prima - il servizio dell'Odroid Go non
cambia di una virgola:

    spkeys-service [--mod <codice>] [--mod-up <cmd>] [--mod-down <cmd>] <device>...

Col modificatore premuto il tasto esegue il comando e a RetroArch non arriva
niente. La ripetizione tenendo premuto rispetta `REPRESS_MS` (350 ms): al ritmo
del poll, 100 ms, la luminosita' salterebbe da un estremo all'altro in mezzo
secondo.

**Due bug trovati strada facendo, e il secondo si sentiva.**

`gettimems()` faceva `tv_sec + tv_nsec/1000000`, cioe' secondi piu' un resto
0..999: la differenza fra due letture non era un tempo. Corretto in
`tv_sec * 1000 + tv_nsec/1000000`.

Quel valore finiva in `longpressed`, che veniva calcolato e **poi ignorato**:
il ciclo di ripetizione mandava il comando a ogni giro di poll. Risultato: ogni
singolo tap del volume mandava `VOLUME_UP` **due volte** - una alla lettura
dell'evento e una subito dopo dal ciclo di ripetizione, prima ancora del
rilascio. Due passi di volume per pressione, su tutti gli RK3326 di Lakka.

Ora la ripetizione parte dopo `REPRESS_MS`, che e' quello che il nome della
costante e il commento dicono da sempre. Misurato sul programma vero: un tap
manda un comando, due secondi di pressione ne mandano cinque (~350 ms),
non venti.

## Il joypad: driver, DT e autoconfig verificati insieme

**Le proprieta' che il driver legge dal DT.** Quindici in tutto; il nostro DTS
ne dichiara undici. Le quattro assenti sono innocue, controllate nel sorgente:
`linux,input-type` ha default esplicito `EV_KEY`, `rumble-boost-weak/strong`
si leggono solo dentro `if (joypad->has_rumble)`, e `joypad-bustype` finisce in
una variabile inizializzata a `BUS_HOST`.

**L'identita'.** RetroArch non filtra, assegna un punteggio
(`task_autodetect.c`, `input_autoconfigure_get_config_file_affinity`):
VID+PID valgono 30, il nome 20. Combaciamo su entrambi:

    DTS joypad-vendor  = <0x484B>  ->  18507  = cfg input_vendor_id
    DTS joypad-product = <0x1101>  ->   4353  = cfg input_product_id
    DTS joypad-name    = "retrogame_joypad"   = cfg input_device

**Gli indici.** Ricalcolati da zero sul sorgente al commit che Lakka costruisce
(`69a4f0ea`, `udev_joypad.c` righe 235-249): prima `KEY_UP..KEY_DOWN`, poi
`BTN_MISC..KEY_MAX`. Questo device non ha codici nel primo intervallo, quindi
l'enumerazione parte da `BTN_MISC` e i diciassette codici del DTS cadono in
ordine numerico. Confrontati uno per uno con il `.cfg`: **17 su 17**.

Resta vero che nessuno li ha ancora visti funzionare su hardware, ma non sono
piu' dedotti: sono calcolati dalle stesse due fonti che il device usera'.

## Ogni driver del device tree e' nel config

Controllati tutti i 69 `compatible` del DTB compilato contro
`linux.aarch64.conf`: 27 driver rilevanti, **tutti presenti**. Due sono moduli
(`CONFIG_KEYBOARD_ADC=m` per i tasti volume e
`CONFIG_SND_SOC_ROCKCHIP_I2S_TDM=m`), caricati da udev per modalias.

I nostri due moduli out-of-tree seguono la stessa strada, verificata sui `.ko`
compilati:

    rocknix-singleadc-joypad   alias=of:N*T*Crocknix-singleadc-joypad
    rk915                      alias=sdio:c*v0296d5348*  e  *d5347*

E finiscono in `kernel-overlays/base/lib/modules/<kver>/`, che e' esattamente
l'albero su cui `scripts/image` riga 247 fa girare `depmod`. Costruito →
installato → indicizzato → caricato.

## RetroArch: un valore tarato sull'OGA

`packages/lakka/retroarch_base/retroarch/package.mk` righe 196-202, per RK3326
- il commento dice "HARDKERNEL OdroidGoAdvance or compatible devices":

    xmb_layout = "2"
    input_menu_toggle_gamepad_combo = "4"      (Start+Select)
    menu_widget_scale_auto = "false"
    menu_widget_scale_factor = "2.250000"

I primi due vanno bene anche a noi. Il quarto e' tarato sui **480x320**
dell'OGA. RetroArch scala i widget dall'altezza dello schermo (riferimento
1080), e il nostro pannello e' 640x480 sullo stesso 3.5":

    OGA    320/1080 x 2.25 = 0.667
    RF35H  480/1080 x 1.50 = 0.667

`retroarch-no-go2-rf35h.patch` ora mette **1.5** per rf35h. Lasciato a 2.25,
notifiche e widget sarebbero una volta e mezza piu' grandi del voluto.

Controllato anche il resto: sway non ruota l'output (`output * bg ... fill`,
niente `transform`), `video_rotation = "0"`, e nessuno script, regola udev o
unit fa riferimento all'OGA a parte i cinque file gia' gestiti dall'overlay.

Un dettaglio che gioca a favore: per RK3326 Lakka mette
`cpu_main_gov = "ondemand"` e `cpu_scaling_mode = "1"`, cioe' e' RetroArch a
governare la frequenza. Con la scala tagliata a 1008/1296/1416 `ondemand` non
aveva quasi niente su cui lavorare; con quella piena si'.

## Audio: un servizio che poteva morire per sempre

La prima versione di `rf35h-audio.service` aveva
`ExecStartPre=amixer cset name='Playback Mux' HP`. Girava **prima** che
`headphone-sense` aspettasse la scheda audio: se la scheda non era ancora su,
`amixer` falliva, `ExecStart` non partiva, `Restart=on-failure` riprovava ogni
100 ms e dopo cinque tentativi in dieci secondi systemd marcava l'unita'
`failed` in modo permanente. Niente audio, e niente che riprovasse.

Ora il Mux viaggia dentro i due comandi che `headphone-sense` esegue: li
lancia dopo aver trovato il device del jack, che e' creato dalla stessa scheda,
quindi a quel punto `amixer` funziona. Viene applicato subito allo stato
iniziale (`EVIOCGSW`) e a ogni transizione. `RestartSec=10` e
`StartLimitIntervalSec=0` su questo e su `rf35h-volkeys`: se qualcosa va storto
meglio riprovare ogni dieci secondi che smettere.

Il default del driver e' comunque HP (enum `{"HP", "SPK"}`, indice 0), quindi
anche nel caso peggiore il Mux parte giusto. Verificato in `rk817_codec.c`.

## Servizi: chi aspetta e chi no

`headphone-sense` e `spkeys-service` cercano il loro device e **riprovano ogni
dieci secondi** finche' non lo trovano, quindi `rf35h-audio` e `rf35h-volkeys`
non hanno bisogno di `After=` - ed e' anche l'ordinamento che ha il servizio
originale dell'Odroid Go, che funziona.

`rf35h-state` era diverso: `Type=oneshot`, gira una volta sola. Se partiva
prima che il backlight avesse fatto probe, `rf35h-brightness` usciva 1, e con
`Type=oneshot` **un ExecStart fallito impedisce ai successivi di partire** -
quindi niente luminosita' e nemmeno i LED. Il probe dei device e' asincrono e
`multi-user.target` non lo garantisce.

Ora i due script aspettano che il loro sysfs compaia (fino a 15 s, regolabile
con `RF35H_WAIT`) e in `--restore` non trattano l'assenza come errore; il
servizio ha `-` davanti a entrambi gli ExecStart. Verificato con un backlight e
un trigger LED che compaiono dopo due secondi: vengono presi. L'uso
interattivo invece continua a fallire subito, senza attese.

## Hotkey: preso dai device simili di Lakka

Gli altri handheld RK3326 in Lakka - GameForceChi, GO-Advance, RG351MP -
definiscono tutti un livello hotkey nel loro autoconfig. Il nostro non ce
l'aveva, e senza quello **su un handheld il menu di RetroArch non si apre e da
un gioco non si esce**: il toggle di default e' F1 su tastiera.

Il modificatore e' **Select**, indice 8:

    Select + Start     menu
    Select + R3        esci dall'emulatore
    Select + R1 / L1   salva / carica stato
    Select + Dx / Sx   slot successivo / precedente
    Select + R2        avanti veloce (tenendo premuto)
    Select + L2        rewind
    Select + X         screenshot

### Perche' non il tasto F

Il primo tentativo l'aveva messo su `BTN_MODE`, indice 10, il "tasto F". Poi
ho letto il commento che gli sta sopra nel device tree:

    this sw11 entry is SPECIAL, most [...] devices do not have this physical
    button but for the sake of keeping compatibility with ES and retroarch,
    this phantom button and offset will allow existing userspace programs to
    work without doing any new remapping

E' un **pulsante fantasma**: sta nel device tree solo per tenere allineata la
numerazione con gli altri device. Se sull'RF35H non esiste fisicamente,
legarci il menu significa non poterlo aprire - cioe' esattamente il problema
che il livello hotkey doveva risolvere.

Nota che l'autoconfig aveva gia' `input_menu_toggle_btn = "10"` da prima:
quel menu, se il pulsante non c'e', non si e' mai potuto aprire.

Sull'RF35H un pulsante F fisico **non c'e'**: oltre a D-pad, ABXY, L1/L2/R1/R2,
Select, Start e i due click degli stick ci sono solo power e reset. Il power e'
il tasto del PMIC, un input device a parte che gestisce logind; il reset non
compare nel device tree - e' una linea hardware verso il PMIC. Nessuno dei due
e' utilizzabile qui, quindi Select non e' un ripiego: e' l'unica scelta.

E costa meno di quanto sembri. RetroArch non toglie subito il tasto al gioco:

    if (hotkey premuta) {
       if (block_counter < input_hotkey_block_delay) block_counter++;
       else                                          BLOCK_LIBRETRO_INPUT;
    }

`DEFAULT_INPUT_HOTKEY_BLOCK_DELAY` e' **5**, cioe' cinque poll, un frame
ciascuno: circa 83 ms a 60 fps. Una pressione breve di Select - l'uso normale
dentro un gioco - arriva al core lo stesso. Il blocco scatta solo tenendolo
premuto, che e' esattamente quando stai facendo una hotkey.

Nessun conflitto con L1+volume per la luminosita': quello lo gestisce
`spkeys-service` leggendo direttamente gli evdev, RetroArch non c'entra.

## Tre strumenti sul device

`rf35h-utils` installa tre script in `/usr/bin`, sulla falsariga di
`gpicase_safeshutdown` di Lakka (`scripts/` + `makeinstall_target`).

**`rf35h-diag`** - lo stato del port in un colpo solo. Non e' un dump generico:
ogni sezione corrisponde a una cosa che questo overlay da' per vera, quindi se
qualcosa non torna si vede subito. Al primo boot e' il primo comando da dare:

    rf35h-diag > /storage/diag.txt

**`rf35h-brightness`** - la retroilluminazione, che Lakka su RK3326 non
espone affatto (`odroidgoa-volkeys` fa solo il volume) e che questo device non
puo' regolare da tastiera, avendo come soli `adc-keys` vol+ e vol-.

    rf35h-brightness          50%  (128/255, backlight)
    rf35h-brightness 60
    rf35h-brightness +10
    rf35h-brightness -10

Minimo 5%: a zero lo schermo e' spento e il device sembra morto. Il valore
viene salvato in `/storage/.config/rf35h` e rimesso al boot.

**`rf35h-led`** - i LED. Sul device ce ne sono di due tipi e lo script copre
entrambi, perche' per chi lo usa sono "i LED": gli stick, sul microcontrollore
di ttyS2, e i due `gpio-leds` dei pulsanti (`/sys/class/leds/red` e `/blue`).

Su quello rosso `--restore` riattiva l'indicatore di carica. Il trigger lo
registra il power supply core (`power_supply_leds.c`, compilato perche' Lakka
ha `CONFIG_LEDS_TRIGGERS=y`) col nome `battery-charging-or-full`: si chiama
cosi' perche' la patch `0000` di Lakka rinomina il power supply del rk817 in
`battery`. Se il trigger non c'e', lo script non fa niente e non e' un errore.

I codici degli stick: Codici
presi dalla tabella di `mcu_led` in `docs/VERIFICATION.md` di devaOS e
verificati byte per byte:

    off 0x08   green 0x01   blue 0x02   red 0x03   cyan 0x04
    orange 0x05   purple 0x06   white 0x07
    breathing 0x13   breathing-blue 0x18

Gli altri codici della serie `0x11..0x18` esistono ma non risultano
verificati, quindi non hanno un nome: si raggiungono con `rf35h-led raw 0x15`.

Lo stesso `battery` fa funzionare l'indicatore di batteria di RetroArch:
`platform_unix.c` scende solo nei nodi di `/sys/class/power_supply` il cui
nome contiene `BAT` o `battery`, e legge `type`, `status`, `capacity` - che
`rk817_charger` fornisce tutti, con la tabella OCV di `monitored-battery`.
Verificato, niente da fare.

`rf35h-state.service` rimette luminosita' e LED al boot e spegne i LED allo
spegnimento - il microcontrollore mantiene lo stato anche a device spento,
quindi senza `ExecStop` resterebbero accesi.

## Retroilluminazione: il default

`default-brightness-level = <128>` su 255: al primo avvio lo schermo e'
illuminato a meta'. Un sospetto in meno se dovesse sembrare nero.

Da li' la muovono `rf35h-brightness` e, sul device, **L1+vol+/vol-**
(sotto).

## Bluetooth: non c'e'

Il device tree non ha nessun nodo Bluetooth e il driver RK915 porta solo
`rk915_fw.bin` e `rk915_patch.bin`, entrambi WLAN. Su questo port lo stack
bluez di Lakka si avvia e non trova adattatori. Se l'hardware ce l'ha, manca
il nodo nel DT - cosa che vale anche per devaOS, dove `S40bluetooth` e
`bt.sh` girerebbero a vuoto.

## Il tasto power non funzionava, per due motivi indipendenti

Su questa board il tasto power e' quello del **PMIC**: la cella mfd
`rk805-pwrkey` del rk817, input device `"rk805 pwrkey"`. Non e' un `gpio-keys`
e infatti nel device tree non compare - lo istanzia `drivers/mfd/rk8xx-core.c`.
Gli altri RK3326 di Lakka non ne hanno bisogno: l'Odroid Go stacca
l'alimentazione con un interruttore meccanico, e nessun DTS RK3326
dell'albero dichiara `KEY_POWER`.

**Primo motivo.** Nel config del kernel di Lakka:

    # CONFIG_INPUT_RK805_PWRKEY is not set

devaOS lo ha a `=y`. Senza, non esiste nessun input device: il tasto non
genera niente, e non c'e' nemmeno una sorgente di wakeup dal sospeso.
`kconfig-pwrkey-rf35h.patch` lo abilita.

**Secondo motivo.** Anche col driver acceso, in
`packages/sysutils/systemd/package.mk`:

    if [ "${DISPLAYSERVER}" = "no" ]; then
      HandlePowerKey=poweroff
    else
      HandlePowerKey=ignore
    fi

Con `DISPLAYSERVER="wl"` (il default RK3326) logind **ignora** il tasto.
`logind-powerkey-rf35h.patch` aggiunge un caso per `rf35h`, nello stesso stile
del caso RPi che sta due righe sopra. Con `optional/kms-no-compositor.patch`
il ramo giusto lo prenderebbe da solo, ma la patch di base non deve dipendere
da una opzionale.

Verificato che l'evento arrivi davvero a logind: `input/drivers/udev_input.c`
di RetroArch non fa `EVIOCGRAB`, quindi non sottrae la tastiera.

## Il context driver dell'Odroid Go, tolto di mezzo

`--enable-odroidgo2` che Lakka mette per tutti gli RK3326 non aggiunge solo il
video driver `oga` - che `retroarch-0002` commenta comunque via - ma anche il
**context driver** `gfx/drivers_context/drm_go2_ctx.o`, libgo2 e
`-lrga -lpng -lz`. Che sia compilato lo dimostra `retroarch-0001`, che esiste
solo per farlo compilare.

Il problema e' l'ordine in `gfx/video_driver.c`:

    #if defined(HAVE_KMS)
    #if defined(HAVE_ODROIDGO2)
       &gfx_ctx_go2_drm,
    #endif
       &gfx_ctx_drm,
    #endif

RetroArch scorre la lista e prende il primo che inizializza: su una build KMS
proverebbe il context dell'Odroid Go Advance su un pannello che non e' il suo.
libgo2 e' scritto per i 480x320 dell'OGA, con la sua rotazione e lo scaling
RGA.

Sotto Wayland non si vede, perche' vince il context wayland. Con
`optional/kms-no-compositor.patch` si', ed e' esattamente la combinazione che
quella patch propone.

`integration/retroarch-no-go2-rf35h.patch` salta il flag per `rf35h`: resta
`gfx_ctx_drm`, quello generico, e cadono libgo2 e librga.

## Opzionale: RetroArch senza compositore

`optional/kms-no-compositor.patch` porta `rf35h` a `DISPLAYSERVER="no"` e
`WINDOWMANAGER="no"`, cioe' RetroArch direttamente su KMS/GBM.

Ha senso perche' il driver video OGA e' commentato via da `retroarch-0002`:
il percorso RGA + plane DRM diretto non esiste comunque, e sotto sway si paga
un blit di composizione per frame su quattro A35 a 1.3 GHz senza nulla in
cambio. devaOS gira su questa stessa board con `video_driver = "gl"` e nessun
compositore, quindi il percorso KMS e' provato sull'hardware; e
`DISPLAYSERVER="no"` e' il valore piu' diffuso nei target Lakka, non una
configurazione esotica - `Rockchip/options` lo usa come default e solo il
device RK3326 lo sovrascrive.

Non e' applicata da `apply.sh`: al primo boot conviene restare sul percorso
che Lakka collauda su RK3326, per non debuggare due incognite insieme. Il
prerequisito (niente context go2) e' gia' nelle patch di base, quindi quando
la applichi non serve altro. Va
applicata **dopo** `integration/options-rf35h.patch`:

    patch -p1 -d <Lakka-LibreELEC> < optional/kms-no-compositor.patch

## Due script che vengono *sorgentati*, non eseguiti

`scripts/image` riga 354 fa `. ${FOUND_PATH}` su `bootloader/release`, e
`scripts/mkimage` riga 370 fa lo stesso su `bootloader/mkimage`. Girano quindi
**dentro** il processo del chiamante.

Conseguenza: un `exit` li' non esce dallo script, esce dalla build. La prima
versione della patch a `release` chiudeva il ramo rf35h con
`return 0 2>/dev/null || exit 0`: se `return` fosse fallito per qualsiasi
motivo, l'`exit 0` avrebbe terminato la build **con codice 0**, cioe' fingendo
successo e senza produrre immagine. Ora e' un `if/else` senza uscite
anticipate.

Verificato eseguendolo davvero, con l'ambiente finto: il ramo rf35h copia il
loader come `u-boot-rockchip.bin`, mette `.rockchip_boot_chain_old`, copia i
DTB, e **torna al chiamante**. Con un altro `UBOOT_SYSTEM` il ramo originale
si comporta come prima.

## Bootloader

Lakka su RK3326 usa U-Boot Hardkernel, `boot.ini` e `booti`. Qui no: si scrive
il `known-good.bin` di devaOS — i byte 32K..16M di una release AURKNIX che su
questa board parte davvero.

Combacia senza forzature: il `dd` di Lakka e' `bs=32k seek=1`, cioe' da 32K
esatti, e `SYSTEM_PART_START=32768` (16 MiB) e' lo stesso offset della prima
partizione di devaOS. I byte cadono dove devono.

Di conseguenza il boot passa da `boot.ini` a `/extlinux/extlinux.conf`, con
`FDT` esplicito e senza `fbcon=rotate:3` (il pannello e' 640x480 landscape
nativo).

**Verificato, non assunto.** Interrogando `known-good.bin`:

    U-Boot 2025.10 (Aug 09 2026 - 05:59:44 +0000)
    bootcmd=bootmeth order script; bootflow scan -b
    baudrate=1500000
    "extlinux.conf"  20 occorrenze
    "boot.ini"        0 occorrenze

E' bootstd, legge `extlinux.conf`, e `boot.ini` nel binario non esiste
proprio. Con il ramo `boot.ini` di Lakka il device sarebbe rimasto al prompt
di U-Boot senza dire perche'.

Lo stesso binario contiene il suo device tree, da cui arrivano anche console
e baud (vedi sotto).

## Cosa e' stato verificato qui

Cross-compile aarch64 contro Linux 7.0.1 (`gregkh/linux` tag `v7.0.1`, lo
stesso che Lakka `devel` pinna), con `linux.aarch64.conf` di Lakka come
`.config`:

- `rocknix-singleadc-joypad.ko` — compila, zero warning, nessuna modifica
  oltre la patch 6.15 gia' esistente
- `rk915.ko` (383 KB) — compila con la patch `0002`
- `panel-generic-dsi.o` e `panel-sitronix-st7703.o` — compilano
- `rk3326-xifan-rf35h.dtb` — compila sopra l'intero stack di patch Lakka +
  devaOS deduplicato, solo warning dtc cosmetici

## Console: ttyS1, e cosa c'e' davvero su ttyS2

Su RK3326 la debug UART del SoC e' uart2, e il device tree dentro il loader
(`model = "Generic RK3326 Handheld"`) dichiara `stdout-path = "serial2"`. Su
questa board non vale: quel DT e' il default di famiglia, non il cablaggio
dell'RF35H.

**ttyS2 e' il microcontrollore che pilota i LED degli stick**: collegamento a
senso unico, 9600 8N1, un byte per modo (OFF 8, Rosso 3, Verde 1, Blu 2,
Bianco 7, Arancio 5, Viola 6, Ciano 4; versioni "breathing" 0x11..0x18).
Protocollo ricavato dal binario `mcu_led` del vendor e documentato in
`docs/VERIFICATION.md` di devaOS.

Il DTS lo dice a chi lo legge bene:

    px30.dtsi   uart2m1_xfer = <2 RK_PB4 2>, <2 RK_PB6 2>   dma-names = tx,rx
    RF35H       uart2m1_xfer = <2 RK_PB4 2>                 dma-names = "tx"

Un pin solo e solo TX: non e' una seriale bidirezionale, e' un canale di
comando. GPIO2_B6, l'altra meta' del gruppo, qui e' `sw13 = BTN_THUMBR`.

Le prime immagini devaOS avevano la console proprio li' e **il log del kernel
veniva digitato dentro il controller dei LED**. La console e' `ttyS1` a
1500000 8N1.

Il commento `/* FIQ Header(P2) */` sopra `&uart2` e' ereditato dal DTS
dell'Odroid Go Advance e non descrive questa board.

**Trappola da conoscere.** In `options` c'e' una riga commentata di debug con
`systemd.debug_shell=ttyS2`, ed e' attiva per davvero su RK356X/RK3576/RK3588.
Scommentarla qui aprirebbe una shell di root verso il microcontrollore.
`options-rf35h.patch` mette l'avviso accanto a quella riga.

**I LED.** Lakka non tocca quel microcontrollore, quindi senza intervento i LED
resterebbero nello stato lasciato dall'OS precedente. Li gestisce `rf35h-led`
(sopra).

## Nomi ricavati dal codice, non tentati

Tre stringhe che sembravano da verificare sul device sono deterministiche:

| Cosa | Valore | Da dove |
|---|---|---|
| input device dei tasti volume | `adc-keys` | `adc-keys.c:151` `input->name = pdev->name`; `of/platform.c:51` `ofdev->name = dev_name()`; `of/device.c:310` nodo senza `reg` -> basename del nodo |
| input device del jack | `rk817_ext Headphones` | `jack.c:94` `"%s %s"` di `card->shortname` e `jack->id`; `simple-card-utils.c:800` pin NULL -> `"Headphones"`; shortname da `simple-audio-card,name` |
| controllo dello speaker | `Internal Speakers Switch` | `soc-core.c:3129` `"%s Switch"`, `SNDRV_CTL_ELEM_IFACE_MIXER` |

E' lo stesso meccanismo per cui i gpio-keys dell'Odroid Go si chiamano
`odroidgo3-keys`: il nome del nodo diventa il nome dell'input device.

I service usano `amixer cset name='...'` con il nome esatto del kcontrol,
non `sset`, cosi' non dipendono da come alsa-lib aggrega gli elementi.

## Fuzz zero

`apply.sh` applica tutto con `--fuzz=0`. Non e' pignoleria: un patch che passa
col fuzz e' un patch che ha trovato "un posto che somiglia", e resta buono
finche' il file non cambia.

E' successo davvero. il device tree (`z-010`) era stata generata contro un albero che aveva
gia' il device tree (`z-010`), quindi il suo contesto conteneva due righe di `role-switch`.
LibreELEC applica in ordine alfabetico, cioe' il device tree (`z-010`) prima di il device tree (`z-010`), e
`patch` la faceva passare lo stesso. Funzionava per fortuna, non per
costruzione.

Rigenerate nell'ordine reale - il device tree (`z-010`) dallo stato con solo `z-010`, il device tree (`z-010`)
da quello con `z-010`+il device tree (`z-010`) - e ricontrollate tutte:

    8 patch kernel            OK a fuzz 0
    8 patch di integrazione   OK a fuzz 0
    1 opzionale               OK a fuzz 0
    4 patch dei due moduli    OK a fuzz 0

## Verifica finale

Oltre a patch e compilazioni, il comportamento dei file **sorgentati** dal
build system e' stato provato eseguendolo, non solo leggendolo.

`projects/Rockchip/devices/RK3326/options`, sorgentato per davvero:

    UBOOT_SYSTEM=rf35h
      ADDITIONAL_PACKAGES:  odroidgo2-utils rf35h-utils usb-modeswitch-RK3326
      ADDITIONAL_DRIVERS:   rk915 rocknix-joypad
      EXTRA_CMDLINE:        console=tty0 console=ttyS1,1500000n8 net.iframes=0
    UBOOT_SYSTEM=rg351v
      ADDITIONAL_PACKAGES:  odroidgo2-utils odroidgoa-volkeys usb-modeswitch-RK3326
      EXTRA_CMDLINE:        console=tty0 net.iframes=0 fbcon=rotate:3

`scripts/uboot_helper` con la voce nuova:

    dtb    -> rk3326-xifan-rf35h.dtb
    config -> odroidgoa_defconfig
    board  -> odroidgo2 odroidgo2v11 odroidgo3 rf35h rg351m rg351v

Il `sed` del tasto power, nella sequenza reale (prima il ramo upstream che con
un display server mette `ignore`, poi il nostro):

    dopo upstream: HandlePowerKey=ignore
    dopo il nostro: HandlePowerKey=poweroff

E il condizionale di RetroArch: per `rf35h` niente `librga` e niente
`--enable-odroidgo2`, per `rg351v` entrambi come prima.

`bash -n` pulito su tutti e undici i file sorgentati che l'overlay tocca o
crea, `sh -n` sui tre script del device.

**FAT a 32 settori per cluster**: su 2048 MiB fanno **131007 cluster**, ben
sopra il minimo FAT32 di 65525, quindi nessuna ricaduta su FAT16 che
contraddirebbe il tipo di partizione 0x0C. `fsck.fat -v` pulito.

**Handoff di boot**: `packages/sysutils/busybox/scripts/init` accetta `boot=`
e `disk=` nelle forme `/dev/*`, `LABEL=*`, `UUID=*`. `mkimage-rf35h.patch`
scrive `boot=UUID=... disk=UUID=...`, le stesse che usano il ramo generico e
il `boot.ini` di Lakka.



Le 8 patch di integrazione piu' quella opzionale sono state applicate **in
sequenza sullo stesso albero**, non solo una per una, e i file di destinazione
sono stati riletti dopo: `options` porta le voci `rf35h`, il config del kernel
ha `CONFIG_INPUT_RK805_PWRKEY=y`, e `mkimage`, `release`, `package.mk` di
systemd e di RetroArch hanno tutti il loro ramo.

## Validato sui log di boot dell'RF35H

Tutti e quattro i nomi che avevo ricavato leggendo il codice del kernel
compaiono identici in `/proc/bus/input/devices` del device:

    N: Name="rk805 pwrkey"           -> logind-powerkey-rf35h.patch
    N: Name="adc-keys"               -> rf35h-volkeys.service
    N: Name="retrogame_joypad"       -> autoconfig
    N: Name="rk817_ext Headphones"   -> rf35h-audio.service

e la scheda audio e' `0 [rk817ext]: simple-card - rk817_ext`. Il dmesg mostra
`input: adc-keys as /devices/platform/adc-keys/input/input1`, che e' esattamente
il nome del nodo: `of_device_make_bus_id()` come previsto.

Confermato anche il resto: `card0-DSI-1: connected`, `backlight: 128/255`
(cioe' `default-brightness-level`), console `ttyS1,1500000n8` nel cmdline, GPU
a `560000000` (il punto unico di il device tree (`z-010`)), joypad con `adc key cnt = 4,
gpio key cnt = 17` - 17 pulsanti, gli indici 0..16 dell'autoconfig.

Il pannello logga `Failed to request panel display timing` e subito dopo
`lanes 4, format 0, mode e03`: non e' un errore, e' il driver che non trova un
`display-timings` e cade sul `panel_description` del DT - `flags=0xe03`
combacia. La console passa a `80x30`, cioe' 640x480 con font 8x16.

## Il turbo a 1416 MHz e' una frequenza boost

Il log lo dice due volte:

    cpufreq: CPU0: Running at unlisted initial frequency: 600000 kHz,
                   changing to: 1008000 kHz
    cpu cpu0: EM: OPP:1296000 is inefficient

La prima riga conferma che 600 MHz **non** e' piu' nella tabella: il loader
lascia la CPU li', il kernel non la trova elencata e salta a 1008. La seconda
implica che 1416 c'e' (altrimenti 1296 sarebbe il massimo e non potrebbe
essere "inefficiente" rispetto a nulla).

Ma con governor `performance` il device gira a **1296000**, non 1416000:
`turbo-mode` nel binding OPP significa frequenza boost, esclusa finche' non la
si abilita. Quindi il turbo che il device tree (`z-010`) ripristina e' presente ma inerte di
default, esattamente come su devaOS. Per usarlo:

    echo 1 > /sys/devices/system/cpu/cpufreq/boost

## Un problema di devaOS che Lakka non ha

    platform regulatory.0: Direct firmware load for regulatory.db failed
    cfg80211: failed to load regulatory.db

Manca il database regolatorio wireless, quindi cfg80211 resta sul dominio
mondiale e i canali/potenze permessi sono i piu' restrittivi. Lakka lo ha:
`packages/network/wireless-regdb` e' fra le dipendenze di
`packages/virtual/network`. Qui non c'e' niente da fare - e' devaOS che
guadagnerebbe ad aggiungerlo.

## Cosa e' gia' validato da devaOS sul device

devaOS boota sull'RF35H. Tutto quello che questo overlay eredita da li' non e'
piu' un'ipotesi:

- catena di boot `known-good.bin` + `extlinux.conf` + bootstd
- pannello via `rocknix,generic-dsi` (z-002) e le patch `r-025` / `z-001`
- `rocknix-singleadc-joypad` e la mappatura del device tree
- RK915 con `supports-rk912` e la patch `r-024`
- geometria FAT a 32 settori per cluster
- console su `ttyS1`

Dove Lakka si comporta diversamente da devaOS, l'indiziato e' Lakka. Questo
overlay porta la configurazione di devaOS dentro l'albero LibreELEC; non la
reinventa.

## Cosa e' stato compilato ed eseguito qui

Non solo applicato: compilato in cross verso aarch64 contro Linux 7.0.1 con il
`linux.aarch64.conf` di Lakka come `.config`, dopo tutte le patch.

| Cosa | Esito |
|---|---|
| `rocknix-singleadc-joypad.ko` | compila con `patches/0002` - senza, **non compila affatto** (vedi sotto) |
| `rk915.ko` | compila (383 KB) con la patch 7.0 |
| `drivers/input/` (32 oggetti) | compila - `adc-keys.o` incluso |
| `drivers/input/misc/rk805-pwrkey.o` | compila **dopo** aver abilitato il simbolo; l'oggetto contiene la stringa `rk805 pwrkey`, lo stesso nome che il device mostra in `/proc/bus/input/devices` |
| `drivers/power/supply/` | compila; `rk817_charger.o` contiene `battery` e `charger`, non `rk817-battery`: il rename di Lakka e' effettivo, ed e' cio' da cui dipendono i trigger LED e il rilevamento batteria di RetroArch |
| `drivers/mmc/core/`, `dw_mmc.o` | compilano con `r-024` (`MMC_CAP2_WIFI_RK912`) |
| `dw-mipi-dsi.o`, `panel-generic-dsi.o`, `panel-sitronix-st7703.o` | compilano |
| `sound/soc/codecs/`, `sound/soc/generic/` | compilano |
| `drivers/gpu/drm/panel/`, `rockchip/`, `bridge/` | compilano (16 oggetti) nell'albero completo |
| `rk3326-xifan-rf35h.dtb` | compila; `rk3326-odroid-go2.dtb` resta a 5 OPP, non contaminato |
| `spkeys-service` patchato | compila e **gira**: vedi sotto |

Il kernel intero non e' stato linkato: su una CPU sola servirebbero una
quindicina di sessioni e i processi non sopravvivono fra una e l'altra. Sono
stati compilati tutti i sottosistemi che le patch e il cambio di config
toccano; il resto e' config Lakka su sorgente 7.0.1 non modificato, che Lakka
costruisce gia' per gli altri RK3326.

Due driver che Lakka aggiunge per intero **non entrano** in questa immagine,
quindi non sono un rischio: `CONFIG_ESP8089` non e' abilitato (il Wi-Fi qui e'
la RK915) e nemmeno la classe video USB, che rende inerte
`uvc-bandwidth_cap_param-for-sinden.patch`.

**`rf35h-diag` eseguito.** Qui non esiste quasi niente di cio' che cerca:
esce con 0, nessuna riga su stderr, 16 sezioni, ogni cosa assente segnalata
come tale invece di far morire lo script.

**Un blocco che solo la build in contesto ha trovato.** Il modulo joypad
compilava contro 7.0.1 vergine e **non** contro 7.0.1 con le patch di Lakka:

    of_gpio_compat.h:14:6: error: redeclaration of 'enum of_gpio_flags'

Lakka reintroduce `<linux/of_gpio.h>` con l'API legacy completa dentro
`0002-add-input-polldev.patch`, e il compat header di devaOS la reimplementa.
La guardia che c'era - `#ifndef OF_GPIO_ACTIVE_LOW` - non poteva funzionare:
quello e' un **enumeratore**, non una macro, quindi la condizione e' sempre
vera. `packages/rocknix-joypad/patches/0002-of-gpio-legacy-guard.patch` rende
la scelta esplicita e il package passa `-DROCKNIX_OF_GPIO_LEGACY_PRESENT`.

Senza quella macro il comportamento e' identico a prima, quindi devaOS su
6.15 non e' toccato. Verificato in tre modi: da sorgente vergine + 0001 + 0002
compila senza warning; senza il flag fallisce ancora (la guardia non maschera
il problema); il `.ko` esce a 39632 byte.

Senza questo fix Lakka sarebbe partita **senza nessun input**.

**`spkeys-service` eseguito davvero.** Niente `/dev/uinput` qui, quindi ho
intercettato `scandir`, `open`, `ioctl(EVIOCGNAME)`, `socket`/`connect` e
`system` con un `LD_PRELOAD`, e alimentato due fifo con `struct input_event`
veri. Il ciclo eventi, il poll e la logica del modificatore sono il codice
vero:

    un tap di vol+                 -> UN SOLO VOLUME_UP          ok
    L1+vol+ (device diversi)   -> shell, niente a RetroArch  ok
    L1+vol-                    -> BRIGHT_DOWN                ok
    dopo il rilascio               -> di nuovo VOLUME_UP         ok
    senza --mod: Select non e' un modificatore                   ok
    2 s tenuto premuto -> 5 comandi (non ~20)                    ok

E la regressione sull'Odroid Go, con la sua invocazione esatta - un solo nome
di device, nessuna opzione: tre tap producono tre `VOLUME_UP` e niente alla
shell. Prima ne producevano sei.

## Log che sopravvivono al device morto

`rf35h-diag` serve se hai gia' una shell. Se lo schermo resta nero o il boot si
ferma, l'unica cosa che ti resta e' la SD. `createlog-lakka`, che Lakka ha gia',
scrive in `/tmp` e al riavvio sparisce.

`rf35h-bootlog.service` scrive in **`/storage/rf35h-logs/`**, che e' ext4: togli
la scheda, la monti su qualunque PC Linux e leggi.

    boot.log        l'ultimo avvio
    boot.1.log      il precedente, fino a boot.5.log
    shutdown.log    scritto allo spegnimento
    dmesg-boot.log  solo il log del kernel, a parte

Il log allo spegnimento non e' un doppione: contiene `time_in_state` e i picchi
termici di **tutta la sessione**, cioe' i dati che dicono se la scala OPP piena
regge sotto carico.

Rotazione numerata e non per data: questi handheld non hanno la batteria
dell'orologio, quindi al boot la data puo' essere l'epoca zero e i nomi coi
timestamp risulterebbero tutti uguali.

### Cosa contiene, oltre al riassunto

`rf35h-diag --full` aggiunge undici sezioni di dump grezzo. Quella che conta di
piu':

    === input devices, dump completo
    B: KEY=...
    B: ABS=...

Sono le bitmap dei tasti e degli assi, **la fonte di verita' per gli indici
dell'autoconfig**. Finora quegli indici li ho potuti solo calcolare dal device
tree e dal sorgente di RetroArch, mai leggere dal device. Con questo log, se un
pulsante risulta sbagliato, la correzione e' di trenta secondi invece che una
ricostruzione a tavolino.

E poi: tutti i controlli ALSA, `cpufreq` con le frequenze disponibili e
`time_in_state`, il devfreq della GPU, l'alimentazione, i trigger dei LED, il
`compatible` che il kernel ha davvero enumerato, `lsmod`, le unita' systemd
fallite, il journal del boot e il `dmesg` completo.

Nessuno dei due blocca il boot: il servizio ha `-` su entrambi gli ExecStart, e
lo script esce 0 anche se `/storage` non e' scrivibile. Verificato.

## Joypad: autoconfig confermato dalle bitmap reali

Dal `/proc/bus/input/devices` del device che gira:

    B: KEY=f00000000 0 0 0 7fdb000000000000 0 0 0 0
    B: ABS=1b

Decodificate: 17 tasti (SOUTH EAST NORTH WEST, TL TR TL2 TR2, SELECT START
MODE, THUMBL THUMBR, DPAD x4) e 4 assi (X Y RX RY, niente Z). Gli indici che
`udev_joypad` assegna coincidono uno per uno con `retrogame_joypad.cfg`, che
era stato calcolato dal sorgente senza mai vedere il device. Chiuso.

## LED degli stick: erano spenti perche' l'MCU era senza enable

Tre giorni di confronti su UART, baud, clock, regolatori: tutti giusti e
tutti irrilevanti. Il microcontrollore degli stick sta dietro **GPIO2_A1**, e
quel pin non e' in nessun device tree - nemmeno in quello di ArkOS4Clone, che
sullo stesso hardware li accende. Li' e' **EmulationStation** ad esportarlo via
`/sys/class/gpio` e a tenerlo alto prima di parlare all'MCU su `ttyS2`. Con il
pin basso l'MCU non risponde a nessun byte, a nessuna velocita'. Su devaOS non
funzionavano per lo stesso motivo.

Trovato con `hwdump.sh` - i registri dei banchi GPIO letti via `devmem` su
entrambi i sistemi e messi a `diff`: GPIO2 `DR=0x2`, `DDR=0x18002` su ArkOS,
zero da noi. Una riga.

il device tree (`z-010`) lo espone come LED class **`joyled-power`** (gpio-leds, acceso al
boot): `/sys/class/leds/joyled-power/brightness`. LED class e non regolatore
apposta, cosi' `rf35h-led --sleep` lo spegne in sospensione e `--wake` lo
riaccende.

Il protocollo e' quello di `bin/mcu_led` di ArkOS4Clone (sorgente in
`lcdyk0517/JoyLed`), decodificato dal binario prima e confermato dal `.c` poi:
9600 8N1 su `ttyS2`, un byte. La tabella di devaOS aveva due errori - `off`
era `0x08`, che e' **Flow**; lo spegnimento vero e' `0x00` - e mancavano sette
modi. Ora ci sono tutti i 17.

### LED degli stick, l'altro ostacolo: il busybox di Lakka non ha stty

`rf35h-led` usava `stty` per mettere `ttyS2` a 9600 8N1 raw. Lakka non ha ne'
`stty` ne' `microcom` (`CONFIG_STTY`/`CONFIG_MICROCOM` non impostati), solo
`setserial`, che regola l'UART ma non il termios. E il termios serve: senza raw
mode, `0x11`/`0x13` sono XON/XOFF e il tty se li mangia, `0x0d` viene tradotto.

`packages/rf35h-utils/sources/rf35h-tty.c`: quaranta righe di C, apre la porta,
`cfmakeraw` + 9600 8N1, scrive i byte. Nessuna dipendenza. Provato su una pty:
`0x11 0x0d 0x13 0x18` arrivano intatti, termios raw a 9600 con ICANON, ECHO e
IXON spenti. Compila in cross senza warning. Il package segue lo schema di
`eventservice` (`sources/Makefile`, `PKG_URL=""`).

## Wi-Fi: cosa serviva davvero, in ordine

Quattro cause distinte, una sotto l'altra. Ognuna nascondeva la successiva.

1. **iwd.** Lakka e' iwd-only dalla v6; con la RK915 la UI non vedeva reti.
   -> `wpa_supplicant` come package del device, `WIRELESS_DAEMON` nelle
   options, `iwd.service` non abilitato.
2. **connman non ricostruito.** `calculate_stamp()` non guarda l'ambiente:
   cambiare `WIRELESS_DAEMON` non lo rifaceva, e restava il plugin iwd
   ("scan wifi: Not supported"). -> `PKG_STAMP="${WIRELESS_DAEMON}"`.
3. **SAE.** connman 2.0 manda `SAE WPA-PSK WPA-PSK-SHA256` a ogni rete PSK;
   il config v5 di wpa_supplicant era pre-WPA3 e rifiutava tutto
   ("invalid key_mgmt 'SAE'" -> "invalid-key" in connman).
   -> `CONFIG_SAE=y`, `CONFIG_IEEE80211W=y`.
4. **Stato sporco dai test.** Il provisioning lascia la cartella del servizio
   senza passphrase nel settings; la UI la vede, non riscrive la password,
   e il connect fallisce. -> `rm -rf /storage/.cache/connman/wifi_*` e via
   il `.config`. Gli script di test ora lo fanno da soli.

Verificato dalla GUI: spegni e riaccendi il Wi-Fi, riconnesso in sei secondi
con `PTK=CCMP GTK=CCMP`, IP via DHCP, online check superato.

## Wi-Fi: la catena verificata

    UI RetroArch  ->  connmanctl scan wifi / services / connect
                      (network/drivers_wifi/connmanctl.c: zero riferimenti a iwd o wpa)
    connmand      ->  gsupplicant, D-Bus, nome fi.w1.wpa_supplicant1
                      (gsupplicant/dbus.h:24 SUPPLICANT_SERVICE)
    D-Bus         ->  attiva fi.w1.wpa_supplicant1.service -> wpa_supplicant.service
                      (Type=dbus, ExecStart=/usr/bin/wpa_supplicant -u)
    wpa_supplicant->  nl80211 -> mac80211 -> rk915

Ogni anello controllato sul sorgente: le opzioni `--disable-wifi`/`--enable-iwd`
di connman 2.0 esistono (`configure.ac:430,435`), `WPASUPPLICANT=` e' un
`AC_PATH_PROG` che nessun `.c` usa - serve solo a non far fallire configure in
cross-compile. libnl 3.12, crypto software (`AES CCM GCM CMAC=y`) per un
driver senza cifratura hardware. systemd ha la sospensione: Lakka disabilita
solo `hibernate`.

## Gli errori nei log che non sono errori

Al primo boot ne compaiono una sessantina. Nessun servizio fallisce
davvero - `Failed to start` non compare mai - e nel kernel non c'e' un solo
`WARNING:`, `BUG:`, `Oops`, `call trace`, `timeout` o `I/O error`.

| Riga | Cos'e' |
|---|---|
| `Looking up <qualcosa>-supply property ... failed` (una decina) | e' il framework dei regolatori che cerca un'alimentazione opzionale nel device tree e non la trova. Su questa board quelle linee sono fisse, quindi il nodo non c'e' e il driver prosegue col default. Lo dice a livello debug, non di errore |
| `failed to open rk915_cal.bin` / `rk915_rf_para.txt` | file di calibrazione opzionali. Subito dopo: `download firmware success` |
| `Failed to request panel display timing` | atteso: `panel-generic-dsi` prova prima il timing dal DT, non lo trova e usa `panel_description`. E' il percorso giusto, lo stesso di devaOS |
| `Unable to detect cache hierarchy for CPU N` | `px30.dtsi` di mainline non dichiara i nodi cache. Cosmetico |
| `Cannot create '/etc/machine-id': File exists` | normale in LibreELEC, `/etc` e' ricostruita a ogni boot |
| `Failed to find module 'pkcs7_key_parser'` | e' builtin, non un modulo. Cosmetico |
| `Failed to create IPv6 socket` (avahi, nmbd) | IPv6 disabilitato da cmdline |
| `sync_state() pending due to ff442000.video-codec` | il VPU, attivo di serie in `px30.dtsi`: il modulo `hantro` non si carica. I domini Rockchip hanno `GENPD_FLAG_NO_STAY_ON` e si spengono comunque. Cosmetico |
| `Failed to drop supplementary groups` | un servizio senza CAP_SETGID. Cosmetico |

## Il menu "Device Settings" in RetroArch

Prende il posto di "Bluetooth" nel menu Settings, che sull'RF35H non serve.
Quattro voci, ognuna applica subito e resta in retroarch.cfg:

| voce | valori | cosa chiama |
|---|---|---|
| Sleep Timer | 0 (off), 5..60 min | scrive `rf35h-idle.conf`, riavvia `rf35h-idle` |
| Screen Brightness | 5..100 % | `rf35h-brightness N` |
| Joystick LEDs | i 17 modi di mcu_led | `rf35h-led <modo>` |
| Status LEDs | charge, red, blue, both, off | `rf35h-statusled <modo>` |
| USB-C Port | host, transfer | `rf35h-usb <modo>` |
| Audio Output | speakers, usb | dentro RetroArch: `audio_device` + `CMD_EVENT_AUDIO_REINIT` |

(Il profilo di prestazioni non c'e': RetroArch ce l'ha gia', in Settings →
Power Management.)

### La porta USB-C: due usi

Il DWC2 del PX30 e' dual-role e il suo role switch e' scrivibile da userspace
(`allow_userspace_control = true` in `dwc2/drd.c`). `rf35h-usb` lo sfrutta:

- **host** (default): pad, chiavette (Lakka le monta da sola sotto `/media`),
  tastiere, e **cuffie USB-C**: sono un DAC USB, con `SND_USB_AUDIO=y` gia'
  nel kernel diventano la scheda ALSA 1. La voce "Audio Output → usb" le
  cerca in `/proc/asound/cards` e ci sposta RetroArch al volo.
- **transfer**: la console si presenta al PC come scheda di rete (gadget
  composito RNDIS + ECM via configfs, la ricetta di `g_ether`: Windows prende
  RNDIS grazie agli OS descriptor, Linux e Mac prendono ECM). I due link
  `usb0` e `usb1` vanno in un bridge `usbbr0` con 192.168.7.1, cosi' un solo
  `udhcpd` serve qualunque PC (senza bridge nel kernel: stesso IP su entrambi
  e due `udhcpd`). Dal PC: `\\lakka.local`, `smb://192.168.7.1`,
  `ssh root@192.168.7.1`.
  Samba: se lo avevi spento in Lakka (`samba.disabled`), "transfer" lo
  accende per la sessione mettendo il flag da parte, e "host" lo rimette.

Perche' rete e non "chiavetta": un gadget mass-storage vorrebbe `/storage`
smontato, e `/storage` *e'* Lakka; MTP avrebbe voluto `umtprd`, che Lakka non
ha. Samba, SSH e Avahi c'erano gia' tutti.

Tre patch di integrazione lo rendono possibile: `kconfig-usb-gadget` (il
kernel aveva `USB_GADGET=y` senza nessuna funzione), `busybox-udhcpd`, e
`connman-blacklist-usb` (connman non deve fare DHCP *client* sul gadget; i
dongle ethernet USB si chiamano `eth*`, la blacklist non li tocca).


E' `patches/retroarch/retroarch-1003-rf35h-settings-menu.patch`, generata da
`tools/gen-retroarch-rf35h-menu.py` (che applica modifiche con ancore esatte:
se il commit di RetroArch cambia e un'ancora sparisce, si ferma invece di
produrre una patch a meta'). Modellata riga per riga sul menu "Nintendo Switch
Options" di Lakka (`HAVE_LAKKA_SWITCH`), che tocca gli stessi dieci file.

Niente flag di build: il menu compare solo se sul device esiste
`/usr/bin/rf35h-led`, e Bluetooth sparisce con la stessa condizione. Un solo
RetroArch serve tutti gli RK3326 dell'albero.

Quando il menu si apre, i valori vengono **riletti dal sistema**
(`rf35h_sync_settings`): se hai cambiato la luminosita' con L1+vol, il
menu mostra quella. Stringhe in inglese e in italiano.

Tutti i modi (USB, LED) tornano al boot da `rf35h-state.service`.

Alla prima build il menu **non compariva**: Bluetooth spariva (quindi la
condizione scattava) ma la voce nostra no. Mancava il `CONFIG_ACTION` che
registra la voce nella lista principale dei Settings: senza, il `PARSE_ACTION`
della displaylist non trova nessun setting per l'enum e non aggiunge niente.
Il precedente Switch lo ha; io l'avevo saltato. Ora un controllo meccanico
confronta, file per file, le occorrenze della voce Switch con le nostre.

Alla seconda build la voce c'era ma si chiamava **"null"**, e il sottomenu
era vuoto. Le stringhe in `msg_hash_us.h` e `msg_hash_it.h` erano finite
DENTRO l'`#ifdef HAVE_LAKKA_SWITCH` della voce Switch (l'ancora era la
`MSG_HASH` subito dopo l'`#ifdef`): il preprocessore le scartava, e
`msg_hash_to_str` restituiva "null" per ogni etichetta. Il controllo
`-fsyntax-only` non puo' vederlo: codice escluso compila sempre. Ora si
verifica il **preprocessato** di `msg_hash_us.c` e `msg_hash.c` con i flag di
Lakka: ogni stringa e ogni label devono comparirci.

Alla terza build la voce si chiamava bene ma il sottomenu era **vuoto**: lo
stesso errore, una terza volta, sul blocco `case SETTINGS_LIST_RF35H` in
`menu_setting.c` — ancorato al `case` dello Switch invece che all'`#ifdef
HAVE_LAKKA_SWITCH` che lo precede. Ora `tools/check-ifdef-nesting.py`
ricostruisce la pila degli `#if` in ogni punto dove compare RF35H e segnala
qualunque condizione che Lakka non definisce; e il preprocessato di
`menu_setting.c` deve contenere `case SETTINGS_LIST_RF35H:` e le quattro
assegnazioni dei change_handler.

`tools/check-patch-hunks.py` verifica che i conteggi `@@` di ogni patch
corrispondano alle righe vere: modificare una patch a mano senza aggiornarli
fa applicare il blocco **troncato**, in silenzio (successo: `CONFIG_NTFS3_FS`
sparita dalla config, trovata solo eseguendo kconfig).

Alla quarta build il menu c'era e funzionava, ma "Screen Brightness → 100%"
portava la luminosita' al **19 %**, e "Sleep Timer → 60" avrebbe messo 12.
`setting_action_ok_uint` apre la tendina "semplice", che ricava il valore
scelto come **indice + offset**, dando per scontato passo 1: con 5..100 a
passo 5, "100" e' la voce 19. Per i range a passo diverso da 1 RetroArch ha
`setting_action_ok_uint_special`, che legge il numero dal testo della voce —
e' quello che usa `menu_screensaver_timeout`, il modello da cui avevo copiato
prendendo la funzione sbagliata. Le voci a stringa (LED, USB, audio) usano il
percorso `ST_STRING_OPTIONS`, che mappa per indice sull'elenco `a|b|c` e
chiama il change_handler: erano gia' corrette.

Verificata cosi': `./configure` di RetroArch, poi `gcc -fsyntax-only` sui nove
file toccati con i flag esatti di Lakka (`HAVE_LAKKA`, `HAVE_OZONE`...), sia
sul sorgente originale sia dopo tutte le patch di Lakka applicate nel modo di
LibreELEC (`patch -p1`); e senza `HAVE_LAKKA`, per le guardie. Zero errori,
zero warning. Quello che non posso verificare da qui e' l'aspetto a schermo.

## NEON su aarch64 e "CPU Model: N/A": due difetti di RetroArch

System Information sull'RF35H diceva `CPU Model: N/A`, `CPU Features: ASIMD`.
Il secondo era la punta di qualcosa di piu' grosso.

**NEON.** RetroArch imposta `RETRO_SIMD_NEON` e compila i percorsi NEON del
resampler audio (sinc), della conversione s16↔float e del decoder JPEG solo se
esiste `__ARM_NEON__` o `HAVE_NEON`. Su aarch64 GCC definisce **`__ARM_NEON`**
(ACLE, senza underscore finali) e Lakka passa `--enable-neon` solo su ARM a
32 bit. Risultato: su ogni Lakka a 64 bit l'audio di RetroArch gira in C puro
e il flag non viene mai impostato. `pixconv.c` accetta gia' `__ARM_NEON`: la
patch 1004 fa lo stesso negli altri quattro file e nel flag runtime. Tutte le
implementazioni sono intrinsics ACLE (le `.S` a 32 bit stanno dietro
`HAVE_ARM_NEON_ASM_OPTIMIZATIONS`, che resta spento). `--enable-neon` non era
la strada: aggiunge `-mfpu=neon -marm`, che il compilatore aarch64 rifiuta.
Verificato con il cross-compiler: i cinque file compilano, e nel preprocessato
dopo `ASIMD` compare `cpu |= (1 << 5)`, cioe' NEON.

**CPU Model.** Su Linux RetroArch legge `model name` da `/proc/cpuinfo`, che
su ARM64 mainline non esiste. Fallback: `CPU implementer`/`CPU part` → nome
del core (0x41/0xd04 = Cortex-A35) piu' il SoC dal secondo `compatible` del
device tree (`xifan,rf35h\0rockchip,rk3326`). Mostra **"Rockchip RK3326
(Cortex-A35)"**, e funziona su qualunque board ARM. Le altre features
dell'A35 (aes, sha, crc32) non hanno un flag in RetroArch: non c'e' altro da
mostrare.

## Audio: era il codec, un bit non documentato

Suono "da radio che non prende", anche da `speaker-test` con RetroArch fermo.
Percorso digitale tutto giusto (I2S 12,288 MHz, S16, 16 bit nel codec, PLL,
charge pump e opamp HP identici al BSP). Il confronto **registro per registro**
con ArkOS4Clone in playback ha lasciato un solo sospetto: `DDAC_MUTE_MIXCTL`
(0x38). Reset `0xa0`; il BSP scrive `0x00` nel power-up; mainline tocca solo
i bit 0, 4, 7 e lascia il **bit 5** acceso. Scritto a 0 via I²C con il seno
in corso (`rf35h-i2c 0 0x20 0x38 0x00`): pulito all'istante. Riacceso: rumore.

**Quinto giro, e la diagnosi definitiva, misurata sul device.** Mascherando
RetroArch e riavviando, `speaker-test` sull'hardware diretto **suonava**: il
primo flusso dopo il boot funziona per chiunque, RetroArch non ha nulla di
speciale. Ogni flusso successivo era muto. Il motivo e' nel device tree, che lo
dice a chiare lettere: la scheda instrada *entrambi* i canali
dell'amplificatore "otherwise the second channel stays on and keeps amp
enabled". Il percorso di riproduzione quindi **non si spegne mai** - il GPIO
dell'ampli resta alto anche dopo la fine, misurato - e un evento DAPM
`PRE_PMU`, che scatta solo sulla transizione spento->acceso, dal secondo
flusso in poi non viene piu' eseguito. Il ricevitore I2S del codec resta
disallineato e non esce nulla.

Il riarmo sta ora in **`.prepare`**, che gira a ogni avvio di riproduzione e
puo' dormire (il codec e' su I2C). E' il terzo aggancio provato: `.trigger`
uccideva RetroArch (contesto atomico), l'evento DAPM non scattava piu'. Il
build script rifiuta entrambe le forme sbagliate.

**Quarto giro, e un errore grave mio**: avevo spostato il riarmo I2S in
`.trigger`. Sul device: GUI a posto, ma **al lancio di qualunque ROM RetroArch
moriva** e restava il desktop di sway col logo. Causa da manuale: il trigger
PCM gira sotto lo **spinlock** dello stream (simple-card non imposta
`nonatomic`), il codec rk817 e' **regmap su I2C**, e una scrittura I2C dorme.
Dormire in contesto atomico = oops nel contesto del processo che ha fatto la
ioctl = RetroArch ucciso, kernel vivo. Il menu funzionava solo perche' non
aveva ancora aperto il PCM.

La posizione giusta era sotto gli occhi: un evento **DAPM `PRE_PMU` sul supply
"DAC Mute Off"**. Le DAPM event girano in contesto di processo; i supply si
accendono in ordine di lista, e `LDO`, `IBIAS`, `VAvg`, `PLL Power` (1-4)
vengono prima di `DAC Mute Off` (26); e quel widget sta su un registro diverso
dai precedenti, quindi DAPM committa le loro scritture prima di chiamare
l'evento (`dapm_seq_run`, `w->reg != cur_reg`). Cioe': dopo analogico e PLL,
subito prima del mute-off - la posizione del BSP - senza dormire dove non si
puo'. Verificato che "DAC Mute Off" alimenti anche `DAC L`/`DAC R`, il nostro
percorso cuffie. Il build script ora si ferma se in `r-026` compare un
`.trigger`.

**Terzo indizio, dal device**: con `r-026` in `.prepare` l'audio e' diventato
**casuale** - stesso comando, a volte pulito e a volte no, e senza dipendere
dal formato. Casuale per stream significa ordine, non configurazione. Nella
`playback_power_up_list` del BSP il riarmo I2S sta **dopo** il riferimento
analogico e la PLL, subito prima di togliere il mute; `.prepare` invece gira
**prima** che DAPM accenda i widget analogici - l'ordine opposto. Spostato in
`.trigger(START)`, che viene dopo lo stream event di DAPM: e' il punto in cui
lo fa il BSP. `rf35h-audiotest` ripete la stessa riproduzione salvando i
registri a ogni giro, cosi' un giro buono e uno cattivo si confrontano: se i
registri sono identici il problema e' di tempi, se differiscono il registro
che cambia e' il colpevole.

`r-026` azzera il bit 5 in `rk817_init()`. Vale per ogni board col rk817 su
mainline.

**Secondo indizio**: con quel bit sistemato l'audio a volte e' rumore al primo
stream dopo il boot e diventa pulito riaprendo il PCM (Audio off/on in
RetroArch). Un difetto che va e viene al riavvio dello stream non e' un bit
fisso: e' **sequenza**. La `playback_power_up_list` del BSP fa a ogni avvio
una cosa che mainline non fa: ferma e riavvia la ricezione I2S (`RXCMD_TSD 0`,
`RSD 0`, `RXCR1 0`, `RXCMD_TSD 0x20`) e riarma `DDAC_POPD_DACST 0x02`. Se il
ricevitore aggancia la cornice I2S a meta' parola, legge dati sballati finche'
non viene riallineato — e riaprire il PCM lo riallinea per caso. `r-026` ora
lo fa in un `.prepare` del DAI, prima di ogni stream in riproduzione.
`AREF_RTCFG1` non si tocca (lo governa DAPM: LDO, IBIAS, VAvg) e `VUCTIME`
e' gia' all'init. Da confermare sul device: se resta rumore anche cosi',
servono i dump dei registri nei due stati (`rf35h-regdump`). Il bit non e' documentato negli header; dal nome del registro
(MIXCTL) e dal tipo di rumore, probabilmente mescola l'ADC nel DAC.

`rf35h-i2c` (in rf35h-utils) e' il tool con cui si e' trovato: legge e scrive
un registro del PMIC anche mentre il kernel lo usa. Solo per diagnosi.

## Audio: il confronto col BSP di ArkOS, proprieta' per proprieta'

ArkOS4Clone ha audio pulito sullo stesso hardware, col kernel BSP 4.4 e il
driver codec del vendor. Confrontato il suo device tree col nostro e il driver
BSP col nostro:

**Stesso percorso**: anche ArkOS prende l'amplificatore esterno da HPOL/HPOR
("Headphone Jack" -> HPOL/HPOR nel routing), `mclk-fs = 256` come noi, stesso
GPIO dell'amplificatore (gpio3 pin 7). Quindi la differenza non e' *dove* passa
il segnale ma *con quali valori*.

**Proprieta' del vendor che noi non abbiamo** (dal nodo `codec` di ArkOS):

| proprieta' | valore | cosa fa nel driver BSP |
|---|---|---|
| `spk-mute-delay-ms` | **50** | `msleep(50)` PRIMA di accendere l'amplificatore e dopo averlo spento: il codec si assesta con l'ampli muto |
| `hp-volume` | 20 | scritto in `DDAC_VOLL/VOLR` (0x31/0x32) sul percorso cuffie: attenuazione digitale |
| `spk-volume` | 3 | idem sul percorso altoparlante |
| `volume-min-db` | 72 | fondo scala del controllo di volume |

Da noi l'amplificatore e' un `simple-audio-amplifier` che DAPM accende con
`POST_PMU` **senza alcun ritardo**, e il volume digitale del DAC e' quello
che lascia mainline. Il BSP inoltre pilota l'ampli dal driver del codec, in un
punto preciso della propria sequenza; noi lo deleghiamo a DAPM.

**Dal dump di ArkOS** (`tools/arkos-collect.sh` eseguito sul device):
registro per registro, `AREF_RTCFG1`, `VUCTIME`, mic/ADC e l'I2S coincidono
con quello che mainline produce a runtime (l'I2S `CKR` sembrava diverso, ma
`0x1f` e' solo il default della regmap: a runtime `bclk_ratio = 64` da'
`0x00033f3f` come ArkOS). **L'unica differenza e' il volume digitale del
DAC**: ArkOS tiene `DDAC_VOLL/R` a `0xb7` (`Playback Volume = 13` sulla sua
scala da -72 dB a passi di 3,75, cioe' circa -23 dB); noi partivamo dal
default mainline, vicino alla piena scala, dentro un amplificatore esterno a
guadagno fisso. Il "-16 dB" provato prima faceva registro `0x2b`: non era
nemmeno vicino.

**Bug mio, trovato ascoltando sul device.** Il controllo ALSA di mainline e'
dichiarato **invertito** - `SOC_DOUBLE_R_RANGE_TLV(..., 0x00, 0xff, 1, ...)` -
e `soc_mixer_ctl_to_reg()` scrive `registro = max - valore`. La prima versione
dello script ignorava l'inversione: il suo "100 %" scriveva registro `0x00`,
cioe' **muto**, e il "50 %" registro `0x7f`, inaudibile. Il "28 %" funzionava
solo per coincidenza, perche' la doppia inversione lo riportava vicino al
valore di ArkOS. Sul device: a 28 % si sentiva piano, a 50 % e 100 % nulla -
l'esatto contrario di una scala di volume.

**ATTENZIONE: l'analisi qui sopra e' SBAGLIATA, e la "correzione" che ne
derivava lo era altrettanto.** `DDAC_VOLL/R` e' un'**attenuazione**: `0x00` e'
il volume **massimo** e `0xff` il muto - misurato su ArkOS, dove alzando il
controllo il registro scende (controllo 13 -> registro 183, controllo 137 ->
registro 98). Il "100 % muto" e il "50 % inaudibile" non dipendevano dalla
scala: quei test erano viziati dal difetto del riarmo I2S, per cui suonava solo
la prima riproduzione dopo il boot. Avevo letto un bug come una scala.

Stato attuale: la percentuale e' **volume** (0 % = muto, 100 % = massimo),
passata diretta al controllo ALSA, che e' gia' invertito dal driver. Default
**28 % = registro 184**, il livello di fabbrica di ArkOS (il suo controllo vale
10; il 137 misurato in seguito era una regolazione manuale). Il valore e'
passato per due revisioni errate - 72 % e 62 % - prima di tornare al 28 %
iniziale, che era giusto. La scala mainline va da -95 dB a 0, circa 0,37 dB
per punto.

Nel menu: **Speaker Volume**, cursore **0-100 %** in Device Settings, accanto
ad Audio Output. La percentuale e' lineare sul registro del DAC (0..255), che
e' gia' in passi di dB: quindi percettivamente lineare, circa 1 dB per punto.
Default **28 %** = registro 71, il **default** del vendor (ArkOS ha 72: 0,375 dB
di differenza) - non un tetto: il controllo di ArkOS va oltre, e anche questo.
Avevo scritto nel sottotitolo "oltre puo' distorcere": era un'inferenza (un
class-D a guadagno fisso satura con pochi decimi di volt in ingresso, e il
vendor un motivo per quel default l'avra' avuto), non una misura. Tolta. Se
esiste un punto di saturazione lo si trova ascoltando - `speaker-test` con il
cursore a 28, 40, 52, 64, 76, 88, 100 - e in quel caso il 100 % del cursore
viene rimappato sul livello massimo pulito. Il sottotitolo dice che e' separato
dal Volume di RetroArch, che scala solo il mix software. Stesso stampo del cursore
della luminosita' (`setting_action_ok_uint_special`, rappresentazione `%u%%`),
passo 4 cosi' il default sta sulla griglia.

`rf35h-dac-volume 0-100` e' lo script dietro la voce: salva in
`/storage/.config/rf35h/dac-volume` e `--restore` lo applica all'avvio
(`ExecStartPre` di `rf35h-audio`, dopo l'attesa della scheda). `--raw 0-255`
per le prove sul registro, non salvato. Mainline etichetta il 28 % come
"-68 dB" perche' la sua tabella dB non coincide con quella del BSP (che chiama
lo stesso registro -23 dB): il registro e' quello che conta.

Per chiudere servono i registri **dal sistema che funziona**:
`tools/arkos-collect.sh`, da eseguire su ArkOS via ssh, fotografa codec e I2S a
riposo e mentre suona, mixer, clock, GPIO dell'ampli, e per la vibrazione
campiona il GPIO del motore durante un effetto (se oscilla e' PWM software, se
resta fisso e' on/off come da noi). Il diff registro per registro contro i
nostri e' la risposta, non un'altra ipotesi.

## Dal boot log: due cose che non sapevamo

**`rockchip-i2s: using zero-initialized flat cache, this may cause unexpected
behavior`** a ogni avvio. Isolato: `I2S_XFER` (0x1c) era l'unico registro
leggibile e non volatile assente da `reg_defaults`, quindi la prima lettura
cadeva su una voce di cache non valida e tornava zero. E' il registro che
**avvia e ferma il trasferimento**, toccato solo con `regmap_update_bits()`,
cioe' letto-modificato-scritto contro quella cache. Il valore di reset e' 0:
`r-027` lo dichiara. Da solo non spiega il fruscio, ma stiamo inseguendo una
corsa all'avvio dello stream e questo era un registro del percorso di avvio il
cui valore in cache poteva divergere dall'hardware: meglio toglierlo di mezzo
che discuterne.

**L'amplificatore esterno e' pilotato in modo diverso dal BSP.** Da noi e' un
device a parte (`simple-audio-amplifier`, `enable-gpios` su gpio3 pin 7) che
DAPM accende come `OUT_DRV` con evento `POST_PMU`. Nel BSP di ArkOS lo stesso
pin e' `spk-ctl-gpios` **sul nodo del codec**, e lo accende il driver del
codec dentro la propria sequenza, con un ordine noto. Stesso pin, stessa
polarita', catena di controllo diversa - ed e' il pezzo che sta fra il codec e
l'altoparlante, quindi il primo sospettato per un fruscio di fondo.

**La scheda audio si registrava a 19,6 s, il nostro servizio partiva a 18,2.**
Cioe' `rf35h-audio.service` girava **prima che card0 esistesse**. Causa: fra
tutta la catena audio solo `snd_soc_rockchip_i2s` e' un modulo (codec rk817 e
simple-card sono builtin), e lo caricava il coldplug di udev a 19,6 s -
mentre joypad, adc-keys e rk915 partono a ~5 s perche' li forziamo in
`modules-load.d`. Stesso rimedio: ora anche l'i2s e' li'. In piu'
`rf35h-audio.service` ha un `ExecStartPre` che aspetta `/proc/asound/card0`
(al massimo 20 s), perche' il probe resta comunque asincrono.

*(Superato. Questa era la cura a un sintomo. La causa vera, trovata dopo col
confronto con AURKNIX, era la kconfig: l'I2S compilato come modulo. Con
`CONFIG_SND_SOC_ROCKCHIP_I2S=y` il controller e' registrato prima che
`simple-audio-card` componga la scheda, e l'I2S non e' piu' in `modules-load.d`
- ci resta solo `adc-keys`. Anche `rf35h-audio.service` non e' piu' abilitato:
la commutazione cuffie/altoparlante la fa il kernel.)*

Il margine prima di RetroArch smette di essere di 3,4 secondi.

## Audio: il percorso NEON verificato numericamente

Dopo la patch 1004 e' stata segnalata distorsione. Il resampler e le
conversioni NEON sono stati **eseguiti** su arm64 (`qemu-aarch64`, codice
compilato dall'albero patchato, simboli `resampler_sinc_process_neon*`
presenti) e confrontati con il percorso C sullo stesso segnale: conversioni
s16↔float identiche al bit; resampler sinc identico entro 2,4·10⁻⁷ a cinque
livelli di qualita' e sei rapporti (1.0, 44.1→48, 32→48, 22.05→48, 32.768→48,
32.04→48). La 1004 non e' la causa. (`tools/neon-harness.c` e' il banco.)

## Menu con Select+Start: si apriva e si richiudeva

Due meccanismi sugli stessi tasti. Lakka per l'RK3326 accende la combo nativa
`input_menu_toggle_gamepad_combo = 4` (Select+Start), che scatta **alla
pressione**; il nostro autoconfig ha hotkey=Select e `menu_toggle`=Start, e in
RetroArch 1.22 quel toggle scatta **al rilascio** (*"Set menu toggle on
release"*, `input_driver.c`). Premendo si apriva, lasciando si richiudeva.

Tenuta la strada hotkey, spenta la combo per l'RF35H. Non il contrario,
perche' la combo non regge la hotkey su Select: dopo `input_hotkey_block_delay`
frame (5, ~83 ms) RetroArch toglie il bit di Select e la combo diventa falsa se
Select e' premuto un attimo prima di Start; il bit hotkey `RARCH_MENU_TOGGLE`
invece non viene bloccato. Il menu ora si apre **quando lasci** Start.

## Services: Bluetooth via anche da li'

Settings → Services ha un secondo toggle Bluetooth, in una lista fissa con un
`for`: si salta la voce quando `rf35h_present()`.

## Wi-Fi Access Point: il toggle esistente ora spegne davvero

Il toggle OFF di Lakka fa `connmanctl tether wifi off` **solo se** connman
riporta `Tethering = True`, e non tocca mai `/storage/.cache/services/
localap.conf`, il flag che al boot fa ripartire `localap.service`: spento dal
menu, al riavvio l'hotspot tornava. Con wpa_supplicant al posto di iwd lo
stato riportato e lo smontaggio dell'interfaccia AP non sono affidabili.

`rf35h-ap on|off|status`: off mette il flag da parte (`localap.conf.off`, nome
e password restano), spegne il tethering, verifica con `wpa_cli` (mode=AP), e
se l'interfaccia resiste spegne e riaccende la tecnologia Wi-Fi; on rimette il
flag e avvia il servizio. Il toggle **esistente** in Services lo chiama
(`localap_enable_toggle_change_handler`, solo se lo script c'e'): nessuna voce
nuova. Per `wpa_cli` il package wpa_supplicant non lo cancella piu' e il
demone parte con `-O /var/run/wpa_supplicant` (unit e file dbus, sed
verificato sui template della 2.11).

## Scraper: miniature per RetroArch, da devaOS

`rf35h-scrape` e' `lume/src/scraper.cpp` di devaOS portato a tool: stesso
parser JSON minimo, stesso CRC32 (dalla playlist se RetroArch l'ha calcolato,
altrimenti dal file fino a 64 MB), ScreenScraper con `systemeid` per
piattaforma, **ArcadeDB** di riserva per l'arcade (niente credenziali, niente
quote, risponde per id MAME). Cambiano ingresso e uscita, che sono di
RetroArch: legge `/storage/playlists/*.lpl`, scrive
`/storage/thumbnails/<playlist>/Named_Boxarts|Named_Snaps|Named_Titles/
<label>.png` con i caratteri `&*/:\`"<>?\|` → `_` come
`gfx_thumbnail_fill_content_img`.

Due decisioni di design diverse da devaOS, perche' il frontend e' diverso:
- **Niente "tipo di artwork"**: RetroArch mostra due miniature e l'utente
  sceglie quali in Settings → User Interface → Appearance. Si scaricano tutti
  e tre i tipi (`box-2D`/`ss`/`sstitle`; `flyer`/`ingame`/`title` da ArcadeDB).
- **Estensione dai byte veri**: RetroArch sceglie il decoder dall'estensione e
  cerca `.png` poi `.jpg`; una JPEG chiamata `.png` non la carica. Si legge la
  firma e si salva `.png` o `.jpg`; html di errore e altro si scartano.

Cartella: le regole di `gfx_thumbnail_set_content_playlist` — il `db_name`
della voce vince sul nome della playlist; se contiene `|` vale il primo; e
qualunque nome che inizia con **`MAME`** va in `thumbnails/MAME/` (un solo
repository di miniature MAME). Senza quest'ultima, "MAME 2010" avrebbe avuto
le immagini dove RetroArch non guarda. Provato con una playlist MAME 2010.

Regioni: preferenza `eu|us|jp|wor` (poi qualunque), dal menu o `--region`.

Credenziali: `/storage/.config/rf35h/scraper.conf` con `DEVID`/`DEVPASSWORD`
(developer ScreenScraper, come su devaOS non sono nel sorgente) e opzionali
`SSID`/`SSPASSWORD` per la quota. `rf35h-scrape --init` scrive il file
commentato. Stato in `scraper.status`, log in `scraper.log`.

Nel menu Device Settings: **Scrape Thumbnails** (azione), **Scrape Only
Missing Thumbnails**, **Scraper Region**. L'ordine delle undici voci segue i
gruppi: timer e luminosita', i tre LED, porta USB e audio, zram, i tre dello
scraper. Un controllo confronta l'elenco della displaylist con i setting
davvero creati (nessuna voce orfana) e verifica che ognuna abbia il suo
sottotitolo.

Come si integra con l'interfaccia, verificato nel codice di Ozone e RetroArch:
- L'azione **avvia una unit systemd** (`rf35h-scrape.service`, non abilitata,
  `systemctl start` con gli argomenti in `scraper.args`) e la ferma con
  `systemctl stop` se e' attiva. Non `system("... &")`: un figlio di RetroArch
  muore con lui a ogni restart, e "sta girando?" lo chiediamo a systemd
  (`/run/systemd/units/invocation:rf35h-scrape.service` esiste solo mentre la
  unit e' attiva), non a un file che dopo un crash puo' restare a "running".
- Il **sottotitolo** mostra lo stato dal vivo: Ozone chiama `menu_entry_get`,
  e quindi il nostro callback, a ogni frame. Il numero di righe pero' lo
  calcola una volta alla costruzione della lista: la riga di stato e' sempre
  presente e corta, cosi' l'altezza della voce non cambia. Se il file dice
  "running" ma la unit non e' attiva, mostra "interrupted".
- Le miniature compaiono senza riavviare: RetroArch le cerca su disco quando
  la voce della playlist viene selezionata.
- Errori che contano fermano il giro con un messaggio leggibile nello stato:
  credenziali rifiutate (401/403), quota esaurita (429/430/431).
- Niente CRC calcolato sugli archivi: sarebbe quello dello zip, non della ROM.
  Dalla playlist invece RetroArch mette il CRC del contenuto, e quello si usa.

Provato da capo a fondo contro un server locale che imita le due API: CRC e
regione preferita, ripiego ArcadeDB, cronologia saltata, solo-mancanti,
`--all`, JPEG salvata `.jpg`, html scartato, nessun `.part` residuo.

Trovato per strada: il Makefile di rf35h-utils installava due binari su
quattro (`rf35h-i2c` e `rf35h-rumble` non sarebbero finiti nell'immagine).
Riscritto con elenco esplicito, 5/5 verificato con install in una directory.

## Le patch del device tree: una sola

Erano otto: `z-010` creava il DTS e poi il device tree (`z-010`)..il device tree (`z-010`) **appendevano in coda
allo stesso file**, ognuna col contesto lasciato dalla precedente. Catena
fragile (una che non applica rompe tutte quelle dopo), e due blocchi `&joypad`
separati. Ora `z-010` porta il device tree completo, ogni regolazione col suo
commento. Il rifacimento e' stato verificato nell'unico modo che conta: **DTB
compilato e decompilato, identico** a quello della catena. Il build script
controlla che dentro z-010 ci siano ancora le due regolazioni piu' facili da
perdere (rumble e batteria).

**Pulizia**: tolti tre script usa-e-getta della fase Wi-Fi
(`wifi-probe/diag2/connect.sh`, con credenziali in chiaro, superati da
`rf35h-diag`); `probe-gitea.sh` e `repin-checksum.sh` — utili quando una forge
cambia il modo di generare gli archivi e lo sha256 pinnato non torna — sono
passati in `tools/`. `verify-kernel.sh` citava ancora `z-011`/`z-012`: ora
controlla dentro `z-010` tutte e sette le regolazioni della board, cosi' una
patch applicata a meta' si vede.

`z-001` (pannello ST7703) resta pur essendo **inerte**: il DTS usa
`rocknix,generic-dsi` (z-002) e il compatible `xifan,xf35h-panel` compare solo
in un commento. Verificato a fondo: `z-002` installa il driver con `obj-y +=
panel-generic-dsi.o`, quindi e' sempre compilato, senza simbolo Kconfig; e il
**DTB compilato** — l'artefatto che gira — dichiara un solo compatible,
`rocknix,generic-dsi`. E' l'alternativa se generic-dsi dovesse rompersi; costa
96 righe da riportare a ogni rebase. Se si preferisce, si toglie senza effetti.

## Confronto DTB con ArkOS4Clone (BSP 4.4), nodo per nodo

Fatto sui due DTB decompilati, confrontando i valori e non i nomi (i binding
dei due kernel differiscono). Identici: I2S/codec/MCLK, CPU OPP alle
frequenze in comune (816→1050 mV, 1008→1175, 1200→1300, 1296/1416→1350), GPU
OPP, thermal (70/85/115 °C), SD (UHS fino a SDR104), SDIO Wi-Fi, backlight
PWM, joypad (canali, mapping, deadzone, tuning), tabella OCV della batteria
(21 punti, 3300→4046 mV), resistenza di sense, soglie di sleep, tensione di
carica. Differenze trovate:

- **Batteria**: capacita' di progetto 3228 mAh e resistenza interna 115 mOhm
  (OEM) contro 3000/100: entrano nel fuel gauge → il device tree (`z-010`). Corrente di carica
  lasciata a 1,5 A (l'ingresso e' limitato a 1,5 A; il BSP dichiara 2 A solo
  come massimo del charger).
- **amux-b** dichiarato attivo-basso dall'OEM, come per il rumble: il driver
  ignora il flag, allineato lo stesso → il device tree (`z-010`). (Attenzione al banco: e'
  gpio2, non gpio3 — sbagliato una volta, preso dal DTB compilato.)
- **hp-det** polarita': *(verificato)* `Headphones Jack: off` a cuffie
  scollegate, cioe' la polarita' e' giusta
  (`hexdump /dev/input/event2` inserendo le cuffie).
- ArkOS espone OPP CPU 1440–1608 MHz (overclock del BSP) e 408 MHz; mainline
  si ferma a 1416. Non replicato.
- **DDR**: ArkOS ha una tabella devfreq 194→786 MHz; mainline non ha devfreq
  per la DRAM del px30, quindi la RAM resta alla frequenza fissata dal
  DDR-init del loader Rockchip. Se e' 333 MHz e non 786, e' la differenza di
  prestazioni piu' grossa di tutte. Da misurare sul device:
  `grep -E "dpll|ddr" /sys/kernel/debug/clk/clk_summary`.

## Opzioni kernel aggiunte

Dall'esame della config di Lakka per RK3326 (`kconfig-zram-gamepads-rf35h`):

- **zram**: la board ha 730 MB e nessuno swap attivo (quello di Lakka e' un
  file sulla SD: lento e logora la card). `rf35h-zram` crea meta' della RAM
  come swap compresso (~364 MB per ~900 MB di pagine), con `swappiness=100` e
  `page-cluster=0` perche' qui "swappare" non tocca il disco. Serve ai core
  grossi (mame2010, flycast, melondsds) per non finire uccisi dall'OOM killer.
  Acceso e spento dal menu (voce "Compressed RAM (zram)"), lo stato sopravvive
  al riavvio.

  **Algoritmo, misurato** (`tools/zram-bench.c`, eseguito su arm64 con qemu:
  i rapporti sono esatti, i MB/s valgono come confronto relativo):

  | algoritmo | rapporto | decompressione |
  |-----------|----------|----------------|
  | lz4       | 2,1-3,4x | **la piu' veloce** |
  | lzo-rle   | 2,2-3,4x | 3x piu' lenta |
  | zstd      | 3,2-4,4x | 4-5x piu' lenta |

  `lzo-rle`, il default del kernel, ha lo stesso rapporto di lz4 ed e' tre
  volte piu' lento a decomprimere: non ha senso qui. zstd comprime il 30-45%%
  meglio ma decomprime 4-5 volte piu' piano, e ogni page fault durante il
  gioco paga quella decompressione: **lz4**. Chi preferisce piu' RAM
  effettiva puo' mettere `ALGO=zstd` (e `PCT=`) in
  `/storage/.config/rf35h/zram.conf`.
- **Gamepad USB**: `JOYSTICK_XPAD` (+FF e LED), `HID_NINTENDO`,
  `HID_PLAYSTATION`, `HID_STEAM`. Senza, in modo host funzionano solo i pad
  HID generici — e i piu' diffusi fra chi emula non lo sono.
  `HID_PLAYSTATION` dipende da `LEDS_CLASS_MULTICOLOR`, che Lakka non ha:
  senza quello kconfig **lo scarta in silenzio**. Verificato eseguendo
  `make olddefconfig` sulla config risultante: tutti e 15 i simboli
  sopravvivono. Il build script controlla anche la dipendenza.
- **ntfs3**: chiavette e dischi USB in NTFS, con scrittura.

Gia' a posto e lasciate stare: `PREEMPT=y`, `HZ_300`, deadline e kyber,
`SND_USB_AUDIO`, exfat, il governor `ondemand` che Lakka tara da se'
(`up_threshold 50`, campionamento 100 ms). Scartate: `PSI` (contatori sempre
attivi che non leggiamo), `BFQ` (pensato per dischi rotanti).

## Revisione delle regressioni rispetto all'ultima immagine avviata

Dall'ultima immagine provata sul device sono cambiate molte cose. Rivisti i
punti in cui una modifica poteva rompere qualcosa che **funzionava**:

- **bluez tolto**: tutte le dipendenze nell'albero sono condizionali
  (`pipewire`, `pulseaudio`, `virtual/network`), e RetroArch non ne ha:
  `HAVE_BLUETOOTH=1` e' il suo menu, che sull'RF35H nascondiamo. Niente si
  rompe in compilazione e bluez esce davvero dall'immagine.
- **tasti volume** (li avevo gia' rotti una volta): il conteggio dei device
  attesi provato sul sorgente vero, includendolo in un banco di prova. Con la
  riga della unit: `firstdev=7`, **2 device attesi** (adc-keys e
  retrogame_joypad), modificatore 310 = L1. Aspetta entrambi, com'era
  l'intento.
- **nessuna unit nuova puo' bloccare l'avvio**: nessuna ha `Requires`,
  `BindsTo` o `Requisite`. Se zram non parte la sua unit risulta fallita e il
  boot prosegue; provato con il modulo assente, esce con 1 e un messaggio.
- **rf35h-ledd senza hardware**: zero tick di CPU in 5 secondi, non gira a
  vuoto.
- **celle del nodo dsi**: il `reg` del pannello resta 4 byte e il framework
  MIPI lo legge con `of_property_read_u32`, indipendente dal conteggio celle:
  il pannello si comporta come prima.
- **attesa Wi-Fi (1005)**: nel caso peggiore l'interfaccia resta ferma 25 s
  quando la password e' sbagliata. Prima rispondeva subito, ma sbagliando.

## Audit "non ho inserito altri bug": quattro trovati, tutti muti

Passata sistematica su tutto cio' che ho toccato dall'ultima immagine
funzionante, con una domanda sola: puo' rompersi a runtime?

1. **Variabili di shell nelle righe `Exec*` delle unit.** systemd espande `$var`
   PRIMA di passare la riga a `sh`, anche fra apici (per un `$` letterale
   serve `$$` - e io `$$` l'avevo usato per l'aritmetica, ma non per `$i`, `$f`,
   `$s`). Risultato: l'attesa della scheda audio in `rf35h-audio` era un
   **no-op** e il ripristino della vibrazione in `rf35h-state` **non avveniva
   mai**. Tolto lo sh inline: `rf35h-audio-wait` e `rf35h-vibra --restore`,
   script veri. Provati: 20 s senza scheda, 2 ms con; ripristino a 0 e
   default rispettato. Regola da qui in poi: **niente `$` nelle unit**, salvo
   `$SCRAPE_ARGS` che e' un'espansione voluta.
2. **`stat -c %Y` in `rf35h-crashlog`**: la busybox di Lakka non ha
   `FEATURE_STAT_FORMAT`, quindi il rate-limit non sarebbe mai scattato
   proprio nel restart loop in cui serve. Ora l'epoch sta in un sentinel.
   Aggiunto il PID al nome del file (due crash nello stesso secondo si
   sovrascrivevano). Provato: 3 crash in un secondo = 1 file; sentinel
   scaduto = nuovo file; sentinel corrotto = non si rompe; 10 snapshot = ne
   restano 8.
3. **Handler Rumble nel menu** scriveva lo stato in C senza garantire la
   directory. Ora passa da `rf35h-vibra`, che fa `mkdir -p`: una sola
   implementazione.
4. **`timeout` in `rf35h-rescue.sh`**: l'autostart che installa gira su Lakka,
   la cui busybox non ha `timeout`: la cattura di `retroarch --verbose`
   sarebbe fallita in silenzio. Sostituito con background + sleep + kill.

Controllo esaustivo di ogni comando esterno usato dagli script contro la
configurazione busybox di Lakka: nessun altro assente.

## Logging: mai piu' al buio

Due volte in un giorno il device e' rimasto senza GUI e senza modo di sapere
perche': il journal di Lakka sta su `/var`, che e' **tmpfs**, e si perde al
reboot; `retroarch.service` ha `Restart=always` e nessun `OnFailure`, quindi un
crash all'avvio e' un loop infinito e muto - sway con la barra (il "1" e
l'ora), niente RetroArch, niente da leggere. Da qui tre pezzi, tutti su
`/storage/rf35h-logs/` che sopravvive:

- **`rf35h-crashlog`**, agganciato con un drop-in `OnFailure=` su
  `retroarch.service`: a ogni morte di RetroArch scrive `crash-<data>.txt` con
  lo stato della unit, le ultime 60 righe di RetroArch nel journal, il dmesg
  con oops/BUG/"sleeping function"/segfault evidenziati, le unit fallite, gli
  stream audio aperti e le voci di `retroarch.cfg` che pesano all'avvio.
  **Rate-limit** a un file al minuto (col restart loop ne farebbe centinaia) e
  rotazione agli ultimi 8. Provato: tre chiamate in un secondo, un file.
  Ogni file comincia con **kernel, build (`BUILD_ID`), `boot_id` e stato
  dell'orologio**: senza RTC affidabile e con l'NTP spento la data puo' essere
  sbagliata di giorni (uno snapshot datato 29/9 era stato scritto il 23, e
  l'avevo scambiato per il boot piu' recente).
- **`LimitCORE=0`** nello stesso drop-in: systemd e' compilato senza coredump
  e sulla console non c'e' gdb, quindi il core non serviva, mentre ritardava
  di ~6 s lo spegnimento dopo un crash.
- **`rf35h-bootlog-late.timer`** a 90 s dal boot: `rf35h-bootlog` gira a ~20 s
  ed e' troppo presto per vedere RetroArch; questa e' la foto di quando la GUI
  dovrebbe essere su da un pezzo.
- **`log_verbosity = "true"`** nel `retroarch.cfg` di default per l'RF35H: cosi'
  l'ultima riga prima della morte finisce nel crash log. Si spegne da Settings
  > Logging quando il porting sara' stabile.

`tools/rf35h-rescue.sh` resta per il caso estremo: card nel PC, semina il Wi-Fi
in connman, accende ssh, e installa un autostart usa-e-getta che raccoglie la
diagnosi al boot successivo.

## GPU: la tabella del vendor, e perche' la batteria NON andava toccata

**GPU.** Mainline dichiara per il px30/RK3326 **un solo** punto operativo,
560 MHz a 1,15 V. Il nostro `z-010` ne aggiungeva gia' quattro piu' bassi
(200/300/400/480 MHz, 950-1125 mV) presi dalla tabella del vendor. Aggiunti
ora **520 e 600 MHz**, entrambi a 1,15 V: i 600 sono +7% di frequenza di picco
**senza alzare `vdd_logic` di un millivolt**, su un punto che il produttore
valida (tabella letta dal DTB di ArkOS4Clone). I 640 MHz restano fuori:
vogliono 1,2 V, e anche ArkOS si ferma a 600 (`max_gpufreq=600`).

Due cose emerse rivedendo la logica della patch:

- `mali-supply` e' **`&vdd_logic`**, il rail della logica dell'intero SoC, e su
  mainline nessun altro consumatore dichiara un minimo su quel rail: quando il
  devfreq sceglie un OPP basso, la tensione scende per tutti. Verificato che il
  vendor usa lo **stesso** rail con gli **stessi** limiti (950-1350 mV), e che
  i punti bassi erano gia' nel nostro device tree e la console ci gira da
  sempre. I due punti aggiunti ora stanno a 1,15 V, quindi non spostano il
  rail di nulla.
- la prima stesura creava un **secondo** blocco `&gpu_opp_table` in coda al
  file invece di estendere quello esistente. Legale in DTS - i nodi si
  fondono - ma confonde chi legge. Uniti in uno solo.

**Batteria: nessuna correzione, e la mia diagnosi precedente era sbagliata.**
Avevo scritto che l'indicatore segna pieno in anticipo, confrontando la cima
della nostra tabella OCV (4,047 V) con il `vfull_chg=4219` del log di ArkOS.
Sono grandezze diverse: la tabella OCV mappa la tensione **a riposo**, i 4,2 V
sono la tensione di **fine carica**. Verificato sul DTB di ArkOS: il suo
`ocv_table` ha gli stessi 21 valori del nostro (3300...4046 mV), il suo
`design_capacity` e' 3228 mAh come il nostro, e `max_chrg_voltage` 4200 mV
coincide con il nostro `constant-charge-voltage-max`. I dati erano gia' quelli
OEM.

## Le scritture i2c dirette sull'rk817: cosa e' andato storto

Durante la diagnosi dell'audio ho proposto scritture dirette nei registri del
codec con `rf35h-i2c`. E' stato un errore di valutazione, e il conto e' arrivato
in giornata: audio distorto su **entrambe** le uscite e su **entrambi** i
sistemi operativi, per ore, finche' un evento di alimentazione non ha ripulito
lo stato.

Il meccanismo: l'rk817 e' insieme PMIC e codec. I registri analogici che
avevamo toccato - stadio cuffie (`0x3d`), pompa di carica (`0x3f`), class-D
(`0x40`/`0x41`) - **non vengono riscritti da nessun driver all'avvio**, e la
PMIC resta alimentata dalla batteria anche a console spenta: un `poweroff` non
la azzera. Quelle scritture sono quindi sopravvissute ai riavvii e hanno
seguito la console anche avviando ArkOS, che con il nostro software non
condivide niente.

`rf35h-i2c` ora **rifiuta** le scritture verso il codec (bus 0, indirizzo
0x20, registri 0x10-0x4f) con un messaggio che spiega perche', e suggerisce
`rf35h-dac-volume` per il volume. La lettura resta libera - serve alla
diagnosi e non ha effetti. Per i casi consapevoli: `RF35H_I2C_FORCE=1`. Il
controllo sta **prima** di aprire il bus, cosi' rifiuta senza nemmeno toccare
il device. Provato nei cinque casi: scrittura al codec rifiutata (uscita 3),
lettura ammessa, forzatura ammessa, altro indirizzo ammesso, registro fuori
intervallo ammesso.

## AURKNIX: il confronto giusto, e cosa ne e' uscito

ArkOS gira su BSP Rockchip 4.4, quindi ogni sua scelta andava tradotta.
**AURKNIX** (`lcdyk0517/distribution_aurknix`) e' invece un fork di ROCKNIX -
kernel **mainline**, stesso stack ALSA del nostro - e supporta esplicitamente
XiFan RF35H. Confronto diretto, senza traduzione.

Cosa si e' scoperto:

- il loro `rk3326-xifan-rf35h.dts` include `xf35h.dts`, e la sezione audio e'
  **identica alla nostra riga per riga** - stesso amplificatore, stesso GPIO,
  stesso routing, perfino lo stesso commento sul doppio canale. Il nostro DTS
  viene da li' ed e' corretto.
- fra le loro patch kernel per RK3326 ci sono `024-rk915` e `025-mipi` (le
  nostre `r-024` e `r-025`), ma **nessuna patch al codec rk817**. Il driver
  mainline cosi' com'e', su questo hardware, produce audio funzionante.
- usano il kernel **6.12.79**, noi 7.0.1. Verificato che non conta: il driver
  del codec e' identico fra le due versioni salvo la ridenominazione di due
  costanti DAIFMT, e `rockchip_i2s.c` differisce solo per la mia `r-027` e una
  macro PM rinominata. **Nessuna regressione.**
- la differenza vera e' nella **kconfig**:
  `CONFIG_SND_SOC_ROCKCHIP_I2S` da loro **`=y`** e da noi `=m`;
  `CONFIG_SND_SOC_SIMPLE_AMPLIFIER` da loro `=m` e da noi `=y`. L'ordine di
  probe cambia di conseguenza: con l'I2S nel kernel il controller e' gia'
  registrato quando `simple-audio-card` compone la scheda. E' anche il motivo
  per cui avevamo dovuto aggiungere `snd_soc_rockchip_i2s` a `modules-load.d`:
  un rattoppo a un problema di tempi che da loro non esiste.

- **AURKNIX non ha alcun `headphone-sense`**, ne' un equivalente: su questo
  hardware la commutazione cuffie/altoparlante la fa il **kernel da solo** -
  `simple-audio-card` registra il jack da `hp-det-gpio`, e il `pin-switch` su
  "Internal Speakers" piu' le route DAPM fanno il resto. Il nostro
  `rf35h-audio.service` eseguiva invece `headphone-sense` ereditato da
  `odroidgo2-utils`, che forza con `amixer` gli stessi controlli che DAPM sta
  gestendo. Combacia con quanto visto sul device: dopo aver collegato e
  scollegato le cuffie l'altoparlante restava muto, con `Headphones Jack: off`
  e `Internal Speakers Switch: on`, cioe' uno stato coerente ma silenzioso.
  Il servizio non viene piu' abilitato (il file resta, `systemctl enable --now
  rf35h-audio` lo riattiva). Il ripristino del volume, che stava li' dentro,
  e' passato a `rf35h-dacvol.service`, che non tocca nulla se l'utente non ha
  mai spostato il cursore - di nuovo come AURKNIX, che all'avvio non imposta
  alcun volume.
- i quirks del device (`XiFan RF35H` -> `XiFan XF35H` -> `XiFan XF40H`)
  definiscono `DEVICE_PLAYBACK_PATH_SPK="HP"` e `..._HP="SPK"`, ma senza
  `DEVICE_PLAYBACK_PATH` a dire su quale controllo agire, e nel loro albero
  nessun codice legge quelle variabili: sono vestigiali di JELOS.

**Secondo giro sulla kconfig, allargato oltre l'audio.** Confrontando tutte e
~2000 le opzioni attive delle due distribuzioni sono emerse tre differenze che
contano:

- **`CONFIG_DEBUG_PREEMPT=y`** in Lakka, assente in AURKNIX. E' un'opzione di
  **debug**: inserisce un controllo a ogni operazione su `preempt_count`, cioe'
  a ogni presa e rilascio di lock in tutto il kernel. Sovraccarico continuo che
  colpisce per primi i percorsi a bassa latenza - il trasferimento DMA di un
  flusso audio tra questi - e su un Cortex-A35 a 1,2 GHz non e' trascurabile.
  E' il candidato migliore per un audio **granuloso anziche' assente**: non un
  errore di configurazione del percorso, ma di tempi.
- **`CONFIG_DEBUG_GPIO=y`**, altro debug acceso senza motivo in produzione.
- **`CONFIG_SND_SOC_ROCKCHIP=m`** contro il loro `=y`: e' il contenitore di
  `ROCKCHIP_I2S`, e lasciarlo modulo riportava parte della catena a dipendere
  dal caricamento tardivo che l'allineamento precedente voleva eliminare.

  > **Correzione (migrazione alla 7.2.7):** questo punto era sbagliato.
  > `SND_SOC_ROCKCHIP` non esiste come simbolo ne' nella 7.0.1 ne' nella
  > 7.2.7: `sound/soc/rockchip/Kconfig` e' un semplice `menu "Rockchip"`, non
  > un `menuconfig`, quindi non "contiene" `ROCKCHIP_I2S` e portarlo a `=y` non
  > aveva alcun effetto (`olddefconfig` lo scarta su entrambi i kernel).
  > L'opzione che contava era `SND_SOC_ROCKCHIP_I2S=y`, che resta. La riga
  > morta e' stata tolta da `kconfig-debug-off-rf35h.patch`.

`CONFIG_PREEMPT=y` resta invece com'e', benche' AURKNIX usi `PREEMPT_VOLUNTARY`:
la preemption piena *riduce* la latenza, che e' cio' che serve all'audio.
Allinearla sarebbe imitazione, non ragionamento.

Conseguenza: `kconfig-audio-aurknix-rf35h.patch` allinea le due opzioni,
`r-026` e `r-027` sono spostate in `optional/`, e il rattoppo `modules-load.d`
e' rimosso. Le patch kernel attive sono ora **esattamente quelle di AURKNIX**
piu' il nostro DTS.

## Bootloader, driver e cmdline: il resto del confronto

- **Driver condivisi identici**: `rocknix-joypad` e `rk915` sono allo stesso
  commit esatto (`7f3272ff` e `e2fd6165`). Nessuna divergenza.
- **u-boot**: entrambi su `v2025.10`.
- **Il problema del loader e' riconosciuto anche a monte.** ROCKNIX ha un
  `update.sh` proprio per RK3326 che, invece di sovrascrivere ciecamente,
  **rilegge i primi 32 K dalla card e li rimette identici** prima di scrivere
  il resto: `{ dd if=$BOOT_DISK bs=32K count=1; cat $BOOT_IMAGE; } | dd
  of=$BOOT_DISK bs=4M`. Noi usiamo il generico di Rockchip, che fa `bs=32k
  seek=1` e ha rotto la console. La nostra soluzione - il known-good dentro il
  SYSTEM, cosi' che quel dd riscriva byte identici - arriva allo stesso
  risultato per altra via, ed e' verificata idempotente.
- **Ordine delle console nel cmdline**: ROCKNIX mette `console=tty0` per
  **ultima**, quindi `/dev/console` (lo stdout dei processi) e' lo schermo.
  Noi abbiamo `tty0` per prima e la seriale per ultima - ecco perche'
  l'avanzamento dell'aggiornamento non si vedeva. **Non allineato di
  proposito**: mettere tty0 per ultima farebbe comparire l'output di systemd
  sullo schermo anche durante un avvio normale, sovrascrivendo lo splash. La
  nostra patch all'init ottiene la stessa visibilita' *solo* durante
  l'aggiornamento, che e' piu' mirato. E il nostro `ttyS1` al posto del loro
  `ttyS2` resta corretto: su questa board ttyS2 va al microcontrollore, e
  `systemd.debug_shell=ttyS2` aprirebbe una shell di root verso di esso.
- **Compositore: provato sul device, NON funziona. Indagato fino in fondo,
  causa non trovata.** Attivando la patch KMS la GUI non parte: RetroArch
  esce con status 1 dopo ~300 ms, in un ciclo di riavvii. L'analisi che avevo
  fatto prima - che `graphical.target` si attiva comunque perche'
  `retroarch.target` lo dichiara in `Requires` - era corretta ma
  **incompleta**, e l'ho attivata come predefinita invece di lasciarla da
  provare isolata, come io stesso avevo scritto che andava fatto.

  Cosa e' stato accertato, per chi riprendera' la patch:

  - il percorso **DRM funziona**: `[DRM] Connector 0 connected: yes`, 12
    modalita' a 640x480. I due `Couldn't get device resources` iniziali sono
    la scansione dei nodi senza CRTC, non un errore.
  - **non sono librerie mancanti**: `ldd /usr/bin/retroarch` e' pulito.
  - **GBM c'e'**: 17 riferimenti in `libEGL_mesa.so`.
  - **glvnd e' completo**: `50_mesa.json` presente in
    `/usr/share/glvnd/egl_vendor.d/`, dispatcher e vendor Mesa installati.
    (Era la mia ipotesi principale, smentita dai fatti.)
  - **tre nodi DRM** presenti: `card0`, `card1`, `renderD128`.
  - **`GRAPHIC_DRIVERS="mali panfrost"`**, identico a ROCKNIX, che senza
    compositore su questo stesso hardware funziona.
  - fallisce solo `eglGetPlatformDisplay`, con `EGL_SUCCESS`: nessun errore
    impostato, che e' il comportamento di EGL quando la piattaforma richiesta
    non e' utilizzabile.

  **Prossimo passo se si riprende**: `EGL_LOG_LEVEL=debug retroarch --verbose`
  per vedere quale driver Mesa tenta di caricare e perche' rinuncia. Serve
  debug a livello Mesa, oltre quello che si ricava leggendo i package.mk.

  La patch resta in `optional/kms-no-compositor.patch`, applicabile con
  `--kms`. Da provare **da sola**, con `rf35h-reflash-system.sh` a portata.

- Le patch di ROCKNIX a RetroArch (`0002-quit-not-restart`,
  `0003-fix-oga-no-preferred`, dimensioni dei menu) non toccano l'audio.

## Confronto sistematico con ArkOS: cosa diverge davvero

Passata sul dump di ArkOS4Clone, cercando incongruenze oltre l'audio.

**Coincidono** (nessuna azione): il periodo PWM della retroilluminazione
(25000 ns in entrambi); la taratura del joypad - deadzone 64, fuzz 32, flat 32,
e **poll-interval 10 ms**, che avevo creduto diverso finche' non ho visto che
il `<60>` del nostro DTS appartiene ad `adc-keys`, cioe' ai due tasti volume,
non allo stick; il DDR (`clk_ddrphy4x` 656 MHz da loro, 664 da noi, quindi
niente devfreq piu' aggressivo da recuperare); la CPU a 1,2 GHz.

**Divergono**:

- **Input boost**: nei dispositivi input di ArkOS compaiono i gestori
  `dmcfreq` e `cpufreq` accanto a `event0` e `event2` - il BSP Rockchip alza
  CPU e DDR a ogni evento di input. Mainline non ha un equivalente; si puo'
  avvicinare solo con la scelta del governor.
- **GPU**: *(superato)* il 600 MHz del vendor e' stato **aggiunto** a
  `z-010`, alla stessa tensione dei 560 (1,15 V). Vedi la sezione GPU.
- **Batteria**: *(superato - non c'era nulla da correggere)* confrontavo la
  cima della tabella OCV (tensione **a riposo**, 4,047 V) con `vfull_chg`
  (tensione di **fine carica**, 4,219 V): grandezze diverse. La tabella OCV e'
  identica a quella OEM di ArkOS, valore per valore.
- **Vibrazione**: ArkOS espone `rumble_period` (PWM per l'intensita'); il
  nostro driver fa solo acceso/spento. *(Verificato in seguito: ROCKNIX usa
  lo stesso meccanismo - e' il driver `rocknix-joypad` su mainline, non una
  nostra mancanza.)*

## Vibrazione: come funziona davvero sull'RF35H, e la voce nel menu

Catena verificata pezzo per pezzo: core -> interfaccia rumble di libretro ->
driver `udev_joypad` di RetroArch, che manda effetti `FF_RUMBLE` standard con
`EVIOCSFF` -> `ff-memless` nel kernel -> `rumble_play_effect()` del driver
rocknix -> GPIO3_A6. Il device dichiara `FF_RUMBLE`, `FF_PERIODIC` e `FF_GAIN`
(`B: FF=107030000`), quindi RetroArch lo vede come pad con vibrazione. Tutto
conforme.

**Il punto che cambia le aspettative**: nel nostro device tree il motore ha
`rumble-gpio` ma **nessun PWM**. Il driver, con un GPIO valido, fa solo
`gpio_set_value(1/0)`: `if (level) start else stop`. Qualunque intensita'
diversa da zero e' **piena forza**. Quindi il cursore *Rumble Gain* di
RetroArch (Settings > Input, 0-100 %) qui e' un interruttore mascherato da
regolatore: 0 % spegne, dall'1 % al 100 % e' identico. Non e' un bug nostro
ne' di RetroArch - e' l'hardware - ma un utente che mette 30 % aspettandosi
meno vibrazione resta deluso. (ArkOS sullo stesso hardware ha lo stesso
`rumble-gpio` senza PWM: anche li' e' on/off.)

Il driver espone gia' l'interruttore giusto:
`/sys/devices/platform/rocknix-singleadc-joypad/rumble_enable`. La voce
**Rumble** in Device Settings lo scrive direttamente (via VFS, come la
luminosita'), salva lo stato, e il sottotitolo dice chiaro che qui e' o spento
o a piena forza. `rf35h-state` lo ripristina al boot, perche' il driver riparte
sempre a 1. La voce legge la verita' dal sysfs, non dal file.

Non implementato: intensita' vera via PWM software (toggle del GPIO con un
hrtimer). Fattibile nel driver, ma e' un progetto a se' e un motore ERM su
GPIO ha comunque poca dinamica.

## Device Settings: da piatto ad albero

    Device Settings
    +- Sleep Timer, Screen Brightness, USB-C Port, Audio Output, Compressed RAM
    +- LED Settings      -> Joystick LEDs, Status LEDs, LED Effect Speed
    +- Thumbnail Scraper -> Scrape Thumbnails, Only Missing, Region
    +- Network Time      -> NTP, Time Server

Lo fa un **secondo generatore**, `tools/gen-retroarch-rf35h-submenus.py`, da
eseguire DOPO `gen-retroarch-rf35h-menu.py`. Perche' due stadi: nel primo le
stesse stringhe compaiono in 4-5 punti e i tentativi di aggiungere i sottomenu
li' dentro sono falliti due volte su ancore ambigue; nel secondo ogni ancora e'
una riga che il primo ha appena scritto, quindi unica e nota - e `edit()` si
ferma se ne trova zero o piu' di una. Al primo colpo: tutte le ancore trovate
esattamente una volta.

Scelta di progetto: le impostazioni **restano tutte** in `SETTINGS_LIST_RF35H`.
`menu_displaylist_parse_settings_enum()` le trova per enum ovunque siano, e i
sottomenu sono displaylist che le elencano; tagliare blocchi `CONFIG_*` da una
`case` per incollarli in un'altra era l'operazione a piu' alto rischio e non
cambia nulla di cio' che l'utente vede. Le liste native (VIDEO, AUDIO) hanno una
`SETTINGS_LIST` propria: differenza di raggruppamento interno, non di
comportamento, fattibile in un terzo passo se servira'.

**Bug trovato sul device al primo test**: i sottomenu si aprivano su "Parent
directory" + "Directory not found". Causa: a ogni sottomenu avevo dato la
stringa della sua label (`"rf35h_led_settings"`) ma **non quella della lista
differita** (`"deferred_rf35h_led_settings_list"`), che il padre invece ha.
Al push RetroArch fa `info_label = msg_hash_to_str(deferred_enum)`; senza
stringa torna "null", e il deferred push viene agganciato **per stringa** con
la guardia `if (!string_is_equal(label, "null"))` - quindi nessun binding, e la
label viene trattata come percorso di directory. Confronto per file fra padre
e figlio (conteggio delle occorrenze in ognuno dei 12 file toccati): l'unica
differenza vera era in `msg_hash_lbl.h`. Corretto nel generatore.

Il controllo che l'avrebbe preso, ora permanente: `tools/check-menu-labels.py`
verifica nel preprocessato di `intl/msg_hash_us.c` (dove `msg_hash_lbl.h` e'
incluso dentro lo switch - cercarlo in `msg_hash.c` dava falsi positivi anche
sul padre funzionante) che ognuno dei 22 enum RF35H abbia la stringa. Provato
nei due sensi: passa sul sorgente corretto, fallisce con i tre mancanti su
quello rotto. Il build script fa lo stesso controllo sulla patch.

Verificato: **17 voci mostrate = 17 setting creati**, nessuna orfana; sottotitolo
(bind + stringa) per tutte e 16; stringhe inglesi e italiane nel preprocessato;
catena `action_ok -> title -> deferred push` completa per i tre sottomenu; 9
file compilano. Il build script controlla che la 1003 contenga i sottomenu: se
qualcuno la rigenera col solo primo stadio, si ferma e dice quale manca.

Per rigenerare la 1003 (questa procedura riproduce il file byte per byte):

    cp -r retroarch-pristine src
    python3 tools/gen-retroarch-rf35h-menu.py src
    python3 tools/gen-retroarch-rf35h-submenus.py src
    (cd retroarch-pristine && find . -type f | sort | sed 's|^\./||') | while read -r f; do
      cmp -s "retroarch-pristine/$f" "src/$f" ||
        diff -u --label "a/$f" --label "b/$f" "retroarch-pristine/$f" "src/$f"
    done > retroarch-1003-rf35h-settings-menu.patch

### Il crash all'uscita (`free(): invalid pointer`)

Fino al 23/9 RetroArch moriva di `SIGABRT` **a ogni uscita** (riavvio,
spegnimento): 4 crash su 4 uscite registrate, tutti con `free(): invalid
pointer` subito dopo `Stopping retroarch.service`. La causa era nella 1003.
`config_string_options()` marca i `values` con `SD_FREE_FLAG_VALUES`,
`setting_string_setting_options()` ne conserva il puntatore senza copiarlo
(`result.values = values`), e all'uscita `menu_setting_free()` lo passa a
`free()`. I chiamanti originali passano memoria allocata
(`config_get_*_options()`); le nostre sette opzioni a tendina passavano
**costanti** come `RF35H_LED_SPEEDS`. Ora passano `strdup(...)`, nel
generatore e quindi nella patch.

L'avevo escluso cercando `free()` solo nelle righe *aggiunte*: il `free` era nel
codice originale, e scattava sui dati nostri. Verifiche: `free()` di una
costante sulla glibc da' esattamente il messaggio del device e stato 134
(`SIGABRT`), con `strdup` esce pulito; la 1003 rigenerata con i due stadi
differisce dalla precedente solo per le 7 righe e il commento; `menu_setting.c`
compila con `HAVE_LAKKA` senza errori ne' avvisi; tre controlli in
`verify-claims.sh`, che falliscono sulla versione vecchia.

### Il SEGV del 22/9 nel menu Wi-Fi

Il 22/9 RetroArch e' morto di `SIGSEGV` due minuti e mezzo dopo una ripresa
dalla sospensione, 7 s dopo che il menu Wi-Fi aveva lanciato `connmanctl`. Uno
stack non c'e', ma `connmanctl.c` offre due strade verso quel segnale, entrambe
nella chiamata che chiude una scansione:

- **`popen()` mai controllato**: 13 chiamate, nessuna verifica. Se il fork
  fallisce, per esempio sotto pressione di memoria (quella sessione era a 496 MB
  con 85 MB in swap), `fgets(..., NULL)` e `pclose(NULL)` sono un SEGV.
  Riprodotto: con `popen` che fallisce, la versione precedente muore con stato
  139, cioe' `SIGSEGV`.
- **una lista condivisa senza lock**: i task Wi-Fi (scansione, attivazione,
  connessione) girano in un altro thread, e `refresh_services` liberava la
  lista delle reti prima di rileggerla, mentre il menu la scorre dal thread
  principale. La 1005 allargava molto la finestra: le sue attese ricostruivano
  la lista ogni 300 ms per fino a 25 s.

La 1008 controlla `popen` nei percorsi frequenti (`refresh_services`, i cinque
`pclose(popen())`, `tether_status`), costruisce la lista a parte e la scambia
alla fine, scarta le righe troppo corte e libera la `string_list` vuota. La 1005
ora interroga `connmanctl` con una lettura privata e aggiorna la lista una sola
volta, come il codice originale.

Dal secondo giro sono chiusi anche i sei `popen` restanti (`get_connected_ssid`,
`get_connected_servicename`, `tether_toggle`, `tether_start_stop`), con tre
difetti trovati lungo la strada: `tmp` mai liberato se nessun servizio era
attivo; un underflow che, con `ln` vuoto, scriveva un byte prima dell'array
sullo stack; `ap_name` e `pass_key` non inizializzati, passati a
`tether_toggle` e controllati con un `!ap_name` sempre falso.

La 1009 chiude la corsa con `driver_wifi_list_lock()`: un mutex preso dal driver
e dai tre punti del menu che leggono la lista, che lavorano su una copia e lo
rilasciano prima di accodare il task. La finestra della password ora ritrova la
rete per id di connman: per indice, una scansione che riordinava la lista
mentre si digitava mandava la password a un'altra rete, e un fallimento ne
cancellava la configurazione salvata.

Verifiche: 21 test del comportamento sul `connmanctl.c` vero, con un
`connmanctl` finto e `popen` fatto fallire a comando; ThreadSanitizer con un
thread che ricostruisce la lista 40 volte e uno che la legge come il menu, per
oltre 116 000 letture: 0 corse con il lock, 6 senza; compilazione con
`HAVE_LAKKA` e `HAVE_WIFI` (senza `HAVE_WIFI` il codice Wi-Fi del menu non si
compila affatto, e il controllo sarebbe stato vuoto), nessun avviso nuovo.

### Salvataggio atomico della configurazione (1010)

`config_file_write` apriva il file con `fopen("wb")`, che lo svuota subito, e non
controllava alcun errore. Riprodotto con la funzione vera: un crash dopo 100 000
dei 220 890 byte di una configurazione da 6000 chiavi lasciava il file a
**0 byte**. Su Linux ora si scrive `<path>.tmp` con i permessi del file che si
sostituisce, si controllano `fflush`, `ferror`, `fsync` e `fclose`, e solo
allora lo si rinomina sopra l'originale. Stesso crash: file intatto. Il
contenuto scritto e' identico byte per byte a prima; un errore restituisce
`false` e lascia la configurazione da salvare; un collegamento simbolico resta
tale. Vale per ogni file scritto con questa funzione: quelli di
`configuration.c` (`retroarch.cfg` compreso), i preset degli shader, i trucchi
e i file di `runloop.c`.

### Le tendine del menu tornavano vuote a ogni riavvio (1003)

Le 7 impostazioni a tendina del menu (LED degli stick e di stato, velocita'
degli effetti, server NTP, modalita' USB, uscita audio, regione dello scraper)
erano registrate in `configuration.c` con `handle=false`, copiato dallo schema
dei bool, dove non conta nulla. Per gli array quel flag decide invece se la
chiave si rilegge da `retroarch.cfg`: RetroArch non le rileggeva, il menu le
mostrava vuote e il salvataggio successivo scriveva il vuoto. Il dispositivo non
ne risentiva, perche' gli script conservano lo stato in `/storage/.config/rf35h`
e `rf35h-state` lo ripristina al boot; ma scorrendo una tendina vuota si partiva
da una posizione arbitraria.

Ora `handle=true`, e all'avvio una chiave vuota o assente prende lo stato reale:
il file dello script (`led`, `statusled`, `ledspeed`, `ntp-server`, `usb`), per
`audio_out` il valore di `audio_device`, altrimenti il predefinito. Il valore
letto da file si accetta solo se e' una parola di minuscole, cifre, `.` e `-`.
Verifiche: 10 casi sulla funzione estratta dal file generato, con i veri
`settings_t` e `config.def.h`; `configuration.c` compila con `HAVE_LAKKA` senza
avvisi; la 1003 rigenerata differisce dalla precedente solo in
`configuration.c`, nei tre punti previsti.

## Il menu confrontato con quelli nativi di RetroArch

Prima di costruirci sopra i sottomenu, confronto con come RetroArch fa le
proprie liste di impostazioni (`SETTINGS_LIST_DRIVERS`, `_VIDEO`, `_AUDIO`):

- **Il `CONFIG_ACTION` che apre il menu sta al posto giusto**:
  `SETTINGS_LIST_MAIN_MENU`, esattamente dove RetroArch mette quello di
  `DRIVER_SETTINGS`.
- **La lista chiude bene**, con `END_SUB_GROUP` e `END_GROUP`.
- **Mancava una riga**: dopo `START_GROUP` le liste native chiamano
  `MENU_SETTINGS_LIST_CURRENT_ADD_ENUM_IDX_PTR`, che assegna l'`enum_idx` al
  gruppo; senza, il gruppo non e' rintracciabile con
  `menu_setting_find_enum()`. Lo fanno 31 delle 56 liste - fra cui VIDEO e
  AUDIO, cioe' proprio quelle dello stesso tipo della nostra. Aggiunta;
  verificata nel **preprocessato**, non solo nel sorgente.

Verificato anche il resto dell'implementazione contro le pratiche di RetroArch:

| aspetto | come lo facciamo | precedente nativo |
|---|---|---|
| lettura dei file di stato | `filestream_open/gets/close` (VFS) | `configuration.c`, 20 usi |
| esecuzione di comandi | `system("... &")` | `retroarch.c` per lo shutdown Lakka, stesso schema `nohup ... &`; 40 usi in tutto |
| tendine a scelta | `CONFIG_STRING_OPTIONS` + `action_ok = setting_action_ok_uint` | `TIMEZONE` e `APPICON_SETTINGS`, identico riga per riga |
| visibilita' a runtime | `build_list[i].checked = rf35h_present()` | 131 usi di `.checked` in `menu_displaylist.c` |
| sottotitoli | `DEFAULT_SUBLABEL_MACRO` + `BIND_ACTION_SUBLABEL` | tutto il menu |
| persistenza | `SETTING_BOOL/UINT/ARRAY` in `configuration.c`, default in `config.def.h` | tutte le impostazioni |

Il costruttore nativo di `STRING_OPTIONS` **non** assegna `action_ok`: impostarlo
dopo e' la pratica attesa, e il blocco di `TIMEZONE` e' identico al nostro
riga per riga (`action_ok` + `change_handler`). `systemd_service_toggle` usa
`fork`+`execvp` invece di `system()`, ma i nostri comandi usano `&` e le
redirezioni della shell, e RetroArch stesso fa cosi' nello stesso caso:
allinearsi costerebbe codice senza cambiare comportamento.

Questo fissa anche lo schema per i tre sottomenu: `CONFIG_ACTION` nella lista
del padre (`SETTINGS_LIST_RF35H`), e per ognuno una propria
`SETTINGS_LIST_RF35H_*` con il suo `START_GROUP` e la sua macro - esattamente
come RetroArch annida i propri.

## Le patch generate: riproducibili e nel formato giusto

Proprieta' che non avevo mai verificato: **i generatori sono deterministici**.
Due esecuzioni indipendenti di `gen-retroarch-rf35h-menu.py` producono la
stessa patch byte per byte, e coincide con quella spedita; idem per
`gen-retroarch-arm64-fixes.py`. Senza questo, "la patch nel tarball e' quella
verificata" non vorrebbe dire niente.

Le patch **generate** restano diff nudi, come quelle di Lakka: cosi' la prova
di riproducibilita' e' un semplice confronto. Le **scritte a mano** portano il
loro perche' in testa, nel formato del kernel.

Passate a `scripts/checkpatch.pl` del kernel: mancava il separatore `---` fra
messaggio e diff, e i messaggi sforavano le 75 colonne. Sistemato su 18 patch
— `r-026` passa da 2 errori a **0**. Il riformattatore tocca solo
l'intestazione: verificato confrontando i corpi diff prima e dopo, **identici
byte per byte**, e rieseguendo andata e ritorno a fuzz 0 e la prova del DTB.

**Un difetto vero trovato applicando lo stesso standard**: il nodo `&dsi` non
dichiarava `#address-cells`/`#size-cells`. Il pannello e' suo figlio, quindi
dtc ereditava i default della radice (2 e 1), avvisava che il `reg` del
pannello ha lunghezza sbagliata e — peggio — saltava **quattro altri
controlli** come "prerequisito fallito": su quelli eravamo ciechi. Ogni board
mainline con un pannello DSI le dichiara, Odroid Go 2 compreso. Aggiunte:
**da 6 avvisi dtc a 0**, e il DTB cambia esattamente di due proprieta', niente
altro. Corretto anche in devaOS.

Le patch che arrivano da devaOS sono **nostre**, quindi allo stesso standard.
`z-010` aveva **87 errori di spazi in fondo alle righe** nel DTS: tolti qui e
nel sorgente devaOS insieme, cosi' i due progetti non divergono (verificato
che i due file restino identici). Da 88 errori a **zero**; restano 20 avvisi
sullo stile dei commenti a blocco. La prova che non ho cambiato altro:
confronto riga per riga contro il file con i soli spazi rimossi, e **DTB
identico** dopo la rigenerazione della patch.

`r-024` conserva il formato con cui l'abbiamo scritta in devaOS
(`--- linux-6.12.29/...` con i timestamp): applica bene, e riallinearla
converrebbe farlo a partire da li'. `z-001` e `z-002` portano driver presi da
altri progetti: i loro warning di stile sono di chi li ha scritti.

Su 127 hunk in 33 patch: **zero** di soli spazi, **zero** senza effetto.

## Peso morto tolto: Bluetooth e xpadneo

La board **non ha Bluetooth**: nessun nodo nel device tree, ne' nel nostro ne'
in quello di ArkOS che gira sullo stesso hardware; nessuna UART per un modulo
BT; e `CONFIG_BT_HCIBTUSB` non e' nemmeno abilitato, quindi non servirebbe
neanche una chiavetta USB. Lakka pero' costruisce lo stack completo:
`BLUETOOTH_SUPPORT="yes"` porta bluez nell'immagine e il supporto BT in
pipewire e pulseaudio, e `ADDITIONAL_PACKAGES` include **xpadneo**, che e' il
driver per i pad Xbox One **via Bluetooth**.

Le opzioni del device si leggono dopo quelle della distribuzione, quindi si
spegne tutto solo per l'RF35H, senza toccare gli altri RK3326. I pad Xbox via
USB in modo host restano: li gestisce `xpad`, che abbiamo abilitato nel
kernel.

Spento anche nel **kernel** (`# CONFIG_BT is not set`): quattro moduli in meno
nell'immagine. Verificato eseguendo `olddefconfig` e guardando il diff riga per
riga — kconfig porta via solo voci Bluetooth, piu' `HID_NVIDIA_SHIELD` che
dipende dal BT ed era gia' disattivato. Tutti e 15 i simboli che ci servono
sopravvivono. (`CONFIG_BTRFS_FS` resta: e' il filesystem, non il Bluetooth.)

La rimozione di xpadneo dalla lista e' imbottita di spazi ai due lati, cosi'
funziona anche se fosse il primo o l'unico elemento — provata su cinque
disposizioni. Due controlli nel build script verificano che entrambe le cose
restino fatte.

## Parallelismo della build: il default era una trappola

`--jobs` (compilatori dentro un pacchetto) e `--pkg-jobs` (pacchetti insieme)
**si moltiplicano**, e il default era `nproc` per entrambi: su 16 core fino a
**256 compilatori insieme**. Con LTO acceso su Mesa e su 19 core (in realta'
non lo era: vedi la correzione del 3/10 in "Compilazione: -O2 e LTO"), un singolo
link chiede tranquillamente mezzo giga: la macchina va in swap e una build che
dura ore ne dura molte di piu'. L'aiuto stesso consigliava altro, ma il
default restava quello.

Ora il default e' `--jobs 2` e `--pkg-jobs` pari al **minore fra i core e
RAM/2 GB**, e lo script stampa quale dei due ha deciso:

| macchina | prima | adesso |
|---|---|---|
| 4 core, 8 GB | 16 | 8 |
| 8 core, 16 GB | 64 | 16 |
| 8 core, **8 GB** | 64 | 8 (limitato dalla RAM) |
| 16 core, 32 GB | 256 | 32 |
| 16 core, **8 GB** | 256 | 8 (limitato dalla RAM) |

Chi vuole spingere passa `--pkg-jobs 4 --jobs 4` come prima; il wrapper Docker
inoltra gli argomenti senza toccarli.

## Ora di rete: il client c'era gia', spento da una condizione

Dal boot log: `systemd-timesyncd.service skipped, unmet condition check
ConditionPathExists=/dev/.kernel_ipconfig`. Quella condizione vale per chi
configura la rete dal kernel (netboot); sul device il file non esiste, quindi
timesyncd veniva **saltato a ogni avvio** - e `wait-time-sync.service`
restava in attesa oltre due minuti di una sincronizzazione che non arrivava
mai. L'orologio lo sistemava connman, molto piu' tardi.

Dal 23/9 `rf35h-ntp` non esegue piu' `systemctl enable` a ogni avvio: quel
comando fa ricaricare a systemd tutte le unit, e il journal lo misurava in
4,8 s, con circa 7 s in cui nessun altro servizio partiva, RetroArch compreso.
Ora abilita `systemd-timesyncd` solo se non lo e' gia', e con `--no-reload`:
l'abilitazione vale dal boot successivo, e la unit la riavvia comunque subito.
Lo stesso per `disable` con l'ora di rete spenta.

**Il fix non entrava nell'immagine.** Corretto il drop-in, ricompilato, e il
ciclo era ancora li' - dallo snapshot del device, testualmente:
`connman.service: Found ordering cycle: ... systemd-timesyncd.service after
network-online.target ...` e `Job dbus.service/start deleted`. systemd non
cancellava connman ma **D-Bus**, e senza bus cadeva tutto cio' che ci si
appoggia (logind, avahi, connman); wpa_supplicant non partiva perche' e'
**attivato da D-Bus**, non da un enable_service. Radio accesa, zero reti.

**Causa: non l'ho mai accertata, e la spiegazione che avevo scritto qui era
sbagliata.** Avevo attribuito la cosa a `PKG_NEED_UNPACK` mancante su
`rf35h-utils`, ma `calculate_stamp` (config/functions) mette gia' `$PKG_DIR`
nello stamp e ne hashea tutti i file: cambiare un file dentro il pacchetto
invalida lo stamp da solo, e il pacchetto si ricostruisce. Le dichiarazioni
che avevo aggiunto a `rf35h-utils`, `wpa_supplicant` e `busybox` erano
ridondanti - rimosse, insieme alle guardie che le imponevano: una guardia che
impone un no-op insegna una lezione falsa. Restano quelle di `rk915` e
`rocknix-joypad`, che puntano fuori dal PKG_DIR (`LINUX_DEPENDS`) e servono
davvero, come quella di u-boot su `$PROJECT_DIR/$PROJECT/bootloader`.

Cosa resta vero: il ciclo di dipendenze **c'era** nell'immagine provata, con la
prova nel journal del device. Perche' quella build non contenesse il drop-in
corretto non lo so; il build script ha gia' un controllo di firma
dell'overlay che si ferma se l'albero ne ha applicato uno diverso.

**Bug sul device, mio**: la prima versione del drop-in aggiungeva anche
`After=network-online.target`, e il Wi-Fi ha smesso di trovare reti.
`systemd-timesyncd` upstream e' un servizio di early boot -
`DefaultDependencies=no`, **`Before=sysinit.target`** (verificato nel sorgente
upstream). `network-online` viene dopo `network`, dopo `connman`, dopo
`basic`, dopo `sysinit`: ordinare timesyncd dopo la rete e' un **ciclo**, e
systemd lo spezza cancellando un job a sua scelta - stavolta la rete. Tolto
l'ordinamento: timesyncd aspetta la rete da solo, riprovando quando
l'interfaccia sale. Il build script rifiuta qualunque drop-in su timesyncd
che ordini dopo la rete.

Quindi niente client nuovo: un drop-in azzera la condizione (`ConditionX=`
vuota svuota l'elenco) e `rf35h-ntp on|off|status|server <host>` governa il
tutto, scrivendo in `/storage/.config/timesyncd.conf.d` - il percorso che
LibreELEC collega apposta per la configurazione dell'utente. `FallbackNTP`
sempre impostato, cosi' un pool che non risponde non lascia senza ora. Il nome
del server e' validato: solo lettere, cifre, punti e trattini.

Nel menu: **Network Time (NTP)** e **Time Server** (it.pool.ntp.org,
pool.ntp.org, time.cloudflare.com, time.google.com). La voce legge lo stato
**vero** - la unit attiva - non il file salvato.

## Misurare prima di ottimizzare: rf35h-bench

Stavo per togliere `Before=retroarch.target` a `rf35h-state`, convinto che il
`sleep 1.5` dentro `rf35h-led --restore` rallentasse l'avvio di un secondo e
mezzo. **Misurato: 7 ms.** Quel sleep scatta solo se l'MCU era spento, e al
boot non lo e': nel device tree `joyled-power` ha `default-state = "on"`,
quindi il kernel lo accende al probe. La modifica sarebbe stata inutile e
avrebbe tolto una garanzia di ordine.

Da li' `rf35h-bench`, che raccoglie sul device i numeri su cui si decide:

- **boot**: `systemd-analyze time`, i dieci servizi piu' lenti, la catena
  critica fino a RetroArch (chi fa aspettare chi) e l'istante in cui parte
  ognuna delle nostre unit
- **clocks**: CPU, GPU e **DDR** da `clk_summary`, a riposo e sotto carico —
  e' la misura che manca per sapere se la RAM va a 333 o a 786 MHz
- **thermal**: temperatura e frequenza ogni 2 s sotto carico, per vedere se e
  quando limita (soglie 70/85/115 C)
- **zram**: rapporto di compressione e MB risparmiati davvero
- **audio**: `hw_params`, `clk_i2s1` e il bit 5 di MIXCTL

Il carico lo prende da un gioco in corso se ce n'e' uno, altrimenti lo genera
su tutti i core. `--save` scrive un file con data: il confronto fra due
esecuzioni e' cio' che dice se una modifica e' servita.

## Robustezza: dati storti dalla rete e dai file

Lo scraper mastica JSON dalla rete con un parser scritto a mano: un errore li'
e' un problema vero. Provato con **20 risposte malformate** (troncate a ogni
livello, array da 5000 elementi, stringa da 100 kB, escape zoppi, annidamento
a 2000 livelli, byte binari) e con **17 playlist rotte** (troncate, enormi,
annidate, casuali binarie) — ricompilato con AddressSanitizer e
UndefinedBehaviorSanitizer: **zero** segnalazioni, nessun blocco. Il banco e'
verificato a sua volta: con la risposta valida la copertina viene scritta,
quindi non stavo misurando un "ok" dovuto a una connessione mai avvenuta.

Stessa prova per `rf35h-ledd` (modi inventati, stringhe da 9 kB, byte nulli,
capacita' della batteria negative o assurde, batteria che sparisce mentre
gira) e per `rf35h-idle` (argomenti storti, eventi di lunghezza casuale nella
FIFO): pulito, e il demone continua a lavorare. `rf35h-rumble` e `rf35h-i2c`
rifiutano gli argomenti storti con il codice giusto.

**`optional/kms-no-compositor.patch` va applicata DOPO `apply.sh`**, non sul
sorgente pulito: tocca lo stesso `options` che l'overlay modifica. Sul
pinnato fallisce, dopo l'overlay applica a fuzz 0. Non era scritto da nessuna
parte.

## Compilato davvero, non solo controllato a sintassi

Verifica piu' vicina alla build vera: **oggetti**, non `-fsyntax-only`, e col
cross-compiler aarch64.

- Kernel: compilati tutti gli oggetti che le nostre patch toccano —
  `rk817_codec.o` (r-026), `panel-generic-dsi.o` (z-002),
  `panel-sitronix-st7703.o` (z-001), `dw-mipi-dsi.o` (r-025),
  `mmc/core/core.o` (usa l'header di r-024) e il DTB (z-010).
- **Moduli fuori albero**, mai provati prima: `rocknix-singleadc-joypad` e
  `rk915` compilano contro il kernel 7.0.1 con le nostre patch — 0 warning,
  20 oggetti per rk915. `modpost` si ferma perche' il `Module.symvers` di un
  albero con il solo `modules_prepare` e' vuoto: e' un limite del banco, non
  del codice.
- RetroArch: **14 file** patchati compilati a oggetto aarch64, zero errori.
- Nel codice macchina: 57 istruzioni vettoriali nel resampler e 10 in
  `s16_to_float` (il NEON della 1004 c'e' davvero); in `connmanctl.o`
  compare `usleep` fra i simboli esterni, assente nel pristine — le attese
  della 1005 sono compilate dentro (le funzioni sono `static` e inlined).

Per rifare il test dei moduli serve, come nella build vera, la patch kernel
`0002-add-input-polldev.patch` di Lakka (reintroduce l'API GPIO legacy) e
`KCPPFLAGS=-DROCKNIX_OF_GPIO_LEGACY_PRESENT`: senza, `of_gpio_compat.h`
ridefinisce `enum of_gpio_flags` e non compila.

## I controlli sanno fallire

Un verificatore che non e' mai scattato non dimostra niente. Ognuno e' stato
provato **rompendo apposta** cio' che sorveglia:

- `check-patch-hunks.py` con un conteggio `@@` falsato → lo segnala
- `check-ifdef-nesting.py` con codice RF35H sotto un `#ifdef` estraneo → lo trova
- build script, simbolo kernel spento (`CONFIG_ZRAM`) → si ferma
- build script, `LEDS_CLASS_MULTICOLOR` spento → si ferma citando HID_PLAYSTATION
- build script, `z-010` senza il rumble o senza i valori OEM della batteria
  (applicazione fresca) → si ferma nominando cio' che manca
- overlay modificato dopo l'applicazione → firma diversa nello stamp, la build
  rifiuta e dice come riapplicare

`rf35h-tty` provato contro un **PTY vero**: 0x11 (XON), 0x13 (XOFF), 0x0d,
0x00 e 0xff passano intatti — e' la prova che il raw mode regge, perche' un
tty normale quei byte se li mangia o li traduce. Rifiuta 0x100, 0xZZ e i
decimali fuori scala con exit 2. Tutti e 17 i modi dei LED degli stick sono
stati eseguiti e mandano il byte giusto.

## Ottimizzazioni

- `rf35h-scrape`: un solo handle curl per tutta la corsa (keep-alive e
  sessione TLS riusata): un handshake per host invece di uno per richiesta.
- Sottotitolo di stato: Ozone chiama il callback a ogni frame; il file si
  rilegge al massimo due volte al secondo.
- Luminosita' dal menu: era `sh` + script a ogni passo (30-50 ms su A35), e
  tenendo premuto il menu scattava. Ora RetroArch scrive in sysfs da solo, con
  la stessa aritmetica dello script e lo stesso file di stato, cosi' L1+volume
  e il menu restano d'accordo; il primo backlight con un file `brightness`,
  come `find_backlight()`. LED e status LED (cambi singoli) sono asincroni.
- `spkeys-service`: il `poll` era a 100 ms fisso, dieci risvegli al secondo a
  console ferma; il timeout serve solo per la pressione lunga, quindi ora
  blocca finche' nessun tasto e' premuto (il modificatore L1 da solo non
  conta: non ripete).
- Script su percorsi caldi (brightness, led, statusled): `$(cat file)` →
  `rd()`, lettura con il builtin `read`, nessun fork. Il helper gestisce file
  senza newline finale (il `read` li segnala come EOF: il primo tentativo li
  perdeva, trovato dal test).

## Rumble

C'e', ed e' del driver: `rocknix-singleadc-joypad` registra `EV_FF`/`FF_RUMBLE`
quando trova `rumble-gpio` (il boot log dice "has gpio rumble"), e RetroArch
lo usa via `udev_joypad` con `input_rumble_gain = 100`. Non l'avevo visto
perche' `rf35h-diag` filtrava via la riga `B: FF=`. Ora la mostra, e c'e'
`rf35h-rumble [ms]`: fa vibrare il pad via evdev senza RetroArch — se
`FF_RUMBLE = si` e non vibra, il problema e' fra GPIO3_A6 e il motore.

Vibra solo quando un core lo chiede: mgba (cartucce con rumble), pcsx_rearmed
(DualShock), i due N64 (Rumble Pak), flycast (Jump Pack). SNES, NES, GB no.

il device tree (`z-010`): il pin era dichiarato `ACTIVE_LOW`, ma a riposo e' basso con il motore
fermo e ArkOS lo dice `ACTIVE_HIGH`. Il driver usa l'API GPIO legacy e ignora
il flag, quindi funzionava lo stesso; corretto perche' non morda quando il
driver passera' a gpiod.

## Effetti LED: rf35h-ledd

L'MCU degli stick ha un protocollo a un byte con 17 modi fissi; i LED di
stato hanno i trigger del kernel (`timer`, `heartbeat`, `activity`). Gli
effetti nuovi si costruiscono sopra: `rf35h-ledd` manda i byte dell'MCU in
sequenza e combina i trigger con la batteria.

Stick (in aggiunta ai 17 dell'MCU): **battery** (colore dalla carica: verde ≥50 %,
arancio ≥20 %, rosso sotto; respiro in carica; bianco a carica completa),
**charging** (spenti; respiro verde in carica; verde a carica completa),
**alert** (spenti; lampeggio rosso sotto il 15 %), **rainbow** (ciclo di 7
colori), **strobe** (rosso/blu). Velocita' **slow/normal/fast** per rainbow e
strobe (voce "LED Effect Speed").

LED di stato (in aggiunta a charge/red/blue/both/off): **battery** (rosso
sotto il 20 %, lampeggia `timer 250/250` sotto il 10 %, blu in carica),
**heartbeat** e **activity** (trigger del kernel sul blu, rosso indicatore di
carica: li applica lo script, nessun demone).

Il demone e' event-driven: `inotify` sui file di stato (`led`, `statusled`,
`ledspeed`), `poll()` con timeout = prossimo frame, 5 s se serve solo la
batteria, infinito se tutto e' statico. Non manda due volte lo stesso byte,
sta zitto quando `joyled-power` e' a 0 (sospensione) e riprende da solo. Gli
script salvano **prima** di applicare, cosi' il demone vede il modo statico e
smette prima che arrivi il byte; per i modi dinamici salvano soltanto, e
`--wake`/`--restore` fanno `touch` per svegliarlo subito. `charge_indicator`
di rf35h-led tocca il rosso solo se i LED di stato sono in modo `charge`.

Provato con sysfs, seriale e batteria finti: sequenze, velocita', silenzio a
MCU spento e ripresa, allarme solo sotto soglia, trigger timer, ordine
salva→applica, `--restore` che rispetta il modo dei LED di stato.

`rf35h-ap` aveva i percorsi cablati, unico fra gli script: non si poteva
provare fuori dal device. Ora ha `RF35H_LOCALAP_CONF` e `RF35H_NET_DIR` come
gli altri, e i tre percorsi (AP che si spegne, AP testardo che obbliga a
riavviare il Wi-Fi, riaccensione) sono stati eseguiti con `connmanctl` e
`wpa_cli` finti.

**Bug trovato al test d'integrazione** (demone e script insieme, come sul
device): scegliendo `battery` per i LED di stato mentre la console caricava,
il blu restava spento. `rf35h-statusled battery` salvava il modo e **poi**
spegneva i LED; il demone, svegliato dall'inotify, accendeva il blu nel
frattempo, e lo script lo rispegneva. Peggio: il demone non lo riaccendeva
piu', perche' la sua cache diceva "gia' acceso". Ora per i modi dinamici lo
script salva e basta: l'unico che scrive sui LED e' il demone.

## Stick e sospensione

In sospensione gli stick si spengono e l'MCU perde corrente
(`rf35h-led --sleep`, da `rf35h-suspend.service`); al risveglio torna la
corrente, un secondo e mezzo per far ripartire l'MCU, e il colore salvato
(`--wake`). Per questo GPIO2_A1 e' un LED class (`joyled-power`) e non un
regolatore: da userspace si spegne.

## I due messaggi sulla console prima dello splash

Con `quiet` il kernel stampa sulla console tutto cio' che e' `KERN_ERR` o
peggio. Due righe arrivavano prima del logo:

- `panel-generic-dsi ff450000.dsi.0: Failed to request panel display timing`
  — il driver cercava un nodo `panel-timing`; questo pannello non lo ha e
  prende il mode da `ctx->modes`, che e' il suo percorso normale. Era un
  `dev_err` nel ramo giusto: ora e' `dev_dbg` (z-002).
- `mmc1: error -110 whilst initialising MMC card` — `mmc1` e' la **eMMC da
  4 GB** con il firmware di fabbrica, non il Wi-Fi. Il loader XiFan la lascia
  in uno stato in cui il primo init a 400 kHz va in timeout; il core riprova
  a 300 kHz e riesce (`mmcblk1: 004G60 3.69 GiB`), ma Lakka non la usa.
  ArkOS4Clone la tiene `disabled`; ora anche noi (in z-010). Il firmware di
  fabbrica resta intatto e il boot perde un centinaio di ms.

Non si e' abbassato `loglevel`: gli errori veri devono restare visibili.

## Core: 30 di default, principale e riserva per ogni sistema (34 dal 4/10)

Ognuno verificato nel suo `package.mk` e nel suo Makefile: che esista per
aarch64, come rileva l'architettura in cross, se ha dynarec.

| sistema | principale | riserve | LTO |
|---|---|---|---|
| SNES / SFC | `snes9x2010` | `snes9x` (accurato), `snes9x2005` (leggero) | tutti |
| GB, GBC | `gambatte` | `sameboy`, `tgbdual` | tutti |
| NES / Famicom | `fceumm` | `nestopia` | tutti |
| MAME (romset 0.139) | `mame2010` | `mame2015` (0.160: molti set 0.139 caricano, non tutti) | no: giganti |
| Mega Drive | `genesis_plus_gx` | `picodrive` | gpgx si', picodrive no (dynarec SH2) |
| Game Gear, SG-1000, SMS | `genesis_plus_gx` | `gearsystem` | tutti |
| Sega 32X | `picodrive` | nessuna: unico core 32X | no |
| GBA | `mgba` | `gpsp` (dynarec arm64) | mgba si', gpsp no |
| PC Engine | `beetle_pce_fast` | `beetle_pce` (fa anche SuperGrafx) | tutti |
| Neo Geo, CPS1/2/3 | `fbneo` | `fbalpha2012`; anche `mame2010` dal romset 0.139 | no: giganti |
| N64 | `mupen64plus_next` | `parallel_n64` (unico altro core N64) | no: dynarec |
| Neo Geo Pocket | `beetle_ngp` | `race` | tutti |
| Atari 2600 | `stella2014` | `stella` | tutti |
| Nintendo DS | `melonds` | `melondsds` | no: JIT (melondsds ha gia' `+lto-off` in Lakka) |
| Amstrad CPC | `cap32` | `crocods` | tutti |
| Dreamcast | `flycast` | nessuna: unico core Dreamcast | no: dynarec |

Scartati, e perche':

- `blastem`: in Lakka e' `PKG_ARCH="x86_64 i386"`. Su aarch64 la build **muore**.
- `vbam`: piu' lento e meno preciso sia di `mgba` che di `gpsp`.
- `beetle_supergrafx`: `beetle_pce` copre gia' il SuperGrafx.
- `desmume`: interprete puro, su un A35 non e' giocabile; `melondsds` e' la riserva.
- `mame2003_plus` (0.78) e `mame` corrente: con un romset 0.139 non caricano niente.

Note dai Makefile: `picodrive` rileva l'arch con `$(CC) -dumpmachine` e attiva il
dynarec SH2 arm64; `mame2010` su aarch64 va con `PTR64=1 ARM_ENABLED=1
LCPU=arm64`; `fbneo` ha `profile=performance HAVE_NEON=1`; `gpsp`
`platform=arm64`; `mupen64plus_next` `platform=rpi-mesa` con GLES (giusto per
Panfrost). Il `NO_OPTIMIZE=1` che Lakka passa a `genesis_plus_gx` non esiste
nel suo Makefile: residuo innocuo, il core compila a `-O2` suo.

LTO (non attivo, vedi la correzione del 3/10): 19 core, tutti interpreti in C/C++ puro. Fuori chi ha dynarec o JIT e i
giganti dove il link con LTO mangia gigabyte di RAM per poco. Se uno dei 19 si
comporta male: `RF35H_LTO_CORES="..."` nell'ambiente della build, o
`--no-core-lto`.

`--all-cores` per i ~120 di Lakka; `--cores "..."` per un elenco proprio. I
nomi sono le cartelle di `packages/lakka/libretro_cores/` (underscore:
`mupen64plus_next`, `beetle_pce_fast`). LTO solo sui cinque provati; gli
altri si aggiungono a `RF35H_LTO_CORES` uno alla volta, dopo averli visti.

**Partizione SYSTEM da 3 GB** (`SYSTEM_SIZE=3072`, nelle options del device,
lette dopo quelle di Lakka). Lakka fa stare i suoi ~120 core in 2 GB e con
`-O2` la base cresce di 60-80 MB: ci starebbe, ma di poco. Con 3 GB non ci
si pensa piu'. Se non ci stesse, `mkimage` fallirebbe in `mcopy` con "disk
full" prima di produrre l'immagine, mai sul device. La STORAGE sulla SD
perde 1 GB.

## Compilazione: -O2 e LTO, dove servono

Cosa fa oggi LibreELEC, verificato nell'albero:

- `config/optimize`: `GCC_OPTIM="-Os"` per **tutto** lo userspace. Giusto per
  un media center, sbagliato per un emulatore.
- `LTO_SUPPORT="yes"` in Lakka, ma opt-in per package (`+lto`,
  `+lto-parallel`); 28 package lo usano, nessuno di quelli che contano qui.
- RetroArch forza gia' `-O2` da solo (`CFLAGS=${CFLAGS/-Os/-O2}`).
- I core: i Makefile fanno `CFLAGS += -O2 -DNDEBUG` in release, che viene
  DOPO il `-Os` dell'ambiente e vince; mgba e' CMake Release, `-O3`. Stanno
  gia' bene.
- Il kernel: `CC_OPTIMIZE_FOR_PERFORMANCE=y` c'e' gia'; con GCC **non esiste
  LTO** (serve Clang). Non si tocca.
- `-mtune=cortex-a35 -march=armv8-a+crc`: gia' nelle options del device.

Quindi il `-Os` colpisce chi prende i flag dall'ambiente senza aggiungere i
propri: **Mesa** (meson `--buildtype=plain`), SDL2, alsa-lib, libpng,
freetype. Mesa e' il driver Panfrost in userspace: ogni frame passa di la'.

Cosa fa l'overlay:

| cosa | come | dove |
|---|---|---|
| `-O2` per tutto lo userspace | ~~`PROJECT_CFLAGS="-O2"`~~ tolto il 4/10: in questo LibreELEC il `-O2` c'e' gia' (vedi sotto) | options-rf35h.patch |
| LTO su Mesa | `PKG_BUILD_FLAGS="+lto-parallel"` (Fedora e Arch la costruiscono cosi' da anni) | mesa-lto-rf35h.patch |
| LTO sui core | `+lto-parallel` su snes9x2010, gambatte, fceumm, genesis_plus_gx, mgba: C/C++ puro, niente dynarec | apply.sh |
| RetroArch | resta `-O2` senza LTO: guadagno marginale, e un frontend rotto e' un device rotto | — |

**Correzione (3/10/2026): l'LTO di Mesa e dei core non e' mai stato attivo.**
In questa LibreELEC `config/functions` conosce solo i flag `lto`, `lto-fat` e
`lto-off`: `+lto-parallel` non corrisponde a niente (`listcontains` cerca la
parola intera) e non aggiunge nessun flag. Nell'albero pinnato lo usa un
solo pacchetto, wpa_supplicant del progetto L4T, che per Rockchip non si
costruisce (i "28 package" sopra erano di un albero precedente); `+lto` ce
l'hanno in 9 (systemd, busybox, openssh, bluez, samba, ...). Quindi Mesa e i core a cui `apply.sh`
lo aggiunge (19, `RF35H_LTO_CORES`) sono stati costruiti senza LTO, solo col
`-O2`. Passare a `+lto` non e' una
sostituzione innocua: aggiunge `-Werror=odr -Werror=lto-type-mismatch
-Werror=strict-aliasing`, e re3 per esempio con quei flag non compila. Va
deciso e provato con una build vera; finche' non si fa, `--no-core-lto`
non cambia niente. Trovato integrando re3, che ha lo stesso flag: re3 ora
ha le sue opzioni LTO scritte a mano (vedi "Giochi fatti per questa
console").

Quando l'LTO sara' attivo davvero, se un core si comporta male:
`--no-core-lto` alla build, oppure `PKG_BUILD_FLAGS="+lto-off"` nel suo package.mk.
`PROJECT_CFLAGS` si puo' misurare: `strings /usr/lib/libgallium*.so | head`
non lo dice, ma il tempo di un frame in RetroArch (Settings → Frame Throttle
→ statistiche) si'.

## Wi-Fi e pad pronti a +5 s invece che a +20

Nel boot log tutto cio' che e' modulo — `rk915`, il joypad, `adc-keys`, la
scheda audio — si carica a **+20 s**: e' il coldplug di udev, e la scheda
SDIO del Wi-Fi era pronta da +4 s. Sedici secondi di Wi-Fi e ssh persi a ogni
boot, e un pad che compare dopo RetroArch.

`/usr/lib/modules-load.d/{rk915,rocknix-joypad}.conf` li fa caricare da
`systemd-modules-load` nella fase sysinit (stesso posto usato da joycond in
Lakka). Il driver Wi-Fi si aggancia al bus SDIO e trova la scheda gia' li';
il joypad, se SARADC o GPIO non fossero pronti, rientra con `EPROBE_DEFER`.
`rf35h-diag` ora stampa i tempi di caricamento: devono stare sotto i 10 s.

**Effetto collaterale trovato al boot successivo**: tasti volume morti e
L1+volume morto. `spkeys-service` scansiona `/dev/input` e si fermava
**al primo** device richiesto trovato (`if (numdevs) break;`). Con il joypad a
+5 s e `adc-keys` ancora a +20 s, trovava il joypad e smetteva di cercare:
nessuno in ascolto sui tasti volume. Ora aspetta **tutti** i device richiesti
(fino a 60 s, poi va con quelli che ha), e `adc-keys` e' in `modules-load.d`
anche lui. La lezione: anticipare un modulo cambia l'ordine di tutto cio' che
lo aspettava.

Il gadget USB non da' al PC `router` ne' `dns`: la console non fa NAT, e con
una default route verso di lei il PC perderebbe internet appena collegato.

## Passata finale: altre magagne dello stesso tipo?

Dopo il difetto del loader, cercate le collisioni analoghe - roba che scriviamo
in posti condivisi e che qualcun altro legge per uno scopo diverso:

- **un solo `dd` raw** in tutto il percorso di boot e aggiornamento, ed e'
  quello corretto
- le variabili usate dalla patch (`PROJECT_DIR`, `PROJECT`, `DEVICE`,
  `UBOOT_FIT_IMAGE`) sono definite nel contesto in cui `bootloader/install`
  viene sorgente, e `UBOOT_FIT_IMAGE` e' un nome semplice, non un percorso
- nessuna collisione di nome: i tre file in `modules-load.d` sono tutti nostri
  e il drop-in su `retroarch.service` e' l'unico
- `/flash/firstboot.sh` lo legge solo `fs-resize`, che gira solo col marcatore
  presente: resta inerte dopo il primo avvio

**Trovato e corretto**: `connman-blacklist-usb-rf35h.patch` applicava con
**offset 8** perche' `connman-stamp-rf35h.patch`, applicata prima sullo stesso
file, aggiunge otto righe sopra. Funzionava, ma `patch` lasciava un `.orig`
nell'albero di build - ed e' esattamente l'inesattezza che la politica a fuzz
zero dovrebbe escludere. Rigenerata contro l'albero con la prima gia'
applicata: offset 0. In piu' tutte le 19 chiamate a `patch` in `apply.sh` ora
usano `--no-backup-if-mismatch`, cosi' nessun `.orig` puo' finire nell'albero.

Applicazione completa dell'overlay su albero pulito: **0 offset, 0 file spuri**.

## Il loader nel SYSTEM: perche' il .tar spaccava il device

`bootloader/update.sh`, applicando un aggiornamento, non si limita a KERNEL e
SYSTEM:

    dd if=${SYSTEM_ROOT}/usr/share/bootloader/u-boot-rockchip.bin \
       of=${BOOT_DISK} bs=32k seek=1 conv=fsync

Riscrive **a 32K** quello che trova nel SYSTEM nuovo - lo stesso offset del
nostro loader known-good AURKNIX. Con l'u-boot compilato da Lakka li' dentro,
ogni aggiornamento .tar lo sostituiva con un binario mai verificato su questa
board: console che non riparte, e rifare la partizione 1 non serve perche' il
pezzo rotto sta **fuori** dalle partizioni.

Errore mio: `release-rf35h.patch` mette il known-good nell'immagine, e sapevo
che il loader va scritto raw - non avevo collegato che l'aggiornamento fa la
stessa `dd` in senso contrario.

Correzione (`bootloader-install-rf35h.patch`): sull'RF35H e' il **known-good**
a finire in `usr/share/bootloader/u-boot-rockchip.bin` dentro il SYSTEM. Cosi'
quel `dd` riscrive byte identici a quelli gia' sulla card: operazione nulla e
ripetibile. Verificato simulandola - sha256 della card invariato dopo
l'aggiornamento, e invariato anche ripetendolo tre volte; con l'u-boot di
Lakka al suo posto la card risulta invece alterata, che e' esattamente il
guasto visto. Il build script si ferma se il ramo rf35h manca da
`bootloader/install`.

Per rimettere in sesto una card gia' colpita: riscrivere il loader raw, senza
toccare le partizioni:

    sha256sum -c known-good.sha256
    sudo dd if=known-good.bin of=/dev/sdX bs=32k seek=1 conv=fsync

## Verifica dell'immagine costruita

Piu' volte, durante il porting, ho corretto qualcosa, ricompilato, e scoperto
**sul device** che nel SYSTEM c'era ancora la versione vecchia - senza alcun
modo di accorgersene prima di flashare. `tools/verify-image.sh` chiude il buco:
apre il SYSTEM dentro il `.tar` (o l'`.img.gz`) e controlla cio' che si e'
davvero rotto su questo progetto.

    sh tools/verify-image.sh target/Lakka-*-rf35h.tar ~/lume/buildroot-external/boards/rf35h

Cinque controlli, ognuno legato a un guasto vissuto:

- **il loader dentro il SYSTEM e' byte per byte il known-good** - e' il
  controllo che conta: `update.sh` lo riscrive raw a 32K, e un blob diverso
  rende il device non avviabile
- il **device tree** e' in `usr/share/bootloader`, senno' un aggiornamento
  lascia in `/flash` quello vecchio
- il **drop-in timesyncd** non ordina dopo la rete (il ciclo che cancellava
  D-Bus e uccideva il Wi-Fi)
- il **drop-in OnFailure** su `retroarch.service`, senza il quale un crash non
  lascia log
- almeno **14 script `rf35h-*`** nel SYSTEM, indice che il pacchetto si e'
  davvero ricostruito
- (dal 3/10) **i core dei giochi**: a fine build `build-lakka-rf35h.sh` passa
  `RF35H_GAMES` con i giochi costruiti (tolti i `--no-...` e quelli esclusi da
  `--keep-going`), e ognuno che manca e' un NO: un'immagine di prima dei giochi
  non passa. A mano e con `--verify-only`, dove le opzioni della build non si
  conoscono, i giochi trovati si elencano e basta

**Errore mio, corretto subito.** La prima versione, senza `squashfs-tools`,
ripiegava in silenzio su `build.*/image/system`. Sul device e' uscito
"conforme" per il `.tar` che aveva rotto la console: lo script aveva guardato
lo stato **attuale** dell'albero - ricompilato nel frattempo, quindi con il
loader giusto - e non quel file. Un "conforme" che parla di un'altra cosa e'
peggio di nessun controllo. Ora senza un lettore squashfs (`unsquashfs`, o
`7z` che legge squashfs) lo script **si rifiuta** e dice come installarlo;
l'albero si controlla solo chiedendolo:

    sh tools/verify-image.sh --tree build.*/image/system ~/lume/.../boards/rf35h

e in quel caso lo annuncia, perche' vale per cio' che verrebbe costruito ORA,
non per immagini gia' fatte.

Lo script, lanciato a mano, e' provato nei due sensi e per entrambe le strade:
passa sull'immagine conforme, e fallisce col messaggio giusto su ognuna delle
quattro rotture reali (loader sbagliato, drop-in con `After=network-online`,
pacchetto non ricostruito, dtb mancante).

**Errore mio: a fine build non girava.** Qui c'era scritto che gira da solo a
fine build e la ferma se qualcosa non torna. Non era vero: il build script lo
cercava in `${RK}/tools/verify-image.sh`, cioe' dentro l'albero Lakka, dove
`apply.sh` non lo copia mai. La condizione era sempre falsa e il blocco
saltava senza dire niente; le prove qui sopra riguardavano lo script, non il
collegamento. In piu' il container non aveva `unsquashfs`, quindi anche col
percorso giusto avrebbe solo avvisato. Lo ha fatto emergere la prima build nel
container, per via di un altro falso allarme (vedi "Prima build nel
container").

Ora gira davvero: lo script si prende dall'overlay, `squashfs-tools` e' nel
Dockerfile, e la stessa funzione serve la fine build e `--verify-only`, che
controlla un'immagine gia' fatta senza ricostruire:

    ./lakka-rf35h/build-in-docker.sh --deva ~/lume/buildroot-external/boards/rf35h --verify-only

`tools/test-verify-tools.sh` la esercita passando dal build script, su un
SYSTEM squashfs vero dentro un `.tar` vero.

## Il percorso di aggiornamento, letto per intero

Passata completa su `check_update` (init dell'initramfs) e su
`bootloader/update.sh`. Ipotesi controllate e **scartate**, una per una:

- **geometria del loader**: il blob known-good e' 16.744.448 byte scritti a
  32.768, quindi finisce esattamente a 16 MiB dove inizia la partizione 1
  (`SYSTEM_PART_START=32768` settori). Zero sovrapposizione - era calcolato
  apposta, e la `dd` dell'aggiornamento non puo' intaccare la FAT.
- **`stat -t`** nel controllo di spazio: temevo non funzionasse senza
  `FEATURE_STAT_FORMAT` (che in Lakka e' disattivo, ed e' cio' che aveva rotto
  il rate-limit del crashlog). Verificato nel sorgente busybox: il ramo
  `#else /* FEATURE_STAT_FORMAT */` gestisce comunque `-t` e stampa la
  dimensione come secondo campo. Funziona.
- **`PKG_NEED_UNPACK` su u-boot**: `bootloader/install` sta fuori dal PKG_DIR,
  quindi temevo che la correzione del loader non entrasse - lo stesso inganno
  di `rf35h-utils`. Ma u-boot dichiara gia'
  `PKG_NEED_UNPACK="$PROJECT_DIR/$PROJECT/bootloader"`, che e' proprio quella
  cartella: lo stamp si invalida e la correzione entra.
- **`.tmp` di un aggiornamento fallito**: non e' un ciclo, `check_update` lo
  rileva, ripulisce e avvia normalmente dopo 10 s.
- **KERNEL nel .tar vs nell'immagine**: stessa sorgente
  (`${TARGET_IMG}/${IMAGE_NAME}.kernel`), file identico.

Il meccanismo e' sano. Il problema vero e' **di visibilita'**: su SD un
aggiornamento muove oltre 1,7 GB (estrazione del .tar, md5 di KERNEL e SYSTEM,
scrittura di entrambi) e dura minuti; e con `quiet` nel cmdline l'init manda
tutto su `/dev/null` (`exec 3>/dev/null`). Riuscita, fallimento con countdown
(10/30/60 s) e blocco reale mostrano **lo stesso identico logo**, quindi un
device che sta lavorando e' indistinguibile da uno morto.

**E qui avevo sbagliato diagnosi**: `quiet` non silenzia l'init. Il
silenziamento di `SILENT_OUT` dipende da `DEBUG`, e i messaggi
dell'aggiornamento (`echo`, `ProgressTask_Spinner`) vanno su **stdout**. Il
motivo vero per cui non si vedono e' il cmdline di questa board:
`console=tty0 console=ttyS1,1500000n8`. Con piu' `console=`, `/dev/console` -
cioe' lo stdout dei processi - segue l'**ultima**, quindi tutto l'avanzamento
esce dalla **seriale** e sullo schermo resta il solo logo. Togliere `quiet`
non avrebbe cambiato nulla; quella patch e' stata ritirata.

Conseguenza pratica utile: **con l'adattatore seriale collegato a ttyS1 si
vede gia' tutto**, senza ricompilare niente.

`init-update-visible-rf35h.patch` fa la cosa mirata: quando - e solo quando -
un aggiornamento viene rilevato, lo stdout passa per un `tee` verso
`/dev/tty0`. La seriale continua a ricevere tutto, lo schermo mostra
l'avanzamento, e il **boot normale resta intatto** con il suo splash pulito,
perche' a quel punto la funzione e' gia' uscita con `return 0`. `quiet` resta
nel cmdline. Logica del tee provata con una shell POSIX: entrambe le
destinazioni ricevono ogni riga.

**Rischio evitato nella prima stesura di questa patch.** Avevo usato una fifo
con `tee` in sottofondo per mandare l'avanzamento a schermo *e* seriale.
Sbagliato in un initramfs: aprire una fifo in scrittura **blocca** finche' non
c'e' un lettore, quindi se il `tee` non fosse partito l'init sarebbe rimasto
appeso per sempre - proprio durante un aggiornamento, cioe' nel momento peggiore
e senza alcun messaggio. E se il `tee` fosse morto dopo, un SIGPIPE avrebbe
ucciso l'init. Sostituita con una redirezione diretta a `/dev/tty0`: niente
processi in sottofondo, niente blocchi, niente SIGPIPE. La prova di scrittura
sta in una **subshell** perche' un `exec >` fallito nella shell principale la
farebbe uscire - init morto e kernel panic. Provati entrambi i rami: con
destinazione irraggiungibile la shell sopravvive e il boot prosegue.

## Recupero da un aggiornamento interrotto

Un `.tar` in `/storage/.update` che fallisce a meta' lascia KERNEL o SYSTEM
scritti in parte e il device non riparte. `/storage` pero' non c'entra: sta
sulla partizione 2, e l'aggiornamento tocca solo la 1.

    sudo sh tools/rf35h-reflash-system.sh nuova.img.gz /dev/sdX

Riscrive **solo la partizione 1** (KERNEL, SYSTEM, DTB, extlinux) dall'immagine
e non tocca mai la 2. Non riscrive nemmeno il bootloader raw a 32K: resta il
known-good del primo flash.

In piu' **svuota `/storage/.update`**: l'init cancella il tarball solo a fine
corsa riuscita, quindi quello fallito resterebbe li' e verrebbe riprovato -
e rifallito - a ogni boot.

Due guardie: rifiuta di procedere se qualcosa e' ancora montato, e si ferma se
la partizione 1 della card e' piu' piccola di quella dell'immagine (riscriverla
troncherebbe il filesystem). Provato su loop device con p1 corrotta a colpi di
urandom e p2 popolata: p1 ricostruita e leggibile, `roms/` intatta,
`.update/` svuotata, e il caso della partizione troppo piccola rifiutato.

## Aggiornare senza riscrivere la card

La build produce due file: `.img.gz` (immagine completa) e **`.tar`**
(aggiornamento). Il `.tar` copiato in `/storage/.update/` viene applicato
dall'init al riavvio: scrive `KERNEL` e `SYSTEM` in `/flash`, e l'`update.sh`
di Rockchip **aggiorna il DTB** in `/flash` prendendolo dal nuovo SYSTEM
(verificato: `cp -p ${SYSTEM_ROOT}/usr/share/bootloader/${dtb} ${BOOT_ROOT}`),
quindi le nostre modifiche al device tree arrivano. Il loader a 32K viene
riscritto, ma con il known-good che il SYSTEM contiene (vedi "Il loader nel
SYSTEM"): byte identici a quelli gia' sulla card, quindi resta quello. `/storage` - ROM, salvataggi,
configurazioni, i nostri file di stato - non viene toccata.

    scp Lakka-RK3326.aarch64-*-rf35h.tar root@<ip>:/storage/.update/ && ssh root@<ip> reboot

Oppure card nel PC: partizione 2 (ext4), cartella `.update/`. Oppure la share
Samba "Update", che e' la stessa cartella.

Cosa persiste e cosa no: `retroarch.cfg` resta il tuo - le chiavi gia'
presenti tengono il loro valore, quelle nuove prendono il default. Quindi un
nuovo default per una chiave che esiste gia' (es. un cambio di
`input_menu_toggle_gamepad_combo`) NON si applica su aggiornamento: e' il
comportamento voluto. La scrittura completa con `flash-sd.sh` serve solo la
prima volta o per cambiare il bootloader.

## Il resize lo fa flash-sd.sh, non il primo avvio

Il meccanismo di LibreELEC esiste ma e' fragile: `libreelec-target-generator`,
trovando `/storage/.please_resize_me`, dirotta il boot su `fs-resize.target`;
ma `fs-resize` si rifiuta di procedere se trova `/storage/.config`, `.cache` o
`.kodi` e **in quel caso toglie il marcatore**, quindi non ci riprova mai piu'
e la card resta a 25 MB per sempre. Verificato riga per riga nel sorgente
(`fs-resize` riga 25) e nel generatore.

Ora la partizione la allarga `flash-sd.sh` mentre scrive la card: `parted
resizepart 2 100%`, rilettura della tabella, `e2fsck -f -p`, `resize2fs`. Gli
stessi comandi di fs-resize, ma con `resize2fs` al posto di `mke2fs`: allarga
conservando invece di ricreare. Poi toglie il marcatore (non serve piu') e
scrive il flag ssh direttamente in `/storage`, che a quel punto e' sicuro.

**Tre guardie, non una.** (1) Si rismonta subito prima e, se qualcosa resta
montato, si salta tutto: fra il `dd` e questo punto passano `partprobe` e
`udevadm settle`, e un desktop con automount ha tutto il tempo di montare le
partizioni appena scritte - `e2fsck -f -p` su un filesystem in uso non si fa.
(2) Si procede solo se la partizione e' cresciuta
davvero (`after > before`). Se il kernel non ha riletto la tabella, resize2fs
"riuscirebbe" sulla dimensione vecchia e togliere il marcatore lascerebbe la
card piccola per sempre - esattamente la rottura da evitare. In quel caso, e
se il PC non ha parted/resize2fs/e2fsck, si ripiega su `/flash/firstboot.sh`
lasciando il marcatore al suo posto.

(3) `e2fsck -p` esce con 1 quando **corregge** qualcosa: e' successo, non
errore, e solo da 2 in su si rinuncia.

Ogni via di fallimento finisce allo stesso modo: marcatore intatto e resize
fatto dal device al primo avvio. Non esiste un percorso che lasci la card
piccola **e** il marcatore rimosso.

Perche' non limitarsi a non scrivere in `/storage`, che gia' basterebbe a
sistemare il difetto? Perche' `fs-resize` fa `mke2fs`: ricrea il filesystem.
Chi copia le ROM sulla card subito dopo averla scritta se le vedrebbe
cancellare al primo avvio. Facendo il resize dal PC, `/storage` e' gia' pronta
e definitiva quando la card esce dal lettore.

Provato end-to-end su loop device, due percorsi: con la partizione **montata**
la guardia ferma tutto senza toccare nulla; smontata, da **28 MB a 332**,
filesystem a 323 MB utilizzabili, `e2fsck=0`, marcatore rimosso, flag ssh
scritto.

## La partizione /storage non si espandeva: era il flag ssh

Sintomo sul device: SD da 64 GB, `/storage` da **25 MB e piena**. Causa:
`fs-resize` (il servizio che al primo avvio allarga la partizione) si ferma se
trova gia' `/storage/.config`, `.cache` o `.kodi` — li considera "sistema gia'
inizializzato" — e `flash-sd.sh` creava proprio `.cache/services/sshd.conf`
per accendere ssh. Avevo scambiato una bugia del menu con una partizione non
espansa.

Doppiamente sbagliato: il resize fa `mke2fs`, cioe' **ricrea** il filesystem,
quindi qualunque cosa scritta in `/storage` prima del primo avvio sparirebbe
comunque.

Il gancio giusto lo prevede LibreELEC: **`/flash/firstboot.sh`**, che
`fs-resize` esegue DOPO aver ridimensionato, con `/storage` montata. Ora
`flash-sd.sh` scrive li' il comando che crea il flag, e non tocca piu'
`/storage`.

Per riparare una card gia' scritta senza perdere nulla (dal PC, scheda
estratta, `sdX` da verificare):

    sudo umount /dev/sdX1 /dev/sdX2 2>/dev/null
    sudo parted -s -f /dev/sdX resizepart 2 100%
    sudo e2fsck -f -p /dev/sdX2
    sudo resize2fs /dev/sdX2

`resize2fs` allarga conservando i dati, al contrario del `mke2fs` di
fs-resize.

## SSH: il toggle del menu dice il vero

`sshd.service` parte se in cmdline c'e' `ssh` **oppure** se esiste
`/storage/.cache/services/sshd.conf`; il toggle "SSH" in Settings → Services
legge **solo** il file. `flash-sd.sh` metteva `ssh` in cmdline: sshd girava e
il menu diceva "off", e spegnerlo dal menu non serviva. Ora crea il file sulla
STORAGE e lascia la cmdline pulita: il menu dice il vero e lo governa.

Su una card gia' flashata, una volta:

    mount -o remount,rw /flash
    sed -i 's/ ssh$//' /flash/extlinux/extlinux.conf
    mount -o remount,ro /flash
    touch /storage/.cache/services/sshd.conf

## Luminosita': L1 + volume

Il modificatore e' **L1** (`BTN_TL`, 310), non Select. Select e' la hotkey di
RetroArch: tenuto oltre 5 frame viene tolto al gioco, e faceva da
modificatore anche per noi — due ruoli sullo stesso tasto. L1 non ne ha altri.

## Sospensione automatica

**Bug trovato eseguendo il demone** (FIFO al posto dei device di input,
`RF35H_IDLE_DIR` e `RF35H_IDLE_CMD`): un evento arrivato mentre il device si
chiudeva non azzerava il timer. Il kernel puo' segnalare `POLLIN` e `POLLHUP`
nello **stesso** poll — un pad USB che manda gli ultimi eventi e sparisce, o
un cavo ballerino che si riaggancia di continuo — e il ramo POLLHUP, che veniva
prima, faceva `continue` buttando i dati gia' pronti. Con un pad cosi' la
console si sospendeva mentre ci stavi giocando. Ora si leggono prima i dati e
poi si tratta la chiusura.

Verificato eseguendolo: disattivato a 0 minuti; sospensione a 61 s con 1
minuto e nessuna attivita'; timer azzerato da un evento (sospensione a 98 s
con l'evento a 38); zero tick di CPU nei 26 s dopo un POLLHUP (era il vecchio
loop a vuoto).

Lakka non ne ha una: `swayidle` e' commentato nella config di sway e non e'
impacchettato, `IdleAction` di logind vuole sessioni che riportino l'idle ma
RetroArch gira come servizio senza sessione, e RetroArch non ha un "comando
su idle".

`rf35h-idle` (C, in `rf35h-utils`) apre tutti gli evdev, aspetta con `poll()`
e dopo N minuti senza eventi chiama `systemctl suspend`. Non fa grab, quindi
RetroArch continua a ricevere tutto; riapre i device ogni 30 s cosi' un pad
USB collegato dopo conta come input; ignora gli `EV_SYN`, che arrivano anche
senza attivita' vera.

Default **10 minuti**. Per cambiarlo, un file sulla card:

    echo RF35H_IDLE_MINUTES=15 > /storage/.config/rf35h-idle.conf
    systemctl restart rf35h-idle

`0` lo disattiva. Provato con device finti: con input ogni secondo non
sospende, dopo il silenzio sospende, i soli SYN non contano.

## Se qualcosa non parte

| Sintomo | Dove guardare |
|---|---|
| il device non parte e non ho una shell | togli la SD, monta la seconda partizione su un PC e leggi `/storage/rf35h-logs/boot.log`. Se non c'e' nemmeno quello, il boot si e' fermato prima di systemd: resta la seriale su `ttyS1` a 1500000 |
| un pulsante e' mappato male | `/storage/rf35h-logs/boot.log`, sezione "input devices, dump completo", righe `B: KEY=`. Mandamele e ricalcolo gli indici |
| voglio sapere **prima** quali sorgenti non si scaricheranno | `./lakka-rf35h/check-sources.sh <albero>` prova tutti i ~1000 URL in parallelo, prima quello del `package.mk` e poi il mirror, e stampa solo quelli dove falliscono entrambi. Un paio di minuti invece di scoprirli uno per build |
| `pax-utils` non si scarica | `gitweb.gentoo.org` non serve piu' lo snapshot. Gli snapshot di gitweb pero' sono `git archive`, quindi deterministici: `seed-sources.sh` clona il mirror su github e lo ricostruisce con `--prefix=pax-utils-1.3.10/ \| bzip2 -9`, ottenendo **lo stesso sha256** che Lakka pinna. Verificato |
| `Cannot get <pkg> sources ... 404` | il pool di Debian tiene solo la versione corrente: quando ne esce una nuova, il tarball pinnato sparisce. `get_archive` ha un mirror di riserva (`sources.libreelec.tv`) che pero' non copre tutto. `./lakka-rf35h/seed-sources.sh <albero>` prende gli stessi tarball dal pool di Ubuntu, che le versioni vecchie le tiene, ne verifica l'sha256 contro quello pinnato e scrive gli stamp che `get_archive` controlla |
| `mmc1: error -110 whilst initialising MMC card` a schermo e il boot non prosegue | `mmc1` e' la **eMMC interna**, non la SD (`mmc0`): Lakka non la usa. Un timeout li' da solo non ferma il boot. Se il boot si ferma e sul PC `LAKKA_DISK` non si apre, il colpevole e' quasi sempre STORAGE corrotta da un `dd` con la card montata (vedi Flash). Controlla con `sudo fsck.ext4 -n /dev/sdX2`. Se `-110` compare anche su una card sana, e' la eMMC: carica il device, e se persiste e' hardware, ma Lakka gira lo stesso |
| la build muore dentro `u-boot` | e' il U-Boot Hardkernel, che questo device **non usa**: lo sostituiamo con `known-good.bin`. Viene costruito lo stesso perche' `BOOTLOADER="u-boot"` guida le dipendenze dell'immagine. Se ti blocca, il modo rapido e' correggere il suo package, non cambiare il boot |
| si ferma dopo il loader, prima del kernel | cluster FAT. `mkimage-rf35h.patch` passa gia' `-c 32`; verifica con `minfo -i` che siano davvero 32 settori |
| schermo nero | **non** la retroilluminazione: il device tree la mette a 128/255 e il device parte cosi'. Guarda la seriale su `ttyS1` a 1500000 |
| nessun input | `lsmod \| grep rocknix` - se il modulo non c'e', udev non l'ha caricato; se c'e', e' l'autoconfig: `retrogame_joypad.cfg` deve stare in `/etc/retroarch-joypad-autoconfig/udev/` |
| pulsanti sbagliati | `cat /proc/bus/input/devices` e la riga `B: KEY=`. Trenta secondi di correzione nel `.cfg`, non una ricompilazione |
| nessun audio | `amixer -c 0 cget name='Playback Mux'` deve dire `HP`. Se dice `SPK`, il servizio dell'Odroid Go e' ancora attivo: controlla che `odroidgoa-utils.service` non esista |
| audio solo in cuffia | `amixer -c 0 cget name='Internal Speakers Switch'` |
| la UI non trova reti, ma `dmesg` mostra il firmware caricato | era iwd, e Lakka e' **iwd-only dalla v6**: `wpa_supplicant` esisteva fino alla v5.x ed e' stato tolto, il ramo di connman e' rimasto. `packages/wpa_supplicant/` lo riporta come package del device (2.11, compilato contro OpenSSL 3 con lo stesso config: zero errori) e `iwd-off-with-wpa-rf35h.patch` impedisce a iwd di partire e prendersi `phy0`. La RK915 e' un driver vendor con semantica mac80211 di qualche anno fa; devaOS, che sullo stesso hardware funziona, usa `wpa_supplicant`. `WIRELESS_DAEMON="wpa_supplicant"` nelle options di RK3326, ramo `rf35h`: connman si ricostruisce con `--enable-wifi --disable-iwd`. E' un ramo che Lakka gia' prevede |
| niente Wi-Fi | `ls /lib/firmware/rk915_*.bin`, poi `dmesg \| grep -i rk915` |
| voglio che il tasto power spenga invece di sospendere | `HandlePowerKey` in `packages/sysutils/systemd/package.mk`, ramo `rf35h`. Ora e' `suspend` per la pressione breve e `poweroff` per quella lunga (5 s, soglia fissa di logind) |
| la ripresa dalla sospensione si pianta | tieni premuto il power: dopo 5 s logind spegne comunque, perche' quella soglia la misura lui sugli eventi del PMIC. Se si ripete, rimetti `HandlePowerKey=poweroff` |
| il tasto power non fa niente | due cause indipendenti: `grep rk805 /proc/bus/input/devices` per il driver, `grep HandlePowerKey /etc/systemd/logind.conf` per logind |
| L1+volume non regola la luminosita' | `systemctl status rf35h-volkeys` - deve aver trovato **entrambi** i device, altrimenti ritenta ogni 10 s |
| i LED degli stick sono spenti | `cat /sys/class/leds/joyled-power/brightness` deve dire `1`. Se il file non c'e', il DTB in FAT e' vecchio (senza il device tree (`z-010`)). Prova al volo: `devmem 0xff260004 32 $(( $(devmem 0xff260004 32) \| 2 )); devmem 0xff260000 32 $(( $(devmem 0xff260000 32) \| 2 ))` |
| i LED degli stick restano del colore precedente | `systemctl status rf35h-state`, poi `rf35h-led blue` a mano |

`rf35h-diag` copre tutte queste righe in un colpo solo.

## Cosa non e' stato verificato

La build completa di Lakka non e' stata eseguita, e l'immagine non e' stata
avviata: quello che segue e' il primo posto dove aspettarsi problemi.

- **Cluster FAT: risolto nella patch.** Misurato: con i 2048 MiB di `SYSTEM`
  di Lakka, `mformat` senza argomenti sceglie **8 settori per cluster** (4
  KiB). La card AURKNIX che su questa board parte ne ha 32 (16 KiB), ed e'
  il valore a cui devaOS e' arrivato dopo aver visto il boot fermarsi.
  `mkimage-rf35h.patch` passa `-c 32` solo per `rf35h`. Stesso U-Boot in
  entrambi i casi (2025.10), quindi allinearsi alla card che funziona costa
  zero.
- **Ordine dei moduli.** `rk915` e `rocknix-singleadc-joypad` finiscono sotto
  `$(get_full_module_dir)`; se non vengono caricati, servono in
  `/etc/modules-load.d/`.
- **`.rockchip_boot_chain_old`.** Lo mettiamo perche' il loader e' in layout
  miniloader Rockchip. Se l'update in-place si comporta male, e' il flag da
  guardare.
- **Nessun fallback di boot.** Un solo DTB, nessun menu. DTB sbagliato = schermo
  nero senza messaggi. Tieni pronta la seriale: `ttyS1` a 1500000.
- **Nessun blocco noto rimasto sulla configurazione.** Gli sha256 dei due
  package sono quelli veri, calcolati sui tarball ai commit pinnati e
  verificati identici tra `codeload` e l'URL `archive` che usa LibreELEC:

      rocknix-joypad  3f8a48e4be159d5c1ee5018849a9a0d0bdfcfad3797320d7983313b773098d48
      rk915           5d3ad6fe0a0323e3fc93c6f8a2d6553c23a25288a21a4b73cdfb3557c273848e Mettici gli sha reali dei tarball
  GitHub ai commit indicati, o la build si ferma alla verifica.

## RetroArch e frontend

**Cambiare `audio_driver` richiede di disattivare e riattivare Audio Output.**
I setting dei driver sono registrati con `SD_FLAG_IS_DRIVER` e senza
`change_handler`: cambiarli scrive solo la stringa, e il driver vero si crea
all'avvio. Il toggle forza `audio_driver_deinit()` + `audio_driver_init_internal()`.
Comportamento previsto di RetroArch, non un difetto.

**`audio_out_rate = 44100` e `audio_resampler_quality = 2`**, i valori di
ROCKNIX e di ArkOS, i due sistemi che su questo hardware suonano bene. Meno
lavoro di ricampionamento per buffer.

**Vibrazione**: ROCKNIX usa lo stesso meccanismo nostro (`rumble_enable` in
sysfs, acceso/spento). Nessun PWM per l'intensita' nemmeno da loro: e' il
driver `rocknix-joypad` su mainline.

## Lo stamp di RetroArch su DISPLAYSERVER (difetto reale, osservato)

Sintomo: sway parte, la UI no. RetroArch esce con status 1 in un ciclo di
riavvii, con `Found GL context: "kms"` e `[KMS] Error when switching mode`.

Causa: `DISPLAYSERVER` governa sia `--enable/--disable-wayland` sia la
scrittura di `WAYLAND_DISPLAY` in `retroarch-env.conf`, ma lo stamp di
LibreELEC e' l'hash di `PKG_DIR` e **non tiene conto di quella variabile**.
Dopo una build con `DISPLAYSERVER=no` (la prova KMS) e il ritorno a `wl`, la
cache ha restituito un RetroArch **senza Wayland collegato**: `ldd` non
mostrava `libwayland-client`. Nessuna variabile d'ambiente poteva aiutarlo.

Rimedio: `PKG_STAMP="${DISPLAYSERVER}"` nel package.mk di RetroArch, lo stesso
gia' usato per connman con `WIRELESS_DAEMON`. Lezione: con una build da cache,
prima si controlla **com'e' fatto il binario**, poi si ragiona sull'ambiente.

## SDL:host contaminato dal sysroot del target (difetto di Lakka)

`PKG_CONFIGURE_OPTS_HOST="${PKG_CONFIGURE_OPTS_TARGET}"` portava nella build
host anche `--with-alsa-inc-prefix=${SYSROOT_PREFIX}/usr/include`: host-gcc
x86_64 riceveva gli header aarch64 e falliva su `__Float32x4_t`. Latente:
`SDL` dichiara `SDL:host` fra le proprie dipendenze, quindi emerge appena un
core qualsiasi richiede SDL. `sdl-host-flags-rf35h.patch` da' alla build host
un elenco minimo; le opzioni **target** conservano ALSA (guardia nel build
script, con confronto esatto: `--enable-alsa` combacia anche dentro
`--enable-alsa-shared`, e la prima versione della guardia passava con ALSA
tolta).

## Core: skip-core e keep-going

`--skip-core NOME` (ripetibile) riempie `EXCLUDE_LIBRETRO_CORES`, che Lakka
applica **dopo** la lista personalizzata: vale sia con `--all-cores` sia con
`--cores`. Nessuna patch.

`--keep-going` non si ferma al primo core che non compila: legge il pacchetto
dalla riga `FAILURE: scripts/<azione> <pkg>:<tipo> has failed!`, lo esclude e
riprende (la cache conserva il resto). Salta **solo** i core libretro; un
pacchetto di sistema ferma la build. Massimo 25 riprese (`--keep-going-max`).
Alla fine: elenco dei saltati, `<log>-core-saltati.txt`, e per ciascuno il log
**del thread**.

Due correzioni fatte strada facendo: il riconoscimento non doveva ancorarsi a
`^FAILURE:`, perche' LibreELEC stampa la riga con i codici di colore; e il
log copiato doveva essere quello del thread, non quello complessivo, che
contiene l'intera build e ha fatto inseguire per tre giri gli errori di
`scummvm` credendoli di `ecwolf`.

## Core riparati e core lasciati fuori

- **`applewin`** - usa `xxd -i` per le ROM ma non lo dichiarava: aggiunto
  `xxd:host`, pacchetto che Lakka ha gia'.
- **`uae4arm`** - `static const char *numbers` confligge con `std::numbers` di
  C++20. Rinominato il simbolo: il suo Makefile compila i `.cpp` con
  `$(CFLAGS)`, non `$(CXXFLAGS)`, quindi un `-std=` in CXXFLAGS era inutile e
  in CFLAGS sarebbe finito anche sui file `.c`.
- **`cannonball`** - Boost incluso che usa membri di `std::allocator` rimossi
  in C++20: fissato `-std=gnu++11`, come il suo Makefile fa gia' per Switch ed
  Emscripten. Qui la regola usa `$(CXXFLAGS)`.
- **`ecwolf`** - causa non individuata (gli errori del linker che sembravano
  suoi erano di scummvm, che pure e' stato costruito).
- **`panda3ds`, `azahar`** - emulatori 3DS, non girerebbero su un A35.

Nota: 154 core dichiarano solo `toolchain` fra le dipendenze. Il sintomo di
uno strumento non dichiarato e' sempre `[code=127]`.

## Compositore: configurazione snella invece di toglierlo

Togliere sway (patch KMS) si e' fermato su EGL. Ma il costo non stava in sway,
stava nella sua configurazione desktop generica. `sway-lean-rf35h.patch`
toglie la **barra di stato** - un `date` al secondo in un ciclo di shell - e
lo **sfondo a 2160p**, sostituito da nero pieno. Senza superfici sovrapposte
wlroots puo' fare **direct scanout**: il buffer di RetroArch va al pannello
senza composizione. Una barra gia' definita non si toglie da un drop-in in
`config.d/`, quindi si modifica la configurazione principale; guardia contro
il ritorno di `status_command`. Prova a caldo senza ricompilare:

    export SWAYSOCK=/var/run/0-runtime-dir/sway-ipc.0.sock
    swaymsg bar mode invisible
    swaymsg output '*' bg '#000000' solid_color

## Override per-core

Lo schermo e' 4:3: le console casalinghe in 4:3 lo riempiono gia'. Le
**portatili** no, e senza scala intera escono con pixel irregolari. Si imposta
`video_scale_integer = "true"` per Gambatte, SameBoy, TGB Dual (GB 3x =
480x432), mGBA, gpSP, VBA-M (GBA 2x = 480x320), RACE, Beetle NeoPop (NGP 3x),
Beetle WonderSwan (2x) e Handy (Lynx 4x).

Il nome della cartella e' il `library_name` del core, verificato sul core-info
di libretro: uno sbagliato viene ignorato in silenzio, e diversi contengono
spazi. `rf35h-overrides.service` copia i default in
`/storage/.config/retroarch/config/` **solo se mancano**: le modifiche
dell'utente non vengono mai toccate.

## Caccia ai bug: cosa e' stato verificato

- il crash logger non riempie la card: un file al minuto, rotazione a 8
  (provato: 15 diventano 8);
- il bootlog ruota con numerazione;
- gli override sopravvivono al primo avvio (`retroarch.cfg` di Lakka sta in
  `/etc`, e RetroArch non cancella le sottocartelle di `/storage`);
- **sospensione con Wi-Fi: da verificare sul device.** Nessuno script nostro
  gestisce l'rk915 in sospensione, ma nemmeno AURKNIX, che sullo stesso chip ha
  hook di sospensione solo per la frequenza della CPU. Nessuna correzione su
  un'ipotesi. Test: sospendi col Wi-Fi connesso, riprendi,
  `iw dev wlan0 link`.

## Una lezione sulla documentazione stessa

Diverse modifiche a questo README, fatte con `replace` senza verificare che
l'ancora esistesse, stampavano "ok" anche quando non cambiavano nulla: da
"RetroArch e frontend" in poi ogni sezione si agganciava alla precedente, e
sono fallite in catena, in silenzio. Il codice era corretto - l'hanno
confermato dry-run e guardie - ma meta' della documentazione di tre giorni non
era mai arrivata. Queste sezioni sono state ricostruite in coda, senza
ancore.

## Opzioni dei core pesanti (.opt)

Un'opzione si imposta solo se il suo default e' sbagliato per questo hardware:
altrimenti e' rumore. Verificato sul sorgente della versione costruita:

- **Mupen64Plus-Next (N64)** - il renderer predefinito GLideN64 (l'unico
  compilato per RK3326: ParaLLEl-RDP Lakka lo abilita solo su Generic, anche
  con Vulkan) rende a **640x480**. Impostato
  `mupen64plus-43screensize = "320x240"`: e' la risoluzione nativa della
  maggior parte dei giochi N64, diventa un upscale pulito 2x sul pannello, e
  riduce a un quarto i pixel da riempire per la Mali-G31. Il prefisso
  `mupen64plus-` e' confermato dai file `.opt` reali; la vecchia wiki dice
  default 320x240, ma riguarda il core `mupen64plus` precedente, non -next.
- **PPSSPP (PSP)** - default `480x272`, cioe' 1x nativo, gia' il minimo.
  Nessun override.

`rf35h-overrides` copia ogni file della cartella del core - `.cfg` e `.opt` -
solo se manca. Provato: il `.opt` si installa, una modifica dell'utente
sopravvive al rilancio, i nomi con spazi restano intatti.

## verify-claims: le modifiche dichiarate sono davvero presenti?

L'incidente del README (sezioni fallite in catena, in silenzio, stampando
"ok") ha posto una domanda che valeva anche per il codice: le modifiche
**dichiarate fatte** sono davvero nell'albero? Controllate una per una contro
l'albero applicato: **tutte presenti**. Il fallimento silenzioso aveva colpito
solo la documentazione.

Quella verifica e' ora `tools/verify-claims.sh`: 26 controlli su integrazione
(sway, RetroArch, SDL, core riparati, kconfig), pacchetto `rf35h-utils` (DAC,
servizi, override, rf35h-i2c, timesyncd), kernel (GPU, DSI, z-010) e build
script. Il build script la esegue da solo **prima del dry-run e prima di ogni
build vera**: una regressione si scopre in secondi invece che dopo ore.

Provata nei due sensi: sull'albero sano passano tutte ed esce 0; cambiando il
default del DAC da 28 a 50 la intercetta ed esce 1.

Uso manuale, su un albero passato per `apply.sh`:

    tools/verify-claims.sh <albero-lakka> [overlay]

Quando si aggiunge una modifica, si aggiunge anche la sua riga qui.

## Revisione della coerenza del README

In tre giorni diverse decisioni sono cambiate, e le sezioni scritte prima
affermavano ancora le versioni superate. Corrette:

- **Scala del volume, presentata al contrario come "corretta".** Diceva
  `0 = muto, 255 = massimo` con default 72 %. E' l'opposto: `DDAC_VOL` e'
  un'attenuazione, misurata su ArkOS. Era la piu' pericolosa, perche' portava a
  reintrodurre il difetto. Ora la sezione avverte che quell'analisi era
  sbagliata e riporta lo stato reale (28 % = registro 184).
- **GPU a 560 MHz** - superato: il 600 MHz e' stato aggiunto.
- **Batteria "segna pieno in anticipo"** - superato: era un confronto fra
  tensione a riposo e tensione di fine carica, e la tabella e' gia' OEM.
- **hp-det "da verificare"** - verificato, polarita' giusta.
- **I2S in `modules-load.d`** - superato dalla kconfig; segnalato con una
  nota, senza cancellare il ragionamento che ci aveva portati li'.
- **"Cosa contiene"** fermo a 7 patch kernel e 18 di integrazione - ora 5 e 27.

Le correzioni sono state fatte per intervallo di righe, verificandone il
contenuto prima di toccarle; la prima stesura, ancorata a testo copiato da un
output troncato, si e' fermata sull'`assert` invece di stampare "ok".

`verify-claims.sh` ora controlla anche che i numeri del riassunto
corrispondano ai file: se tornano a divergere, la build lo segnala.

## Tasti volume: passi da 2 dB e scatto al muto

Segnalato sul device: per arrivare a volume zero coi tasti servivano
tantissime pressioni, mentre ad alto volume scendeva in fretta.

Causa, nel sorgente di RetroArch: `CMD_EVENT_VOLUME_UP/DOWN` chiamano
`command_event_set_volume` con un passo **fisso di 0,5 dB**, su un intervallo
da -80 a +12 dB. Da 0 dB al silenzio servivano **160 pressioni**. E
sull'altoparlante di un handheld tutto cio' che sta sotto circa -40 dB e' gia'
inudibile: **meta' delle pressioni non cambiava nulla di percepibile**. Da
qui la sensazione di un fondo interminabile.

`retroarch-1006-volume-steps.patch`: passo a **2 dB**, e sotto -40 dB lo
scatto diretto al muto; dal muto la prima pressione riporta a -40. Simulato:
**21 pressioni** da 0 dB al muto invece di 160, venti livelli udibili da -2 a
-40 dB, tetto a +12 rispettato, muto che resta muto premendo giu'.

La funzione e' chiamata **solo** dai due tasti (verificati tutti i chiamanti):
il cursore del volume nel menu scrive `audio_volume` direttamente e non
cambia comportamento. Nessuna delle patch 1003-1005 tocca `retroarch.c` o
`command.c`; le quattro si applicano in sequenza a fuzz 0, e i due file
compilano senza errori ne' avvisi nuovi.

Nota: le patch RetroArch si copiano in `apply.sh` **per nome esplicito**, non
con un glob. La 1006 messa nella cartella senza la sua riga in `apply.sh`
sarebbe stata ignorata in silenzio; `verify-claims.sh` ha anche intercettato
il riassunto del README rimasto a 3 patch.

Da tenere presente: sopra 0 dB RetroArch applica un **guadagno digitale**
fino a +12 dB. Su materiale gia' vicino al fondo scala questo satura, e il
risultato suona gracchiante. Se tornasse il gracchio, controllare che il
volume a schermo non sia sopra 0.

### Correzione alla patch del volume, trovata in revisione

La prima versione scattava a -40 dB salendo **solo dal muto esatto** (-80).
Ma il cursore del volume nel menu puo' lasciare il valore nella zona
inudibile - per esempio -60 dB - e da li' si risaliva di 2 dB alla volta:
**dieci pressioni nel silenzio**, lo stesso difetto che la patch doveva
eliminare, rientrato da un'altra porta. La simulazione iniziale partiva sempre
da 0 dB e non poteva vederlo.

Ora la condizione e' `audio_volume < -40.0f`: da **qualunque** valore sotto
-40 una pressione riporta a -40. Verificato eseguendo il codice **estratto dal
file patchato**, non una riscrittura, su 12 casi - passo normale nei due
sensi, ultimo livello udibile, scatto al muto, muto che resta muto, risalita
da -80, -60 e -45, -40 esatto senza scatto, tetto a +12, valori dispari
ereditati dai vecchi passi da 0,5 dB. `verify-claims.sh` controlla la
condizione nuova e che quella vecchia non torni.

Regressione completa dopo la correzione: i quattro file toccati dalle patch
RetroArch (`command.c`, `retroarch.c`, `configuration.c`,
`menu/menu_setting.c`) compilano a 0 errori con e senza le nostre patch, e con
`-Wall -Wextra` gli avvisi sono **identici** - nessuno nuovo. Un errore
iniziale su `menu_setting.c` (`rc_export.h` non trovato) si presentava uguale
anche sul sorgente originale: mancava al controllo il percorso
`deps/rcheevos/include`, non era un difetto nostro.

## Correzioni dal device: sway e volume

### La barra di sway non spariva: la copia in /storage

Segnalato sul device: al boot comparivano ancora la barra in alto e lo sfondo
col logo. La patch era corretta ma **non aveva effetto** su chi aveva gia'
installato. Il motivo sta in `sway-config`, eseguito come `ExecStartPre` di
sway:

    if [ ! -f /storage/.config/sway/config ]; then
      cp /usr/share/sway/config /storage/.config/sway/
    fi

Il default viene copiato in `/storage` **solo al primo avvio**, e da li' non si
aggiorna piu': sway usa quella copia, e la patch cambiava solo il default in
`/usr/share/sway/`, che sul device non veniva piu' letto. Stesso schema degli
override per-core, ma qui lavora contro di noi.

Correzione in `sway-lean-rf35h.patch`, che ora tocca **due** file: una
migrazione una tantum in `sway-config`. Se la copia contiene ancora la barra di
**serie** di LibreELEC - riconoscibile dal suo `status_command while date` - la
si salva in `config.rf35h-backup` e la si sostituisce col default nuovo.
Scatta prima di sway (e' un `ExecStartPre`), una sola volta (il default nuovo
non contiene quella riga), e non tocca chi ha gia' tolto o cambiato la barra
da se'. Provato estraendo il codice dal file patchato, in quattro casi: copia
di serie (sostituita, backup creato, rilancio senza effetti), copia gia' nuova
e personalizzata (intatta), barra tolta dall'utente (intatta), nessuna copia
(creata dal default nuovo).

### Volume: dalla scala in dB alla scala cubica

La prima correzione (passi da 2 dB invece di 0,5) aveva risolto il fondo -
arrivare al muto era lentissimo - ma **rotto la cima**: il widget mostrava
94 -> 74 -> 59 -> 47 %. Causa nel sorgente: il widget calcola la percentuale
come `pow(10, dB/20)`, cioe' **ampiezza lineare**, e qualunque passo fisso in
dB, letto in ampiezza, e' enorme in alto e minuscolo in basso. I numeri
riportati tornano al decimo: sono passi da 2 dB partiti da -0,5.

Ora i tasti si muovono su una **scala cubica** - la posizione e' la radice
cubica dell'ampiezza, il volume vale `60*log10(x)` - a passi del 5 %. E' la
curva di PipeWire e PulseAudio, e quella che ROCKNIX usa su questo hardware
(`volumealign`). Il widget mostra la **stessa** scala, e due dettagli sono
stati corretti perche' altrimenti la scala sarebbe apparsa sbagliata:

- la percentuale era **troncata**: 0,9499 sarebbe comparso come 94, e la scala
  come 94, 89, 84... Ora arrotonda.
- al muto la radice cubica varrebbe ~4,6 %: sarebbe comparso **5 %** a volume
  azzerato. Ora e' 0.

I tasti restano fra muto e 0 dB: sopra 0 dB RetroArch applica un guadagno
digitale che satura e gracchia. Se il volume e' stato portato sopra 0 dal
menu, "su" lo lascia com'e' invece di abbassarlo.

Verificato estraendo il codice da **entrambi** i file patchati (`command.c` e
il widget): a schermo 95, 90, 85... 5, 0 in 20 pressioni, e 5, 10... 100 in
salita; nessun valore mostrato sbagliato per troncamento; dal volume -0,5 dB
la prima pressione porta a 95 % senza saltare un gradino; muto mostrato come
0 %. I tre file toccati compilano senza errori e con gli **stessi** avvisi di
prima (`-Wall -Wextra`).

## Revisione del codice

Revisione di tutto il codice implementato, per rischio: prima cio' che gira
sulla console, poi il build. Ogni difetto e' stato **riprodotto** prima di
correggerlo, e ogni correzione provata sul codice estratto dal file vero.

### Difetti trovati e corretti

- **`rf35h-dac-volume status` etichettava male i valori.** Stampava
  `attuale (registro): values=71,71`, ma 71 e' il **controllo** ALSA: il
  registro vale 255 - 71 = 184. E' la stessa confusione registro/controllo che
  per mezza giornata ha fatto ragionare all'incontrario sulla scala. In piu' il
  `grep "values="` prendeva anche la riga dei metadati, dove `values=2` e' il
  numero di canali. Ora: `28 % (controllo 71, registro 184/255, dove 0 =
  massimo)`, una sola riga. Provato su controllo 71, 255, 0 e scheda assente.
- **`rf35h-rk915-load` nascondeva i fallimenti.** `modprobe rk915 2>/dev/null
  || exit 0`: se il driver del Wi-Fi non si caricava, lo script usciva con
  successo e l'unico sintomo era "niente Wi-Fi". Ora esce 1 con un messaggio.
  Sicuro: il servizio e' `Before=` connman, non `Requires=`.
- **`rf35h-rumble` senza limiti sulla durata.** `replay.length` e' a 16 bit e
  l'attesa `(ms + 200) * 1000` e' in `int`: con `-5` il motore vibrava **65531
  ms, oltre un minuto**; con 3000000 il programma restava appeso quasi un'ora.
  Ora 1-10000 ms. Provato su 8 valori, compresi `0`, `-5`, `abc`.
- **`--keep-going` poteva ripetere a vuoto.** Se un core gia' escluso falliva
  ancora - perche' un altro pacchetto lo tira dentro come dipendenza - il
  ciclo lo riaggiungeva e ripartiva con un `make image` completo, fino a 25
  volte. Ora si ferma e lo spiega. Provato sul ciclo vero con un `make` finto,
  in tre scenari.
- **`rf35h-ledd` ignorava i valori di ritorno di inotify.** Con inotify fallito,
  nei modi statici il demone aspetterebbe all'infinito e i cambi di colore dal
  menu non arriverebbero. Con un solo watch e' praticamente impossibile, quindi
  **niente** ripiego a polling (rileggere lo stato di continuo reinvierebbe i
  byte al microcontrollore, in un componente che funziona): solo il messaggio
  nel journal. Il comportamento e' identico, verificato col diff.

### Verificato e trovato corretto

- tutti gli script del device usano `#!/bin/sh`: la console ha busybox, non
  bash;
- nessuno script usa opzioni che la busybox di Lakka non ha. Due segnalazioni
  erano falsi positivi: `stat -c` in `rf35h-crashlog` compare solo nel commento
  che spiega perche' **non** lo usa, e `timeout` in `rf35h-diag` e' dentro il
  pattern di un grep;
- `rf35h-idle` apre i dispositivi con `O_NONBLOCK`, quindi il ciclo di
  svuotamento esce a buffer vuoto invece di bloccarsi al primo tasto;
- `rf35h-tty` gestisce `EINTR`, gli errori e le scritture parziali;
- lo scraper non passa mai i nomi delle ROM a una shell, e `urlEncode` e'
  corretta secondo la RFC 3986 (provata con spazi, `&`, `+`, `%`, `/`, `?`,
  `#`, UTF-8).

### Una nota sui test

Due volte un test mi ha dato un risultato falso: `dash`, la shell dei comandi
di prova, non espande le graffe, e `mkdir {vice,uae4arm}` ha creato una sola
cartella dal nome letterale; e un nome di file diverso da quello reale ha
fatto sembrare rotta la migrazione di sway. In entrambi i casi il risultato
era **impossibile** rispetto a come avevo preparato il test, ed e' stato quello
a far cercare l'errore nel test prima che nel codice.

### Revisione, seconda parte: gli script rimanenti

La prima parte si era fermata ai componenti piu' critici. Completata sugli
script restanti, cercando lo schema che aveva prodotto i difetti: **input non
validati** - un argomento, un file scritto a mano - che arrivano all'aritmetica
della shell o all'hardware. Tre difetti, tutti riprodotti eseguendo lo script
vero (su un sysfs finto, o con strumenti finti nel PATH).

- **`rf35h-brightness`: i passi derivavano.** La percentuale attuale era
  **troncata** (`CUR * 100 / MAX`) mentre quella da scrivere era
  **arrotondata**, e ogni pressione rileggeva l'hardware. Su di 5 in 5: 54, 58,
  63, 67... e dieci pressioni portavano a 94, non a 100; giu' a passi di 5 e 6;
  +5 seguito da -5 partendo da 50 riportava a 49, quindi la luminosita'
  scivolava verso il basso a forza di regolarla. E' lo stesso tipo di difetto
  segnalato sul volume. Ora la lettura e' arrotondata: passi esatti in
  entrambe le direzioni, e **tutte** le percentuali da 5 a 100 fanno andata e
  ritorno senza scarti. In piu', `max_brightness` a 0 faceva dividere per zero.
- **`rf35h-zram`: la percentuale non era validata.** `PCT=50%` - il modo
  naturale di scriverla - dava `Illegal number` e la zram **non partiva
  affatto**; `PCT=500` era accettato (zram cinque volte la RAM, che anche
  compressa non ci sta); `PCT=0` produceva il messaggio falso "non riesco a
  leggere MemTotal". Ora `50%` vale `50`, e i valori non validi o fuori da
  1-150 ripiegano sul default con un avviso. Provato su nove valori.
- **`rf35h-led raw`: validazione piu' larga del dichiarato.** `[0-9]*` accetta
  una cifra seguita da qualunque cosa: `5abc` o `1+1` passavano e poi facevano
  fallire `$(( v ))` con un errore grezzo della shell. Nessun byte partiva
  (e' un comando di diagnostica per root), ma la validazione non faceva cio'
  che prometteva. Ora 1-3 cifre decimali o `0x` + 1-2 esadecimali. Provato su
  dodici valori.

Verificati e trovati corretti: `rf35h-vibra` (valore salvato accettato solo se
0 o 1), `rf35h-audio-wait`, i contatori interni di `rf35h-usb` e `rf35h-ap`;
`rf35h-statusled` e `rf35h-ntp` non fanno aritmetica. `sleep 0.5`, usato in
sei punti, funziona: la busybox 1.37 di Lakka ha `CONFIG_FLOAT_DURATION=y`.

Tre volte in questa revisione un test ha dato un risultato falso, e ogni volta
il segnale era un esito **impossibile**: `dash` non espande le graffe; con
`. script start` non passa `start` come `$1`; e un `echo` di commento stampato
comunque ha fatto sembrare assente cio' che il grep aveva trovato.

### Revisione, terza parte: il menu e la coerenza fra componenti

Il menu di RetroArch (`1003`) e gli script sono programmi separati, ciascuno
corretto preso da solo, che devono **concordare**. Verificato ogni punto di
contatto:

- **Nessun valore puo' spezzare una riga di shell.** Il menu applica le
  impostazioni con `system()`. Tutti i dodici punti di chiamata passano o un
  numero (`%u`) o una voce di una lista chiusa (`CONFIG_STRING_OPTIONS`):
  nessuna impostazione e' a testo libero, nemmeno il server NTP, che si sceglie
  da quattro voci.
- **Stessi percorsi.** Il timeout di sospensione: il menu scrive
  `/storage/.config/rf35h-idle.conf`, la unit legge proprio quello; 0 significa
  "disattivato" da entrambe le parti, e con `Restart=on-failure` l'uscita del
  demone non innesca riavvii. Lo scraper: il menu scrive `scraper.args` con
  `--region` prima di avviare il servizio, e `ExecStart=... $SCRAPE_ARGS`
  (senza graffe) lo divide negli argomenti giusti.
- **Intervalli e default.** Sospensione 0-60/5, luminosita' 5-100/5, volume
  0-100/4: dentro cio' che gli script accettano, e i tre default (10, 60, 28)
  cadono sulla griglia del passo.
- **Tutte le 41 voci delle liste** - 22 modi LED, 3 velocita', 8 modi di
  stato, 2 USB, 4 server NTP, 2 zram - accettate dallo script che le riceve,
  eseguito davvero. Il test e' stato prima dimostrato capace di fallire: due
  valori inventati (`purplex`, `magenta`) vengono segnalati.

Una descrizione incompleta, corretta: il modo LED **`charging`** diceva
"spenti, respiro verde in carica", ma il codice mostra anche **verde fisso a
carica completa**. Comportamento sensato e voluto (il codice tratta `FULL`
esplicitamente): corretto il testo, nel generatore, e rigenerata la patch.
Differenza verificata: quattro righe (italiano e inglese), 15 file come prima.

Un falso allarme, e la trappola che lo produceva. `check-menu-labels.py` ha
segnalato "23 enum RF35H senza stringa: menu vuoti". Le etichette stanno
dentro `#ifdef HAVE_LAKKA`, e i flag che avevo scritto non lo definivano; la
build reale di Lakka passa `HAVE_LAKKA=1`. Lo strumento ora lo definisce da
se': con i flag incompleti non da' piu' il falso allarme, e con un'etichetta
davvero rimossa (`ZRAM`) continua a segnalarla.

## Revisione di sicurezza

Modello della minaccia: dispositivo a utente singolo, RetroArch gira come root,
Lakka abilita SSH. Conta cio' che e' raggiungibile **dalla rete** - Wi-Fi,
access point, rete USB - e in particolare cio' che abbiamo aggiunto noi.

| # | problema | origine | gravita' |
|---|---|---|---|
| 1 | SSH `root`/`root` con `PermitRootLogin yes`, su **qualunque** rete | default di Lakka (`ROOT_PASSWORD="root"`) | alta |
| 2 | il toggle SSH del menu **svuota** `sshd.conf` e annulla la protezione del punto 1 | difetto di RetroArch/Lakka | media |
| 3 | access point con password **pubblica** `RetroArch`, che riparte a ogni avvio | default di Lakka (`connmanctl.c`), replicato da `rf35h-ap`; il nostro gestore ne nascondeva la notifica | medio-alta |

Verificati e **non** vulnerabili: l'interfaccia di comandi di rete di
RetroArch (`network_cmd_enable`, `network_remote_enable`, `stdin_cmd_enable`
tutti `false`, e i tasti volume usano un socket Unix **astratto**, locale);
lo scraper (credenziali ScreenScraper in HTTPS, mai nei log; ArcadeDB in chiaro
riceve solo il nome del gioco, API pubblica); la rete USB (niente routing, e
serve il cavo: accesso fisico).

### 2. Il toggle dei servizi svuotava la configurazione - corretto (solo in parte: vedi la correzione del 4/10)

`systemd_service_toggle`, accendendo SSH, Samba o Bluetooth dal menu, apriva
in scrittura il file che fa da interruttore del servizio, **svuotandolo**. Per
sshd quel file e' anche l'`EnvironmentFile` da cui legge `SSH_ARGS`: la
protezione standard di LibreELEC (`PasswordAuthentication=no`) spariva la
prima volta che si riaccendeva SSH dal menu, e l'accesso con password root
tornava attivo **senza alcun avviso**. `retroarch-1007` crea il file solo se
manca. Provato compilando il blocco modificato con l'implementazione **reale**
di `filestream` di libretro-common: il file con le opzioni sopravvive, quello
assente viene creato. Controllo negativo sul codice originale: file svuotato.

### 3. Access point con password pubblica - corretto

`rf35h-ap` genera ora una password **casuale per dispositivo** (12 caratteri,
~70 bit, senza i caratteri che si confondono digitandoli sul telefono), e
converte **una volta** le configurazioni che hanno ancora `RetroArch`,
conservando il nome di rete; una password scelta dall'utente non viene
toccata. Il file ha permessi `600`. Casuale vuol dire che va mostrata: il menu
chiama `rf35h-ap prepare` in modo sincrono e mette **nome e password a
schermo per 10 secondi**, come faceva il codice originale di Lakka prima che
il nostro gestore lo saltasse. `rf35h-ap status` la mostra da ssh.

Provato sullo script vero (creazione, rilancio senza rigenerare, conversione,
password utente intatta, ripristino da `.off`, 200 generazioni senza
ripetizioni) e sul blocco C estratto dal file generato (config normale, fine
riga CRLF, ordine inverso e righe estranee; nessuna notifica senza password,
senza config o allo spegnimento). Compilato con `HAVE_LAKKA` **e**
`HAVE_WIFI`: il gestore sta dentro quest'ultimo, e senza il simbolo il
compilatore avrebbe saltato proprio il codice nuovo.

### 1. SSH root/root - richiede un'azione dell'utente

Non lo si cambia d'ufficio: chiuderebbe fuori chi usa SSH, e su LibreELEC
`passwd` non persiste (`/etc` e' in sola lettura). Il meccanismo previsto e'
la chiave piu' `SSH_ARGS` in `/storage/.cache/services/sshd.conf` - che grazie
alla correzione del punto 2 ora **resta** attivo anche riaccendendo SSH dal
menu. Procedura nella risposta che accompagna questa revisione; in caso di
errore si recupera dal PC, togliendo la riga da quel file sulla partizione 2
della card.

### Controlli di non regressione

Quattro righe nuove in `verify-claims`, ciascuna provata anche in
**negativo**. La prima stesura della verifica sulla password pubblica **non
sapeva fallire**: gli strati di escape attorno al `\n` rendevano il pattern
diverso dalla riga da trovare, e reintroducendo `RetroArch` rispondeva comunque
"ok". Riscritta senza escape (una riga che contenga sia `printf` sia
`PASSWORD=RetroArch`), ora intercetta la regressione.

## Kernel 7.2.7

Le sezioni precedenti parlano della 7.0.1: erano vere quando sono state
scritte. Da qui il kernel e' la **7.2.7**, la stabile corrente. Il ramo 7.0 e'
fuori supporto dal 27/06/2026, e noi eravamo al primo rilascio, 7.0.1: tredici
rilasci di correzioni indietro, nessuna correzione di sicurezza da giugno.

**Checksum.** `linux-7.2.7.tar.xz`, SHA256 `4ac34c47...1cad43145a`. kernel.org
non e' raggiungibile dall'ambiente di sviluppo: l'hash viene da nixpkgs, che lo
registra in nix-base32. Il decodificatore e' verificato su un vettore noto e su
1000 andate e ritorno; il metodo e' validato decodificando la 6.1.188 e
confrontandola con il file **firmato** `sha256sums.asc` di kernel.org:
coincide. Un hash sbagliato fermerebbe comunque la build, non passerebbe.

### Pila snella

La build di Lakka applica al kernel 27 patch, 22 delle quali di Lakka, scritte
per la 7.0.1 e per molte console. Sulla 7.2.7: due gia' incluse (le `ntfs`
portate indietro dalla 7.1), quattro con fuzz, tre che falliscono - la `0002`
reintroduce `of_gpio.h` e `input-polldev`, che mainline ha tolto. Il device
tree della RF35H usa solo driver di mainline, il nostro pannello e il joypad
ROCKNIX: di Lakka servono **due** patch, `0000` (il trigger `battery-charging`
esiste solo col power supply rinominato: lo usano `rf35h-led`,
`rf35h-statusled` e `rf35h-ledd`) e `0012` (l'etichetta `dmc`). Piu' le due
generiche `0062` e `9901`.

`apply.sh` tiene un **elenco di quelle da tenere**, non da togliere, e stampa
ogni patch scartata (18 oggi): una patch che Lakka aggiungesse in futuro,
scritta per la 7.0, verrebbe scartata e segnalata invece di fallire.
`0000` e `9901` sono rigenerate a fuzz 0 (le originali applicavano con fuzz 2:
risultato verificato identico, ma non si dipende dal fuzz). `z-001` e'
ritirata. `integration/linux-7.2.7-rf35h.patch` cambia versione e checksum -
ed e' in un elenco **esplicito** di `apply.sh`: senza aggiungerla a mano la
build avrebbe continuato a costruire la 7.0.1 senza errori.

### Porting

- **`r-024`** (Wi-Fi SDIO): 8 blocchi su 9 applicano; `dw_mmc` 7.2 ha eliminato
  lo slot, `&slot->flags` diventa `&host->flags`, `slot->mmc` diventa
  `host->mmc`. Il primo blocco su `dw_mmc` e' finito in una funzione che riceve
  `mmc` come parametro: controllato, non dato per buono.
- **`z-002`** (pannello): `drm_panel_init()` rimossa in 7.2, il pannello si
  alloca e inizializza insieme con `devm_drm_panel_alloc()`. Fra la vecchia
  allocazione e il vecchio init nessun campo del pannello veniva toccato, quindi
  anticipare l'init non cambia il comportamento.
- **`rk915`**, `0003`: `strncpy` rimossa in 7.2. Tre chiamate, nessuna
  sostituibile meccanicamente: 2 cifre esadecimali scritte in mezzo a un buffer
  (`memcpy`), una costante di calibrazione lunga esattamente 188 = `n`
  (`memcpy`), un nome riempito di zeri (`strscpy_pad`). Provate **byte per
  byte** contro la `strncpy` della glibc sugli argomenti reali, con buffer
  sentinella: identiche, anche nei byte non toccati. Controllo negativo: con
  `strscpy` al posto di `memcpy` il primo caso scrive `"b\0"` invece di
  `"b4"`, cioe' corrompe i parametri radio.
- **`rocknix-joypad`**, `0003`: `of_gpio.h` non esiste piu', e con lui
  `of_get_named_gpio()`. Ricostruita com'era nel kernel con primitive
  esportate (`of_parse_phandle_with_args`, `gpio_device_find_by_fwnode`,
  `gpio_device_get_desc`, `desc_to_gpio`): non riserva il GPIO, come
  l'originale, e restituisce `-EPROBE_DEFER` se il controller non e' pronto.
  Pin = prima cella perche' `gpio-rockchip` non ha un `of_xlate` proprio.
  Il driver riceveva l'API a interi **indirettamente** tramite `of_gpio.h`:
  ora `linux/gpio.h` e' incluso esplicitamente. Il flag
  `-DROCKNIX_OF_GPIO_LEGACY_PRESENT` e' tolto dal `package.mk`: l'API legacy
  la dava la `0002` di Lakka, che la pila snella non ha.

### Kconfig

Delle 39 opzioni impostate dalle nostre patch, 38 esistono nella 7.2.7. La
trentanovesima, `SND_SOC_ROCKCHIP`, **non esisteva nemmeno nella 7.0.1**: era
una riga morta, ora tolta (vedi la correzione nella sezione audio). `IPV6` da
tristate e' diventata bool, quindi e' integrata invece che modulo. A runtime
pero' resta **spenta**, come con la 7.0.1: Lakka passa `ipv6.disable=1` sulla
riga di comando del kernel. Gli errori IPv6 di `connmand`, `smbd`, `avahi`,
`rpcbind` e `systemd-sysctl` sono quindi attesi.

Dal 23/9 le nostre patch spengono anche `REGULATOR_DEBUG`, rimasta accesa
dalla config di Lakka: era l'unica, fra le 40 opzioni che aggiungono `-DDEBUG`
a una directory intera, e stampava una trentina di `dev_dbg` a ogni boot. Con
`DYNAMIC_DEBUG=y` quei messaggi restano attivabili a runtime. Il DTS non
attiva piu' l'ISP e la D-PHY CSI della fotocamera, che la RF35H non ha: nodi
senza driver. La IOMMU dell'ISP resta come in `px30.dtsi`, dove e' attiva di
serie e ha un driver.

### Verifiche

- 9 oggetti toccati, i due device tree, `panel-generic-dsi`: compilati sulla
  7.2.7 con la config di Lakka, zero errori, zero avvisi. DTB con 7 punti GPU,
  pannello, joypad, `dmc`.
- `rk915.ko` e `rocknix-singleadc-joypad.ko` costruiti. Senza un kernel
  compilato per intero `modpost` non puo' risolvere i simboli, quindi lo si e'
  fatto a mano: 172 e 67 simboli esterni, tutti esportati nella 7.2.7 (i
  `param_ops_*` e `_dev_*` tramite macro, controllate una per una).
- **Andata e ritorno**: le patch rigenerate applicate a fuzz 0 su una 7.2.7
  pulita danno 16 file identici a quelli compilati; per i driver, sorgente
  riscaricato (hash verificato) piu' tre patch: identico al compilato.
- **Catena intera**: le patch che `apply.sh` lascia nell'albero Lakka, applicate
  come fa `scripts/unpack`, nessuna fallita; `verify-kernel.sh` 21/21; 16/16
  file identici al compilato.
- `verify-kernel.sh` controllato **anche in negativo** sulla 7.2.7 originale:
  17 mancanti. Il controllo negativo ha trovato un marcatore della `9901`
  presente anche senza patch (il gestore di `pm_async=off` assegna la stessa
  variabile): ora e' ancorato alla definizione. Le 10 verifiche nuove di
  `verify-claims` falliscono tutte su un albero non applicato.

### Limiti

- **Nessuna compilazione integrale del kernel**: l'ambiente ha un solo core. La
  fara' la build vera, che e' anche il primo `modpost` completo.
- **Solo sulla console** si verificano: Wi-Fi (`rk915`, clock SDIO portato),
  joypad (ricerca dei GPIO riscritta), schermo (allocazione del pannello), LED
  di carica (trigger `battery-charging`), suspend.
- La 7.2 non e' LTS: fra circa due mesi va aggiornata. Il passo naturale e' la
  prossima LTS, attesa a fine 2026.

### Un difetto trovato rileggendo: il kernel sbagliato

`verify-kernel.sh` sceglieva il sorgente con `find ... | head -1`. Dopo il
passaggio alla 7.2.7 l'albero di build conserva `build/linux-7.0.1` delle build
precedenti, e `find` restituisce le voci in un ordine che dipende dal
filesystem: su ext4 da un hash del nome con un seme **diverso per ogni
filesystem**. Qui usciva prima la 7.2.7 e il difetto non si vedeva; su `tmpfs`,
dove l'ordine segue la creazione, esce prima la 7.0.1 e la versione vecchia
sceglieva quella - con falsi allarmi "kernel 7.2 MANCA" su una build corretta.
Riprodotto, poi corretto: ora si prende la versione piu' alta (`sort -V`).
Correzione incompleta, e peggiorativa a build finita: vedi "Prima build nel
container".

### Prima build con la 7.2.7: due problemi, uno fatale

La prima build si e' fermata su `perf`, lo strumento di profiling che il
pacchetto `linux` compila dal sorgente del kernel:
`tests/workloads/code_with_type.a` e un `error: aborting due to 1 previous
error` di **rustc**. `perf` cerca `rustc` sulla macchina di build
(`feature-rust`) e, se lo trova, compila un carico di **test** in Rust per
`aarch64-unknown-linux-gnu`: il controllo compila per l'host e riesce, la
compilazione per aarch64 no. Non dipende dalla versione - la 7.0.1 ha lo stesso
rilevamento, stesso `Build` - ma da quando `perf` viene compilato rispetto al
toolchain Rust: il cambio di kernel lo ha ricompilato dopo che Rust era gia'
installato. `integration/perf-host-tools-rf35h.patch` aggiunge `NO_RUST=1` agli
altri `NO_*` del pacchetto `linux` (verificato: nessun altro punto ridefinisce
`NO_RUST`, `CONFIG_RUST_SUPPORT` e' letto solo dal `Build` dei carichi di test,
il file dei rilevamenti viene svuotato a ogni build e il pacchetto, cambiando
`package.mk`, riparte da un albero pulito).

Non fatale ma vero: `sha256sum: Dual/TGB: No such file or directory`. La
funzione `calculate_stamp` di `config/functions` passa i nomi dei file a
`xargs sha256sum`, che li divide sugli spazi: i tre override con spazi (`TGB
Dual`, `Beetle WonderSwan`, `Beetle NeoPop`) restavano **fuori dall'hash** di
`rf35h-utils`, quindi cambiarli non l'avrebbe fatto ricompilare.
`integration/stamp-spaces-rf35h.patch` usa `xargs -d '\n'`. Provato sulla riga
estratta dal file: prima 9 errori e 51 file nell'hash, dopo 0 errori e 54; su
`linux`, `retroarch`, `busybox` gli hash sono **identici** prima e dopo, quindi
nessuna ricompilazione di massa (i tre override sono gli unici file con spazi
nell'albero).

**Aggiornamento:** la patch si chiama ora `perf-host-tools-rf35h.patch` e
aggiunge anche `NO_SHELLCHECK=1` (vedi sotto).

La verifica di `verify-claims` per quest'ultima, nella prima stesura, risultava
mancante **anche** con la riga presente: gli escape attorno a `\n` rendevano il
pattern diverso dalla riga. Riscritta senza barre rovesciate, provata nei due
sensi.

### Ricerca di situazioni simili

Le due correzioni rappresentano due classi di problemi. Cercate entrambe.

**Strumenti dell'host rilevati da soli, con esito che dipende dall'ordine di
build.** `rustc` arriva dal toolchain di Lakka (`packages/rust`, non dal
container), portato dai core libretro in Rust (`rustation_ng`, `boytacean`,
`doukutsu_rs`, `holani`) che `--all-cores` compila. Esaminati:
- **`perf`**: ogni strumento dell'host che il suo build cerca. `rustc` e
  `shellcheck` sono **opt-out** (partono se trovati): `shellcheck` >= 0.7.2
  viene eseguito come regola di build sugli script di test e di `trace/beauty`
  e ogni avviso ferma la compilazione. Oggi il container non lo ha: difetto
  **latente**, stessa classe. Aggiunto `NO_SHELLCHECK=1`. `mypy` e `pylint` sono
  **opt-in** (`MYPY=1`, `PYLINT=1`): spenti. I rilevamenti di librerie (libelf,
  zlib, zstd, libunwind...) compilano col cross-compilatore contro il sysroot:
  al piu' cambiano le funzioni di `perf`, non fanno fallire la build.
- **Kernel**: nella config risultante sulla 7.2.7 niente `CONFIG_RUST`,
  `DEBUG_INFO`, `DEBUG_INFO_BTF`, `MODULE_SIG`, `GCC_PLUGINS`: nessuna
  dipendenza da `rustc` o `pahole`.
- **`mesa`**: `gallium-rusticl=false` esplicito; le dipendenze Rust scattano solo
  con Vulkan e `nouveau`, e il device ha `VULKAN="no"`. Deterministico.
- `bindgen-cli`/`cbindgen` li usa solo un addon che non costruiamo. Dall'albero
  del kernel si compila soltanto `perf`.

**Nomi di file con spazi.** Gli unici file con spazi nell'albero sono i tre
override. Fuori da `calculate_stamp` (corretta), nei 18 costrutti a rischio di
`scripts/` e `config/` nessuno li attraversa: operano su `package.mk`, moduli,
file del sysroot, liste di driver. Lo strip (`find -executable | xargs`) non li
tocca perche' hanno permessi 644; `package.mk` li copia con la sorgente fra
virgolette. Nei nostri script `shellcheck` al livello `info` - il lint abituale
e' a `warning`, e `SC2086` e' `info`: finora non si vedeva - segnala 11 punti,
tutti di divisione **voluta** su valori senza spazi per costruzione (PID, nomi
di pacchetto, campi di `/proc/meminfo`, percorsi di sysfs e di `/dev`).

Un caso vero, trovato fra gli 11: in `rf35h-audiotest` l'elenco dei giri
"buoni" arriva da `read`, cioe' dalla tastiera, e veniva diviso senza
validazione. Scrivendo `1,3` - la cosa piu' naturale - il giro 1 finiva fra i
**cattivi** e `diff` cercava `giro-1,3.txt`; con `*` il glob si espandeva nei
nomi dei file della cartella. Ora virgole e punti e virgola valgono come
spazi, il glob e' spento durante la lettura, si tengono solo numeri di giro
nell'intervallo e ogni scarto viene detto. Provato sul blocco estratto dallo
script, in una cartella con dei file: `1,3`, `1, 3;5`, `*`, lettere, fuori
intervallo, duplicati, vuoto.

## Prima build nel container: i controlli di fine build non controllavano

La prima build completa dentro `build-in-docker.sh` e' arrivata in fondo
(immagine da 600 MB in 20 minuti), ma `verify-kernel.sh` ha
stampato 20 `MANCA` su 21. Il kernel era giusto; sbagliati erano i controlli.
Quattro difetti, tutti negli script di contorno, nessuno nell'immagine.

**verify-kernel guardava la cartella sbagliata. Errore mio.** A build finita
esiste anche `build.*/install_pkg/linux-7.2.7` (`config/functions`,
`PKG_INSTALL`: dove il pacchetto si installa per l'immagine), con lo stesso
nome del sorgente e nessun sorgente dentro. Il `find` cercava `linux-7.*` a
qualunque livello e la correzione precedente, `sort -V | tail -1`, la metteva
sempre ultima: `install_pkg` viene dopo `build`. Cioe' la correzione del
difetto di prima rendeva sistematico questo, su ogni albero gia' costruito;
le prove erano state fatte su un sorgente scompattato, senza `install_pkg`.
L'unico `ok` era "r-025 riga vecchia rimossa", un controllo **in negativo**
che su un file inesistente risulta vero per forza. Ora si cerca solo
`build.*/build/linux-7.*`, il controllo in negativo pretende che il file
esista, e l'uscita distingue: 1 mancano patch, 2 niente da controllare.

**La verifica dell'immagine non era mai girata**: percorso inesistente, e
niente `unsquashfs` nel container (vedi "Verifica dell'immagine costruita").

**La firma dell'overlay dipendeva dal percorso.** `sha256sum` stampa il nome
del file accanto all'hash, e la firma nello stamp si calcolava su percorsi
assoluti, ordinati secondo la locale: diversa fra host (`/home/...`) e
container (`/work/...`), e diversa a ogni `--overlay tar.gz`, scompattato ogni
volta in una cartella temporanea nuova. Un overlay applicato dall'host - come
in questa build, fermata sull'host da `mkimage` mancante - andava riapplicato
a mano per costruire nel container. In piu' restava fuori `apply.sh` (erano
esclusi tutti gli `.sh`) pur decidendo cosa entra nell'albero, e dentro c'era
il README. Ora: percorsi relativi, `LC_ALL=C`, esattamente cio' che `apply.sh`
porta nell'albero (vedi "Aggiornare l'overlay senza perdere la build").

**Comandi con i percorsi del container.** Dal container i suggerimenti da
incollare (riapplicare l'overlay, `scp`, `dd`) uscivano con `/work/...`, che
sull'host non esiste. Ora `build-in-docker.sh` passa `RF35H_HOST_WORK` e il
build script stampa i percorsi dell'host.

Di contorno: `mkimage` si controlla prima di toccare l'albero (sull'host la
build moriva dopo averlo gia' modificato); un `--workdir` relativo - quello
che il container richiede - dopo il `cd` nell'albero faceva scrivere il log in
`${WORKDIR}/${WORKDIR}/`, che non esiste (`tee: No such file or directory`,
riprodotto): ora il percorso si rende assoluto subito; il ripristino automatico dopo un
`apply.sh` fallito non cancella piu' log e resoconti `build-rf35h-*`, che
stanno in cima all'albero e git non ignora; `--sh` di `build-in-docker.sh`
vale in qualunque posizione (con `--deva` davanti finiva alla build come
opzione sconosciuta); il messaggio di fine build sull'aggiornamento `.tar` non
dice piu' che il loader "non viene toccato" (viene riscritto, identico).

### Verifiche

- `tools/test-verify-tools.sh`, 20 prove: albero finto costruito leggendo le
  righe `check` di `verify-kernel.sh` (con `install_pkg/linux-7.2.7` e
  `build/linux-7.0.1` accanto), SYSTEM squashfs vero dentro un `.tar` vero,
  `build-lakka-rf35h.sh --verify-only` sopra entrambi, firma da due percorsi.
  **Contro gli script consegnati prima ne falliscono 13**, fra cui "sceglie
  build/linux-7.2.7" e "albero buono: esce 0": il test riproduce il falso
  allarme visto sulla build.
- `verify-claims`: 6 verifiche nuove, 129 in tutto; le 6 falliscono tutte
  sull'overlay precedente.
- Clone pulito di Lakka al commit pinnato, dry-run da zero, poi di nuovo con
  l'overlay in un'altra cartella, da `tar.gz`, con un'altra locale, con README,
  `tools/` e script modificati: sempre "gia' applicato". Firma diversa, e
  build ferma con i comandi per riapplicare, per un file dei pacchetti, un
  permesso, `apply.sh`, `--no-core-lto`, `RF35H_ALL_CORES=1`, uno stamp della
  versione precedente. I tre comandi stampati, eseguiti cosi' come escono:
  l'overlay si riapplica, log e resoconti restano.
- Build finta fino in fondo (`make image` sostituito): verify-kernel,
  verify-image, comandi con i percorsi dell'host (`/work` simulato); con
  l'immagine rotta piu' recente si ferma su "non flasharla"; senza
  `unsquashfs` avvisa e prosegue.
- `build-in-docker.sh` con un `docker` finto: `--sh` prima e dopo `--deva`,
  `--deva` con uno spazio nel percorso, argomenti mancanti; il Dockerfile
  generato contiene `squashfs-tools`.

Non verificato qui: il Dockerfile aggiornato costruito da `docker` vero. Il
pacchetto e' quello di Ubuntu 24.04 (`squashfs-tools` 4.6.1), provato su
un'installazione 24.04: legge zstd, la compressione del SYSTEM di Lakka
(`SQUASHFS_COMPRESSION="zstd"`).

## IKEMEN sulla console: misure (25/9/2026)

Immagine flashata, IKEMEN lanciato da ssh con RetroArch fermo (`</dev/null`,
`GALLIUM_HUD=fps` col dump su file, `GODEBUG=gctrace=1`), 10 s di
`tools/rf35h-ikdiag.sh` 25 s dopo l'avvio. `config.ini`: OpenGL ES 3.2, gioco
320x240 (scelto dal menu di IKEMEN), finestra 640x480, Framerate 60, VSync 1;
`-width`/`-height` cambiano la risoluzione di gioco per la singola prova.

    prova                                  gioco    fps   GPU fragment  MHz GPU
    KFM contro KFM, stage kfm              320x240  23.8  37%           200-400
    KFM contro KFM, stage kfm              640x480  23.2  59%           600
    kfm720 contro kfm720, stage0-720       640x480  27.0  53%           400-600
    senza argomenti (titolo, poi la demo)  640x480  27.7   1%           200
    KFM contro KFM, pannello a 60,000 Hz   640x480  22.1  58%           600

In tutte: thread principale "110%" (cioe' saturo, vedi sotto), gli altri
thread insieme ~25%, CPU sempre a 1200 MHz, core fra 22% e 63%, 57-65 °C.
**Le percentuali per thread e per la GPU sono gonfiate di circa il 10%**: lo
script divideva per i 10 s nominali, ma il suo ciclo ne durava ~11 (un solo
thread al 110% e' impossibile). Corretto: ora divide per la finestra
misurata con `/proc/uptime` (provato con un finto a due thread: 99% ciascuno).

Cosa dicono:

- **IKEMEN e' limitato da un core della CPU.** Il ciclo di gioco gira sul
  thread principale (Go ci blocca la goroutine principale: SDL e GL lo
  vogliono), saturo in ogni prova. Risoluzione (23.8 contro 23.2 fps),
  contenuti HD (27.0) e 60 Hz invece di 58.5 (22.1) non cambiano niente.
- **Gli fps non dicono la velocita' del gioco.** `await()` salta il disegno
  quando e' in ritardo di oltre 17 ms (ne fa comunque uno ogni 250 ms) e oltre
  i 150 ms rinuncia a recuperare: 23 fps possono essere velocita' piena con
  disegni saltati o rallentatore. Lo misura `tools/rf35h-ikbench.sh`: tick
  di gioco al secondo, dalla differenza fra un round di 20 e uno di 5
  conteggi, con Framerate 60 e 30 (in combattimento IKEMEN fa allora due tick
  per disegno; i menu restano a 60) e governor ondemand, performance, boost.
- **La GPU non e' libera a 640x480**: ~23 ms di fragment per fotogramma a
  600 MHz, tetto ~40 fps anche con una CPU infinita; a 320x240 circa un
  terzo. Il 320x240 impostato e' giusto; 640x480 solo con Framerate 30.
- **CPU ferma a 1200 MHz, mai 1296**: ondemand sale al massimo solo con un
  core quasi pieno a ogni campione, e il thread principale gira sui quattro
  core. Performance (1296) e boost (1416) li misura il bench.
- **Garbage collector**: nei combattimenti trascurabile (0%: mark di 14-29 ms
  ogni ~3,5 s, pause stop-the-world sotto i 2 ms, heap 16 MB).
- **Senza argomenti la memoria finisce.** Dopo 600 tick al titolo parte la
  demo, con personaggi e stage a caso dal `select.def` (dentro ci sono gli
  stage 3D `stage3d*`, ~12 MB di glb). Nella finestra: GPU all'1% (stava
  caricando), 93 MB disponibili, 436 MB di memoria condivisa (i buffer della
  GPU; 80-122 MB nei combattimenti), zram +12922/+21820 pagine in 10 s
  (~50/85 MB), heap Go 46-48 MB con mark di 230-345 ms ogni ~2 s, una volta
  con 228 ms di assist sul thread principale. Quale stage avesse pescato non
  si sa.
- **Il pannello andava a 58,5 Hz.** Era il modo `default=1` di
  `panel_description` (z-010): 30 MHz su 990x518. Nella stessa lista c'e' il
  60,000 Hz (31,08 MHz, 1000x518): sway lo imposta al volo (`swaymsg output
  DSI-1 mode 640x480@60.000Hz`), la prova sopra ci e' girata e l'immagine era
  pulita. Ora e' il predefinito: vedi "Pannello a 60 Hz invece di 58,5".
- **Musica dei menu**: non c'e'. `system.def` cerca `sound/Title.mp3`,
  `Select.mp3`, `Versus.mp3`, `Winner.mp3`, `Continue.mp3`, ma lo screenpack
  ufficiale (commit 11d6ea7) ha `sound/` vuota. Messi in
  `/storage/roms/ikemen/sound/` si sentono.

Due lezioni sulle misure. Un IKEMEN avviato in background da una shell
interattiva senza `</dev/null` si ferma (legge lo stdin per la sua console di
debug, riceve SIGTTIN, stato T) e misura zero su tutto: e' successo alla prima
serie, e ora `rf35h-ikdiag.sh` lo segnala. E una finestra di misura va
misurata, non presunta.

`tools/rf35h-ikbench.sh` provato con un IKEMEN finto (durata che dipende da
`-time`, Framerate e governor): tick/s attesi, config.ini, governor e boost
rimessi com'erano anche con un'uscita a meta'; un incontro che non finisce
(crash: niente statistiche da `-log`) o che si appende (oltre 300 s) ferma le
prove e riporta le ultime righe del log.

## Pannello a 60 Hz invece di 58,5

Il nodo del pannello viene da AURKNIX, e il suo primo modo, quello con
`default=1`, e' 30 MHz su 990x518: **58,5 Hz**. Il driver
(`panel-generic-dsi`, z-002) marca PREFERRED il modo con `default=1`, e quello
prendono la console del kernel e sway, che non ha modi nella sua
configurazione. Ora `default=1` sta sul modo da 31,08 MHz su 1000x518,
**60,000 Hz**, della stessa lista di AURKNIX. Gli altri 11 modi restano
com'erano.

Perche':

- col vsync tutto cio' che va al passo del pannello fa 58,5 fotogrammi al
  secondo: IKEMEN (60 tick) e i core di RetroArch a ~60 Hz andavano il 2,5%
  piu' lenti;
- il `retroarch.cfg` di Lakka dice `video_refresh_rate = "60.000000"`, e
  RetroArch ci calcola la frequenza dell'audio (`driver_adjust_system_rates`
  in `retroarch.c`: ingresso = frequenza del core x 60 / fps del core). A
  58,5 Hz reali produceva circa il 2,5% di audio in meno di quanto la scheda
  ne consumi, e il controllo dinamico (`audio_rate_control_delta` 0,005)
  corregge fino allo 0,5%: buffer che si svuota, possibili scatti. Letto nel
  codice, non misurato sulla console. A 60 Hz configurazione e pannello
  coincidono.

Verifiche:

- sulla console, a sway gia' avviato: `swaymsg output DSI-1 mode
  640x480@60.000Hz`, immagine pulita (25/9/2026); la misura di IKEMEN a 60 Hz
  e' in "IKEMEN sulla console: misure";
- DTB compilato con `cpp` + `dtc` su Linux 7.2 (sorgente di torvalds, piu' la
  0012 di Lakka che definisce l'etichetta `dmc`), con la z-010 di prima e con
  questa: i due DTB decompilati differiscono solo in `panel_description`, e le
  frequenze calcolate dai 12 modi sono quelle che sway elencava sulla console
  (58,5; 120; 90; 75,47; 59,728; 60,099; 59,94; 60,000; 57,5; 50,007; 50;
  49,95), col predefinito ora sul 60,000;
- `verify-kernel.sh` controlla la riga nel sorgente del kernel (22 controlli),
  `verify-claims` che nella patch ci sia un solo modo `default=1` e che sia
  quello a 60 Hz (131 verifiche).

**Cosa si ricompila.** Solo il pacchetto `linux` (e l'immagine): la patch sta
in `devices/RK3326/patches/linux`, che entra nello stamp di linux ma non in
`LINUX_DEPENDS`, quello dei moduli esterni. `rk915` e `rocknix-joypad` non si
ricompilano e continuano a caricarsi: stessa versione (`7.2.7`, niente
`LOCALVERSION`), stesso sorgente per `MODVERSIONS`, nessuna firma dei moduli,
`RANDSTRUCT_NONE` (config del kernel dell'RK3326).

Dopo l'aggiornamento: `swaymsg -p -t get_outputs | grep 'Current mode'` deve
dire `640x480 @ 60.000 Hz` senza aver toccato niente, e in RetroArch la
frequenza stimata dello schermo (Impostazioni > Video > Uscita) intorno ai 60.
Per tornare ai 58,5 su un'unita' dove il 60 non andasse bene:
`output DSI-1 mode 640x480@58.500Hz` in `/storage/.config/sway/config`.

## Giochi fatti per questa console: GTA SA, GTA III, OpenXeen, Deva (3/10/2026)

Quattro progetti nati a parte, ora costruiti nell'immagine di default.
**Nessun dato dei giochi nell'immagine**: ognuno usa i file della propria
copia, tranne il gioco di Deva, che e' tutto nostro. Ognuno si spegne alla
build.

    gioco                      si avvia da                      dati                        spegnere
    GTA: San Andreas           Core senza contenuto             APK 2.11.311 arm64 + OBB     --no-gtasa
                               (lanciatore, come IKEMEN)        in ROMs/gtasa
    GTA III (re3)              Core senza contenuto, oppure     cartella della copia PC     --no-re3
                               Carica contenuto > gta3.exe      in /storage/roms/gta3
    OpenXeen (World of Xeen)   Carica contenuto > XEEN.CC o     archivi GOG (XEEN.CC,       --no-openxeen
                               DARK.CC; senza contenuto, demo   DARK.CC, INTRO.CC) nella
                                                                stessa cartella
    Deva's Awesome Adventures  Core senza contenuto             nell'immagine               --no-deva-adventures

Da dove viene ogni pacchetto:

- **gtasa** - il pacchetto dell'overlay `gtasa-rf35h-overlay` del 3/10
  (sha256 fc4d76bf), cosi' com'e'; i sorgenti stanno nel suo `sources/`. Al
  posto del suo `install.sh` lo copia `apply.sh` e lo aggiunge la patch delle
  options. Istruzioni per l'utente nel suo `LEGGIMI.md` (installato in
  `/usr/share/gtasa`).
- **re3** - il pacchetto `lakka-re3-core-package` (sha256 b62c1b31, 33 patch)
  con tre ritocchi: le **opzioni LTO** scritte a mano, `RE3_PGO` facoltativa
  anche con `set -u`, `CMAKE_SKIP_BUILD_RPATH` (vedi sotto). Il PGO funziona
  come prima: `RE3_PGO=generate` o `RE3_PGO=/percorso/re3-pgo` nell'ambiente
  di `build-lakka-rf35h.sh`. Il sorgente arriva da `hottabxp/re3`, mirror del
  repository rimosso nel 2021, con i submodule (librw, ogg, opus, opusfile)
  da GitHub. **re3 non ha licenza**: l'immagine che lo contiene e' per uso
  personale; per una da dare ad altri `--no-re3` (la build lo ricorda a ogni
  avvio). Se il mirror sparisse, la build si fermerebbe sul download di re3:
  `--no-re3`, o `--keep-going` che lo toglie da solo.
- **openxeen** - il commit df6e51e ("fix: review findings", milestone 0)
  come `git archive` riproducibile in `archive/`, controllato con lo sha256.
  La patch 0001 lascia nel workspace solo i tre crate del core: cargo risolve
  l'intero workspace anche con `-p`, e il frontend SDL, la versione web e
  xeentool vogliono crate da crates.io. Cosi' la build va con
  `--offline --locked`: niente rete, niente crate scaricati.
- **deva_adventures** - il tarball dei sorgenti 1.0.0 cosi' come consegnato
  (sha256 042943f4), in `archive/`; `DEVA_ADVENTURES_SRC=/percorso` per
  costruire da un albero di sviluppo. Dati del gioco in
  `/usr/share/deva_adventures` (16,5 MB), dove il core li cerca se in
  `system/` di RetroArch non ce ne sono altri.

**Rust: rust-bin invece di cargo:host.** Lakka il compilatore Rust lo
compila dai sorgenti (rustc 1.95.0, stage 2, su llvm:host), per avere la
libreria standard della triple di LibreELEC. Nessun core del set di default
e' in Rust, quindi finora non si costruiva: per OpenXeen avrebbe voluto dire
un'ora o piu' di build e una decina di GB. `rust-bin` installa invece i
binari ufficiali che Lakka scarica gia' come bootstrap (rustc-, cargo-,
rust-std-snapshot: stessa versione, sha256 nei loro package.mk) piu'
`rust-std-aarch64`, la libreria standard per aarch64-unknown-linux-gnu
(sha256 dal manifest ufficiale del canale 1.95.0, lo stesso che Lakka usa
per rust-std-snapshot sugli host aarch64). OpenXeen si compila per la triple
ufficiale e si linka con il gcc di LibreELEC: stessa glibc. Se Lakka
cambiasse versione di rust, rust-bin si ferma e chiede di aggiornare
versione e sha256.

**LTO di re3.** Il pacchetto chiedeva `+lto-parallel`, che in questa
LibreELEC **non fa niente**: `config/functions` conosce solo `lto`,
`lto-fat`, `lto-off` (vedi la correzione in "Compilazione: -O2 e LTO").
Quindi re3 sarebbe uscito senza LTO, diverso dal core del pacchetto di
prova v5 provato sulla console. `+lto` non va: aggiunge `-Werror=odr
-Werror=lto-type-mismatch -Werror=strict-aliasing`, e re3 fa type punning
(`control/Record.cpp`, i checksum dei replay): la build si ferma li',
provato. Ora `pre_configure_target` aggiunge `-flto` come nel pacchetto di
prova.

**`--keep-going`** ora tratta i giochi (e IKEMEN GO) come facoltativi: se
un loro pacchetto non compila, la build riparte **senza quel gioco**, come
con il suo `--no-...`, e alla fine lo elenca fra i saltati. Solo i
pacchetti che servono a lui solo: openal-soft e mpg123, che servono a GTA SA
e a re3, restano pacchetti di sistema. Senza `--keep-going` la build si
ferma come sempre e dice quale `--no-...` usare.

Cosa cambia nella build: sette passi in piu' (openal-soft, mpg123, gtasa,
re3, rust-bin:host, openxeen, deva_adventures). Il piu' pesante e' re3 (C++
con LTO); rust-bin e' uno scaricamento.

### Verifiche

- **Piano di build** (`scripts/pkgjson | genbuildplan.py --build image`,
  set di core di default): coi giochi 341 passi, dipendenze risolte (gtasa:
  wayland, wayland-protocols, mesa, SDL2_input, openal-soft, mpg123, zlib,
  retroarch); **coi quattro --no-... identico riga per riga a quello
  dell'overlay precedente** (334).
- **deva_adventures**: il package.mk vero (unpack con sha256, `make`,
  makeinstall) col gcc 13.3 per aarch64 e i flag del target RK3326: 0
  warning, esporta solo le 25 `retro_*`, dati identici al pacchetto aarch64
  consegnato. La storia intera (60000 fotogrammi, `--plan ccw`) col core
  aarch64 sotto qemu e con quello x86 dallo stesso sorgente: stesse risposte,
  stesso salvataggio, 64 schermate su 64 identiche.
- **openxeen**: unpack e patch del package, poi il cargo di `make_target`
  con CARGO_HOME vuota e rete tagliata: compila. Per aarch64 (la rust-std
  ufficiale qui non si scarica) con la libreria standard 1.95.0 compilata
  dai sorgenti, stessi flag del package: lo smoke test del progetto (demo e
  contenuto sintetico di `xeentool synth`) da' gli stessi checksum di
  immagini e audio del build x86 e del core aarch64 della CI (M0). Esporta
  solo le `retro_*`; dipende da libgcc_s, libm, libc.
- **re3**: il sorgente preso come lo prende `get_git` (shallow + submodule
  con `--depth 1`) al commit 3233ffe; le 33 patch applicano a fuzz 0. Build
  aarch64 col toolchain file di LibreELEC, OpenAL Soft 1.25.1 (la versione
  di Lakka) e mpg123: senza LTO compila; con i flag di `+lto` no
  (strict-aliasing); con quelli del package si', e il core strippato ha la
  stessa dimensione di quello del pacchetto di prova v5 (2 962 912 byte,
  stesso compilatore GCC 13.3 e stessi flag). Il core si carica
  sotto qemu ("re3 3233ffe", estensione exe), esporta solo le 25 `retro_*`;
  con `CMAKE_SKIP_BUILD_RPATH` niente RUNPATH (quello di prova ne aveva uno
  verso la cartella di build).
- **gtasa**: il `test_package.sh` del suo sorgente, adattato per prendere il
  pacchetto dall'albero dopo `apply.sh`: riga nelle options una volta sola,
  gtasa solo per `rf35h` e non per gli altri RK3326, build senza warning,
  binari aarch64, 25 `retro_*`, `.info` monouso, servizio con gli
  EnvironmentFile di retroarch.service, layout TLS: "package: ok".
- `verify-claims`: 18 verifiche nuove (149 in tutto), tutte e 18 falliscono
  sull'overlay precedente; dry-run da un clone pulito e aggiornamento
  dall'albero dell'overlay di prima.
- **A fine build `verify-image` controlla i core dei giochi** (`RF35H_GAMES`,
  vedi "Verifica dell'immagine costruita"): `test-verify-tools` ora fa 28 prove (8
  nuove: presenti, uno mancante, nessuno atteso, `--keep-going` che ne toglie
  uno, `--verify-only` che elenca soltanto). Quattro mutazioni (niente
  `RF35H_GAMES` a fine build, NO che non scatta, core non estratto dal SYSTEM,
  re3 dimenticato) le prende ognuna la sua prova.
- Albero applicato con questo overlay e con quello di prima (88b78b32), file
  per file: cambiano solo le options e le sei cartelle nuove dei pacchetti.
  Su un albero gia' costruito si costruiscono solo i pacchetti nuovi e
  l'immagine.

Non verificato qui: i pacchetti costruiti dal toolchain vero di LibreELEC
(emulato col gcc 13.3 di Ubuntu, la stessa versione), `rust-bin` con i
tarball veri di static.rust-lang.org (non raggiungibile da qui: sha256 dal
manifest firmato del canale, che rustup ha verificato), e i giochi sulla
console.

## Su GitHub: repository pubblici, re3 a parte (3/10/2026)

L'overlay e i giochi diventano repository GitHub: pubblici `lakka-rf35h`
(questo), `OpenXeenNG` (con la sua storia), `deva-adventures` e
`gtasa-rf35h`; privato `re3-rf35h`. Il README in cima e' ora in inglese e breve; questo
documento, prima README.md, e' `docs/diario.md`.

**re3 esce dall'overlay.** Il suo codice non ha licenza (nel 2021 Take-Two ha
fatto rimuovere re3 da GitHub con un DMCA): il pacchetto (package.mk, files/,
le 33 patch, gli strumenti PGO) vive nel repository privato `re3-rf35h`, e
nell'immagine entra solo con `--re3 <cartella>`:

- `apply.sh` (variabile `RF35H_RE3_PKG`) ne copia package.mk, files/ e
  patches/ in `devices/RK3326/packages/re3`, e prima toglie sempre quello di un
  giro precedente;
- le options aggiungono re3 solo se quel package.mk c'e' (`RF35H_RE3=no` lo
  spegne comunque): anche un `make image` a mano fa la cosa giusta;
- la firma dello stamp comprende cio' che si copia di re3: passare o togliere
  `--re3`, o aggiornare il repository, ferma la build con "overlay
  disallineato" e i tre comandi; README e pgo/ di re3 non contano;
- `build-in-docker.sh` monta la cartella di `--re3` in sola lettura su `/re3`,
  come `--deva`, e passa `RE3_PGO` al container. I mount ora si accumulano nei
  parametri posizionali invece di un ramo per combinazione;
- `--no-re3` resta, per fare dallo stesso comando un'immagine senza re3.

Nel repository di re3, una correzione trovata scrivendone il README:
`RE3_PGO` non era nello stamp del pacchetto, quindi passare da `generate` al
profilo non ricostruiva il core. Ora `PKG_STAMP` contiene la modalita' e, per
un profilo, l'impronta del contenuto della cartella; provato anche con
`set -euo pipefail` e con una cartella che non esiste (nessun errore).

**Deva e OpenXeen dai loro repository**, a un commit fissato, invece dei
tarball incorporati: Deva al commit della 1.0.0 (`1e93ae9`, tag `v1.0.0`),
OpenXeenNG a `afe41a1`. L'overlay passa da 16 MB a meno di 1 MB, e un
aggiornamento dei giochi non aggiunge piu' 15 MB alla storia di git. Il primo
commit di `deva-adventures` e' il tarball 1.0.0 senza modifiche (verificato
file per file; `tools/release/` va aggiunto a forza, perche' il `.gitignore`
del gioco, con `release/` non ancorato, lo ignorava: corretto nel commit
dopo). La build ora scarica i due giochi da GitHub, come gia' rk915 e
rocknix-joypad.

**OpenXeen diventa OpenXeenNG**, in tutto: nel repository i crate
(`openxeenng-*`), il binario, il core `openxeenng_libretro.so` col suo
`.info` (library_name e corename OpenXeenNG), il file wasm, le variabili dei
test differenziali; il progetto Java da cui riparte resta OpenXeen. Qui il
pacchetto e' `openxeenng`, la variabile `RF35H_OPENXEENNG`, l'opzione
`--no-openxeenng`; la patch 0001 e' rigenerata sui nomi nuovi. La demo, la
barra di stato del browser e i dati sintetici mostrano il nome nuovo, quindi
le loro immagini cambiano: con solo quelle stringhe rimesse come prima, lo
smoke test del core da' di nuovo i checksum della milestone 0 (demo
6f116215, contenuto 3d1fcec8). Il core rinominato: x86 e aarch64 (sotto
qemu) danno gli stessi checksum (b4bcb455, 8ddb2fb4), esporta solo le 25
`retro_*`; `cargo fmt`, `clippy -D warnings` e i 76 test passano come
prima.

**Email dei commit**: in tutti i repository autore e committer sono
`d.darrigo@outlook.it`, anche nei 9 commit di OpenXeenNG di prima (storia
riscritta prima di pubblicarla: alberi identici, hash nuovi, e i commit
fissati qui sono quelli nuovi).

### Verifiche

- `scripts/unpack` vero di LibreELEC (get_git, extract, patch) da copie
  locali dei due repository: gli alberi di build sono identici al tarball
  1.0.0 di Deva e all'archivio di OpenXeen provato finora con la patch 0001
  (a parte `.git`, che nessuna delle due build legge).
- Dry-run da un clone pulito: senza `--re3` 148 verifiche, con `--re3` 151
  (le tre di re3 girano solo se re3 e' nell'albero); `--re3` su una cartella
  sbagliata si ferma subito.
- Aggiornamento da un albero con l'overlay di prima (45e087bf), con e senza
  `--re3`: "overlay disallineato", i tre comandi, poi 148 o 151; senza
  `--re3` la cartella re3 sparisce dall'albero. Sullo stesso albero: stesso
  `--re3` "gia' applicato", senza `--re3` o con una patch di re3 cambiata
  "overlay disallineato".
- Piano di build: senza re3 340 passi, con re3 uno in piu'; con re3
  nell'albero e `RF35H_RE3=no` identico a quello senza.
- Build finta fino in fondo, con e senza `--re3`: verify-image si aspetta re3
  solo nel secondo caso, "Conforme" in entrambi.
- `build-in-docker.sh` con un docker finto: `--deva` e `--re3` in qualunque
  ordine, percorsi con spazi, `--sh`, `RE3_PGO`, argomento mancante o
  inesistente.
- `test-verify-tools`: 31 prove (3 nuove sulla firma di re3).

## CI su GitHub e loader nel repository (4/10/2026)

**Il loader sta in `board/loader`**: `known-good.bin` (16 744 448 byte, sha256
`52850532...`) e il suo `.sha256`, gli stessi file di devaOS, con un README
su provenienza (AURKNIX-RK3326 20260809, byte 32K..16M) e licenze. `--deva`
diventa facoltativo: senza, `build-lakka-rf35h.sh` usa `board/` dell'overlay
(anche da un `--overlay` tar.gz). La firma dell'overlay ora contiene lo sha256
del loader usato (board/ o `--deva`): cambiarlo vuol dire riapplicare, prima
non se ne accorgeva nessuno.

**`--dry-run` calcola anche il piano di build** con lo stesso ambiente di
`make image` (`build_env`, una funzione sola per il piano e per la build):
una dipendenza mancante si vede in un minuto. Oggi: 340 passi, 97 per l'host
e 243 per la console.

**Versione dell'immagine**: `RF35H_VERSION` (la CI ci mette il tag) arriva a
`scripts/image` come `CUSTOM_VERSION`: diventa `VERSION` in `/etc/os-release`
ed entra nel nome dei file (`Lakka-RK3326.aarch64-Next-v1.0.0-rf35h.img.gz`).
`BUILDER_NAME=lakka-rf35h` e `BUILDER_VERSION` (il commit dell'overlay, `git
describe --dirty`) finiscono anch'essi in os-release. Nessun pacchetto li
legge (solo `scripts/image` e xorg-server, che qui non c'e'): cambiarli non
ricostruisce niente.

**`build-in-docker.sh` in CI**: il terminale (`-t`) solo se c'e'; un nome al
container (`RF35H_CONTAINER`) per fermarlo da fuori; passa `RF35H_VERSION` e
`RF35H_UPDATE_REPO`.

**Workflow** (`.github/workflows`):

- `check.yml`, a ogni push e pull request: `tools/ci-check.sh` (shellcheck a
  livello warning su tutti gli script, riconosciuti dalla prima riga; sintassi
  dei .py senza scrivere `__pycache__`; i conteggi @@ delle patch; le prove
  `tools/test-*.sh`, con busybox come sulla console) e il dry run su Lakka
  pinnato. Il dry run in CI e' piu' severo di quello a mano: se il commit
  pinnato non si scarica, lo script resta sulla punta di devel con un avviso,
  qui e' un errore.
- `build.yml`: tag `v*`, *Run workflow* (con o senza versione) o push su
  `ci-test/**`. La build gira nel container di `build-in-docker.sh`, la
  stessa di chi costruisce a mano. Un job dei runner gratuiti dura al massimo
  6 ore e la build da zero ne chiede di piu' (llvm per l'host serve a Mesa:
  Panfrost compila i suoi kernel OpenCL con libclc), quindi gira in fino a
  quattro parti (`build-stage.yml`): ognuna costruisce fino a 320 minuti
  dall'inizio del job (`timeout`, poi `docker kill`: la build e' il PID 1 del
  container e il SIGTERM inoltrato lo ignora), e se non ha finito impacchetta
  l'albero per la successiva, senza sorgenti, log e file temporanei.
  LibreELEC salta i pacchetti con lo stamp e rifa' solo quelli interrotti.
  `AUTOREMOVE=yes` per lo spazio (il kernel resta finche' servono i moduli
  esterni: `PKG_IS_KERNEL_PKG` lo mette in `PKG_DEPENDS_UNPACK`); ccache fra
  una build e l'altra nella cache delle actions, 6 GB con
  `CCACHE_COMPILERCHECK=content` (la toolchain ricostruita ha un'altra data),
  salvata alla fine di ogni parte, anche fallita: una build ripartita dopo
  un errore non ricomincia da una cache vuota.
- **AUTOREMOVE e ikemen-go**: LibreELEC toglie la cartella di build di un
  pacchetto quando nessun job del piano la dichiara piu' in
  `PKG_DEPENDS_UNPACK`. ikemen-go compila il suo core lanciatore con
  `-I$(get_build_dir retroarch)/libretro-common/include` e dipendeva da
  RetroArch solo in `PKG_DEPENDS_TARGET`: in CI la cartella di RetroArch
  spariva appena fatto RetroArch, il lanciatore non compilava e
  `--keep-going` toglieva IKEMEN dall'immagine. A mano non succedeva (senza
  AUTOREMOVE le cartelle restano). Ora `PKG_DEPENDS_UNPACK="retroarch"`; nel
  piano non c'e' nessun altro caso (cercati `get_build_dir` e `kernel_path`
  in tutti i 297 pacchetti), e verify-claims controlla che ogni
  `get_build_dir <nome>` dei nostri pacchetti abbia `<nome>` in
  `PKG_DEPENDS_UNPACK` (162 verifiche). La prima build di prova in CI e'
  partita prima della correzione: la sua immagine non avra' IKEMEN.
- La release la crea un job a parte, l'unico con `contents: write`: bozza,
  file, poi pubblicata. File: `.img.gz`, `.tar`, `update.txt` (versione,
  nome, url, sha256 e dimensione del `.tar`), `SHA256SUMS`. Prima di
  pubblicare: re3 cercato nel SYSTEM dell'immagine (non nelle opzioni), la
  versione nel nome dei file, gli sha256. Con "Run workflow" e una versione,
  il tag viene creato alla pubblicazione; una release latest solo dal ramo
  principale, e un tag gia' esistente si rifiuta prima delle ore di build.

## Aggiornamento di sistema dalle release (4/10/2026)

**Perche' non l'updater di Lakka.** "Update Lakka" (Online Updater) legge
l'indice del server di Lakka per `RK3326.aarch64`: immagini per un RK3326
generico, che qui installerebbero un altro kernel, un altro SYSTEM e, con
`bootloader/update.sh` del nuovo SYSTEM, un altro loader a 32K. La console
non ripartirebbe. In piu' il client HTTP di RetroArch tiene tutto il download
in RAM (realloc a raddoppio), cioe' 600 MB su 730. Sull'RF35H la voce ora non
c'e' (`!rf35h_present()` nella 1003) e `lakka-update` da ssh passa a
`rf35h-update` (`integration/lakka-update-rf35h.patch`).

**`rf35h-update`** (rf35h-utils, busybox sh):

- legge `update.txt` dell'ultima release, sempre allo stesso indirizzo
  (`/releases/latest/download/update.txt`, le pre-release no) del repository
  scritto alla build in `/usr/share/rf35h/update-repo` (la CI ci mette il
  suo, `PKG_STAMP` lo segue); `update.conf` in `/storage/.config/rf35h` puo'
  dire `TAG=`, `REPO=` o `URL=`. Ogni campo validato prima dell'uso: version
  e nome del tar senza caratteri strani, nome senza `/`, url solo https,
  sha256 di 64 cifre esadecimali, size numerica;
- versione uguale a `VERSION` di `/etc/os-release` (la CI la mette con
  `CUSTOM_VERSION`): "up to date". Altrimenti controlla batteria (30% o in
  carica) e spazio (il .tar due volte, perche' l'init lo estrae accanto, piu'
  100 MB), toglie da `/storage/.update` gli altri aggiornamenti (l'init
  applica il primo .tar che trova) e scarica con curl in `.part`, in
  background: l'avanzamento nello stato ogni 2 s. Niente `--retry` di curl:
  quattro tentativi propri, sempre con `-C -`;
- dimensione e sha256 giusti, poi `mv` nel nome vero e `update.ready`; solo
  allora "ready: vX, select to restart and install". Al riavvio l'init di
  LibreELEC fa il resto (con i suoi md5 su KERNEL e SYSTEM);
- la dimensione dei file da `ls -ln`, non da `wc -c`: la busybox conta i
  byte leggendo il file, e `stat -c` qui non c'e';
- lo stop dal menu (`systemctl stop`, SIGTERM a script e curl) lascia il
  `.part` e scrive "stopped: select to resume": il giro dopo riprende;
- `rf35h-update boot` (`rf35h-update-boot.service`, prima di RetroArch):
  con il .tar consumato dall'init lo stato "ready" non vale piu';
- **re3**: le release non lo hanno mai. Se l'immagine in uso ce l'ha (build
  personale), prima di dare "ready" lo script copia core, `.info` e
  `system/re3` in `/storage` (in `/tmp/cores` e `/tmp/system`, overlay,
  vince la copia di /storage) con un marcatore; `boot` toglie la copia solo
  se c'e' il marcatore e l'immagine ha di nuovo re3 di suo, altrimenti la
  copia vecchia nasconderebbe quella nuova. Un re3 messo a mano senza
  marcatore non si tocca.

**Menu**: *Device Settings > System Update*, ultima voce. Un'azione come lo
scraper: avvia `rf35h-update.service` (non abilitata), o la ferma se sta
girando, o con un aggiornamento pronto riavvia (`CMD_EVENT_REBOOT`, che salva
la configurazione). Il sottotitolo mostra la riga di stato, riletta al
massimo due volte al secondo, oppure "installed: vX"; un avanzamento senza
il servizio attivo diventa "interrupted: select to resume". Italiano:
"Aggiornamento di sistema".

### Verifiche

- `tools/test-rf35h-update.sh`, 34 prove con busybox sh, curl e df finti:
  gia' aggiornata, aggiornamento completo, ripresa da un `.part`, sha256 e
  dimensione sbagliati (file tolto, niente "ready"), sei `update.txt`
  rifiutati, batteria (scarica rifiuta, in carica no), spazio, rete assente,
  certificato rifiutato, `TAG` e `REPO`, re3 copiato e poi tolto (e uno
  messo a mano lasciato), stop durante il download.
- 1003 rigenerata dai due generatori; sopra la nuova 1003 applicano a fuzz 0
  tutte le patch dopo (1004-1010); compilati (x86_64, flag di Lakka con
  HAVE_LAKKA) menu_cbs_ok, menu_cbs_sublabel, menu_displaylist,
  menu_setting, menu_cbs_title, menu_cbs_deferred_push, configuration,
  msg_hash_us e msg_hash (con l'italiano): nessun errore ne' avviso.
  check-menu-labels: i 24 enum RF35H hanno la loro stringa;
  check-ifdef-nesting pulito.
- Dry run da un albero pulito: 161 verifiche (13 nuove), piano invariato.
- `verify-image` controlla anche gli aggiornamenti: con `rf35h-update`
  nell'immagine serve `usr/share/rf35h/update-repo`, e con `RF35H_VERSION`
  (la CI) la `VERSION` di os-release deve essere quella. test-verify-tools:
  36 prove (4 nuove).

## Prima build pulita in CI: glibc senza ottimizzazione (4/10/2026)

La prima build di prova (run #3) si e' fermata dopo 34 minuti e 83 passi su
340, a `glibc:target`: `#error "glibc cannot be compiled without
optimization"`. Il package.mk di glibc normalizza ogni `-O` a `-O2` e poi
toglie dai suoi CFLAGS il testo di `PROJECT_CFLAGS`; con il nostro
`PROJECT_CFLAGS="-O2"` toglieva anche il proprio `-O2`, e glibc senza
ottimizzazione non compila. A mano non si e' mai visto: l'hash di un
pacchetto copre i suoi file e `PKG_STAMP`, non le options del device, quindi
glibc, costruita prima che arrivasse `PROJECT_CFLAGS`, non e' mai stata
ricostruita. Una build da zero lo trova subito.

E `PROJECT_CFLAGS="-O2"` non serviva: in questo LibreELEC `setup_toolchain`
aggiunge a ogni pacchetto `CFLAGS_OPTIM_DEFAULT` (`-O2 -fomit-frame-pointer`),
dopo `PROJECT_CFLAGS`, e vince l'ultimo `-O`; `-Os` lo prende solo chi chiede
`+size` (nel piano gdb, wsdd2 e busybox). Il commento delle options parlava
di un `GCC_OPTIM="-Os"` per tutto lo userspace che qui non c'e' piu'. Tolto:
nessun pacchetto cambia flag, e glibc compila. Al suo posto un commento, un
controllo nel build script e uno in verify-claims (163 verifiche) contro un
`-O` in `PROJECT_CFLAGS`. `options-vulkan-ikemen-rf35h.patch` rigenerata
sulle righe nuove (applicava con 9 righe di offset).

Nella stessa build: `AUTOREMOVE` e le due variabili di ccache, definite nel
workflow, non arrivavano nel container (`build-in-docker.sh` passava solo
`RF35H_VERSION` e `RF35H_UPDATE_REPO`). Ora una lista sola, solo se definite;
`CCACHE_DIR` mai (un percorso dell'host nel container non esiste).

Misure utili dalla stessa build: il runner ha un disco solo, 122 GB liberi
dopo la pulizia (niente `/mnt`), 4 CPU e 15 GB; 83 passi in 34 minuti (la
toolchain); albero di 20 GB a quel punto.

## Seconda build pulita: strace con gli header della 7.2 (4/10/2026)

La run #4 ha superato glibc ed e' arrivata a 268 passi su 340 in 247 minuti
(ccache a fine parte: 1,9 GB, 77 816 compilazioni), poi si e' fermata su
`strace:target`: `static assertion failed: "Unexpected size of arg.resv
(sizeof(uint64_t) * 3 expected). --enabled-bundled=yes configure option may
be used to work around that."` (src/macros.h, CHECK_TYPE_SIZE su io_uring).
Gli header uapi nel sysroot sono quelli del kernel 7.2.7, strace 7.0 e'
scritto contro quelli della 7.0, e il suo configure di default (`check`) ha
preso quelli di sistema. `integration/strace-bundled-headers-rf35h.patch`
aggiunge `--enable-bundled=yes` (opzione verificata nel configure.ac del tag
v7.0): strace usa la sua copia degli header.

Stessa origine di glibc: l'hash di un pacchetto (`calculate_stamp`) copre i
suoi file e `PKG_STAMP`, non le dipendenze ne' il kernel. In locale strace
era quello costruito prima del passaggio alla 7.2.7, e non e' mai stato
ricostruito. Solo una build da zero dice se l'albero si costruisce davvero,
ed e' per questo che la CI parte sempre da zero (con la sola ccache).

## Ripresa di una build fallita in CI (4/10/2026)

Le due build pulite sono fallite dopo 34 e 247 minuti, e ogni correzione
voleva dire ripartire da zero: con la ccache la toolchain va piu' veloce, ma
fino a strace sono comunque ore. Ora una parte che fallisce salva il suo
stato (`state-N.tar.zst`, lo stesso che passa da una parte all'altra, 3
giorni) e il riassunto del run dice con che ID riprenderla. *Run workflow*
con `resume_run` = quell'ID: la parte 1 chiede all'API gli artifact di quel
run, scarica solo lo stato piu' avanzato (ognuno pesa GB), lo estrae, e
`ci-build.sh reset` riporta l'albero a Lakka pulito tenendo `build.*`, i log
e i resoconti: gli stessi comandi che il build script suggerisce dopo
"overlay disallineato". `prepare` riapplica l'overlay del commit nuovo, e la
build rifa' solo i pacchetti i cui file sono cambiati (l'hash di
`calculate_stamp`); la ccache e' nello stato, quella di actions/cache non si
ripristina.

Solo per le build di prova: `setup` rifiuta `resume_run` con una versione.
Per la stessa ragione per cui la CI parte da zero, una ripresa non dice se
l'albero si costruisce davvero: i pacchetti che dipendono da uno cambiato
non si rifanno, e l'immagine mette insieme pacchetti di due commit. Serve a
vedere in un'ora se una correzione passa; la conferma resta la build pulita.

download-artifact v8 (letto nel sorgente del tag): un artifact non zip si
salva col nome del Content-Disposition, `artifact` se manca; scaricandone
piu' d'uno con `merge-multiple` due file senza nome si sovrascriverebbero.
Per questo uno solo, per nome, scelto prima con `gh api` (il filtro jq
provato: il numero piu' alto fra gli `state-N` non scaduti).


## Terza build pulita: ferma al passo 8, prima diagnosi sbagliata (4/10/2026)

La run #5 (strace corretto) si e' fermata dopo 40 secondi, al passo 8 di
340: `install glsl_shaders:target`. Il resoconto non diceva perche':
glsl_shaders e' un pacchetto di sistema, e il build script si fermava prima
di copiare il log del suo thread (lo faceva solo per i core da saltare), cosi'
la CI ha letto la coda del log complessivo, dove si mescolano i log dei
pacchetti finiti prima (un `curl: (22) ... 400` di un download riuscito al
tentativo dopo, il configure di make). Nel log del pacchetto c'erano solo i
due "FAILED COMMAND": nessuna riga con "error", come un `fatal:` di git.
Ricontrollato a mano: il commit di glsl-shaders si scarica (`git fetch
--depth 1` dello SHA del package.mk) e `make install` funziona. L'ipotesi era
un errore di rete (`get_git` di LibreELEC non riprova, `get_archive` prova 10
volte, URL e mirror): sbagliata, la causa vera e' nella sezione dopo. Le
modifiche restano utili:

- Il build script copia il log del thread in `*-<pacchetto>-fallito.log` per
  ogni pacchetto fallito, anche di sistema, e lo nomina quando si ferma.
- `ci-build.sh build` riprova una volta una build fallita (stessa parte,
  stesso tempo a disposizione): un errore di rete passa, uno vero si ripete
  in pochi minuti, perche' il costruito resta e si rifa' solo il pacchetto
  fallito. Il primo tentativo resta in un'annotazione ("Tentativo 1
  fallito: riprovo"), con il resoconto.
- Il resoconto cerca anche gli errori di rete (`fatal:`, `Cannot get`,
  `curl: (`, `Failed to`, `unable to`, `timed out`, `reset by peer`) e i
  processi morti (`Illegal instruction`, `Segmentation fault`, `core
  dumped`, `Killed`).

Provato con una build finta (fallisce una volta, poi due): un tentativo in
piu', annotazioni giuste, esito `done` e poi `failed`.

## Il vero motivo: -march=native e la ccache fra runner diversi (4/10/2026)

La run #6 (con il nuovo resoconto e il secondo tentativo) e' fallita allo
stesso punto, due volte, e stavolta il log del pacchetto diceva tutto:

    package.mk: line 9: 6062 Illegal instruction (core dumped)
      make -C ${PKG_BUILD} install INSTALLDIR=...

Non la rete: e' `make` (il make:host di LibreELEC, primo pacchetto del
piano) che muore con SIGILL. LibreELEC compila gli strumenti per l'host con
`-march=native` se `BUILD_REUSABLE` e' vuota (config/functions,
`HOST_CFLAGS_OPTIM_NATIVE`). I pacchetti con il flag `local-cc` (make,
cmake, zstd, ... quelli che vengono prima del ccache:host) usano il
compilatore e il ccache di sistema, con la cache in `.ccache-local`, che la
CI salva e ripristina. Il ccache di Ubuntu 24.04 e' il 4.9.1: di
`-march=native` hasha il testo, non la CPU (il 4.13.6 che LibreELEC
costruisce per il resto, invece, chiede al compilatore cosa vuol dire,
`hash_native_args`: verificato nei sorgenti dei due tag). Una run
precedente ha compilato make su un runner; la #5 e la #6, su runner con
un'altra CPU, hanno ripreso dalla cache un make con istruzioni che la loro
CPU non ha. In
locale non succede: la cache resta sulla stessa macchina.

E anche con il ccache giusto la build a parti avrebbe avuto lo stesso
problema: la parte 2 riprende gli strumenti per l'host compilati dalla parte
1, e puo' finire su una CPU diversa.

Correzione: in CI `.libreelec/options` mette `BUILD_REUSABLE="yes"`.
Verificato con `config/options` + `setup_toolchain host` sull'albero pinnato:
vuota, `HOST_CFLAGS` finisce con `-march=native`; "yes", senza. Il valore non
e' "all", "mesa:host" ne' "save-local", gli unici che mesa guarda (quelli
farebbero i suoi strumenti "riusabili", con upx). Gli oggetti vecchi della
cache non si riusano piu' (le opzioni sono cambiate) e invecchiano fuori.

Non riprendere (resume_run) dalle run #5 e #6: lo stamp di make:host non
dipende dai flag, quindi la ripresa terrebbe il make compilato male.

Nel resoconto anche il titolo delle annotazioni codificato: una virgola
("fallito, riprovo") lo tagliava, perche' nei comandi del workflow separa le
proprieta'.

## Prima build completa in CI (4/10/2026)

Run #7 (`b9f79d3`, con `BUILD_REUSABLE`): 340 passi su 340 in 230 minuti,
al primo tentativo, in una parte sola (job di 3 ore e 54 minuti). Immagine
`Lakka-RK3326.aarch64-Next-ci-7-b9f79d3-rf35h.img.gz` da 615 MB, `.tar` da
640 MB, 34 core, nessuno escluso; `verify-image` conforme (a fine build un
"non conforme" fa uscire la build con errore: e' uscita 0); re3 assente dal
SYSTEM. ccache: 21 078 colpi su 159 756 (13%: con i flag cambiati tutti gli
strumenti per l'host si sono ricompilati), 3,8 GB salvati. Disco: 103 GB
liberi alla fine, albero di 19 GB. L'immagine resta negli artifact del run
fino al 18/10.

Quindi una build quasi da zero sta in un job: le parti restano come
margine (cache vuota, runner piu' lenti). La prossima, con la cache calda
anche per l'host, dovrebbe metterci meno.

## rf35h-rescue: Wi-Fi senza MAC fisso (4/10/2026)

Segnalato dall'utente: `tools/rf35h-rescue.sh` seminava la rete in connman
come la scrive il menu, `wifi_<MAC>_<SSID>_managed_psk/settings`, con il MAC
della nostra console (`02:74:49:ca:6a:f6`) come predefinito. Su un'altra
RF35H il MAC e' diverso e la rete seminata non vale. Il driver rk915
(AveyondFly, `init_mac_addr()`) prende il MAC, nell'ordine, dal parametro
del modulo, da un hash dell'ID della CPU nell'OTP del PX30 (`02:` + 5 byte
di hash: unico per console e stabile fra i boot), dal numero di serie, dalla
funzione del BSP Rockchip, a caso. Quindi ogni console ha il suo, e non lo
si puo' indovinare dal PC.

Ora lo script scrive un file di provisioning di connman,
`/storage/.cache/connman/rf35hrescue.config` (`Type = wifi`, `SSID` in
esadecimale, `Passphrase`), senza la chiave `MAC`: connman lo applica
all'interfaccia Wi-Fi che trova, qualunque MAC abbia. Niente piu'
`RF35H_WIFI_MAC`. Una rete data cosi' e' "immutable" (dal menu non si
dimentica): per toglierla `rm /storage/.cache/connman/rf35hrescue.config`.
Nel file la password e' scritta con le regole di GKeyFile (`\` raddoppiato,
spazi in testa e in coda come `\s`) e con `printf`, non `echo` (quello di dash
interpreta le `\`). Provato con il parser vero (GLib 2.80): sette password
difficili (backslash, spazi in testa e in coda, `#`, `;`, `=`, virgolette, uno
spazio solo) tornano identiche, generate con dash, bash e busybox.

Il Wi-Fi configurato dal menu di RetroArch non aveva il problema: lo crea
connman sulla console, con il MAC vero.

## Verso la v1.1: LTO vero, kernel 7.2.9, note di release (4/10/2026)

Chiesto dall'utente: "procedi con tutto quello che puoi fare gia', alla fine
provero' la release nuova ottimizzata".

**LTO.** Questa LibreELEC conosce tre flag: `lto`, `lto-fat`, `lto-off`
(`setup_toolchain` in config/functions; `flag_enabled` confronta parole
intere). `+lto-parallel`, preso da una LibreELEC vecchia, non corrispondeva a
niente: i 19 core, Mesa e wpa_supplicant non hanno mai avuto l'LTO. Elencando
i flag usati nell'albero contro quelli che `flag_enabled` conosce,
`lto-parallel` e' l'unico sconosciuto (22 pacchetti); `gold`, `bfd`, `mold`
sono i linker, che si guardano a parte. Ora i core hanno `+lto`: `-flto=N
-fno-fat-lto-objects` piu' i `-Werror=odr`, `-Werror=lto-type-mismatch`,
`-Werror=strict-aliasing` di LibreELEC, che fermano un core su cui l'LTO
rischierebbe codice sbagliato (`-Werror=x` accende anche `-Wx`). Un core che
non compila cosi' lo toglie `--keep-going`, e la build di prova dice quali.
Mesa su un ramo a parte (`ci-test/mesa-lto`): e' un pacchetto di sistema, e un
suo errore fermerebbe la build prima dei core. wpa_supplicant senza LTO:
per un demone del Wi-Fi non serve. verify-claims controlla `+lto` sui 19 core
(se l'LTO dei core e' acceso: il build script passa `RF35H_CORE_LTO`) e che
`+lto-parallel` non ci sia piu'. `--no-core-lto` torna a voler dire qualcosa.

**Kernel 7.2.9** (uscito il 3/10). SHA256 di `linux-7.2.9.tar.xz` da due
fonti indipendenti: l'hash di nixpkgs (`kernels-org.json`, base32 di Nix
convertito; la stessa conversione da' per la 7.2.7 il valore gia' in uso) e
il `sha256sums.asc` di kernel.org; coincidono. Le 8 patch del kernel (0062 e
9901 generiche, poi 0000, 0012, r-024, r-025, z-002, z-010 del device,
nell'ordine di scripts/unpack) applicano a fuzz 0 sul tag v7.2.9 del mirror
stable. Fra 7.2.7 e 7.2.9 nelle parti che ci riguardano (panfrost, drm
rockchip, dw_mmc, rk817, dts px30, audio) nessun cambiamento; piccoli fix nel
core mmc e nel governor termico step_wise.

La versione ora sta in un posto solo, `integration/linux-rf35h.patch` (era
`linux-7.2.7-rf35h.patch`): apply.sh la legge per il controllo finale,
verify-claims controlla che l'albero abbia quella versione e quello SHA256,
verify-kernel ricava PATCHLEVEL e SUBLEVEL attesi dal package.mk dell'albero
(non piu' "7" scritto nello script) e cerca il sorgente in `linux-[0-9]*`.
test-verify-tools: 38 prove (2 nuove: package.mk 7.2.9 con sorgente 7.2.7
in cache esce 1 sul SUBLEVEL; versioni uguali esce 0).

**CI.** Il titolo di ogni run dice cosa costruisce ("Release v1.1.0",
"Build di prova (ramo)", "ripresa da N"): gli input di Run workflow non si
vedono dall'API, e nella run #8 non si poteva dire se era una release. Le
note di release elencano i commit dall'ultima release vera (`git describe`
escludendo i tag con il trattino; il checkout del job release ora ha la
storia intera). Provato su un clone con tag finti.

**Upstream ogni settimana** (`upstream.yml`, lunedi' 04:23 UTC; a mano con
`dry_run` e `kernel_version`). Lakka devel e' fermo al commit pinnato dal
9/5 (verificato il 4/10), il kernel 7.2 no. Per il kernel il giro completo e'
automatico fino alla build di prova: `tools/upstream-kernel.sh` legge la
versione dalla patch d'integrazione, chiede a `releases.json` l'ultimo
7.2.y, scarica tarball, `.tar.sign` e `sha256sums.asc`, verifica la firma
sul `.tar` non compresso con le chiavi del WKD di kernel.org confrontate con
le impronte di kernel.org/signature.html (Torvalds, Kroah-Hartman, Levin,
Hutchings), lo SHA256 contro `sha256sums.asc`, poi applica le patch del
kernel a fuzz 0 prendendole da un albero Lakka pinnato con apply.sh sopra.
Solo allora: ramo `ci-test/kernel-X` (commit di github-actions[bot] con le
due righe e la riga Provenienza), `gh workflow run build.yml` (un push del
GITHUB_TOKEN non avvia altri workflow) e un issue con i comandi per il
merge. Un ramo gia' esistente vuol dire gia' proposto. Se il ramo 7.2 sparisce
da kernel.org o e' a fine vita, solo un avviso: cambiare ramo e' una scelta.
Per Lakka solo un issue, aggiornato e chiuso da solo (`tools/upstream-lakka.sh`):
le patch d'integrazione sono scritte contro il commit pinnato, un ramo
automatico fallirebbe al dry run. Provati in locale con kernel.org, gpg e gh
finti (Lakka, apply.sh e le patch veri; tarball rifatto dal tag v7.2.9):
--dry-run, il giro vero contro un origin locale (ramo, commit, patch
aggiornata, build e issue chiesti), il secondo giro ("gia' proposto"), e
l'avviso di Lakka con l'issue da aggiornare.

**Le patch del kernel verificate anche in CI.** `check_kernel` a fine build
(verify-kernel) in CI non poteva funzionare: con `AUTOREMOVE=yes`
LibreELEC cancella la cartella di build di un pacchetto appena nessun job la
usa piu' (`scripts/autoremove`), e quella del kernel spariva dopo i moduli
esterni; verify-kernel usciva 2 ("sorgente non trovato") e il build script
lo trattava come un avviso. Ora `integration/autoremove-keep-kernel-rf35h.patch`
tiene il sorgente di `linux` (~2 GB sui 100 liberi del runner) e il build
script ferma la build se verify-kernel esce 1 (una patch manca); con 2 resta
un avviso. verify-kernel provato sul sorgente vero: tag v7.2.9 con le 8
patch, 22 controlli ok; tolta r-024, esce 1 con i due MANCA; package.mk a
7.2.10 su sorgente 7.2.9, esce 1 sul SUBLEVEL.

**Le due build di prova** (4/10): `ci-test/v1.1` (core con `+lto`, kernel
7.2.9) 340/340 in 77 minuti; `ci-test/mesa-lto` (Mesa con `+lto`) 340/340 in
98 minuti (Mesa ricompilata da zero con l'LTO). In tutte e due 34 core,
nessuno escluso: con i `-Werror` di LibreELEC nessuno dei 19 core e
nemmeno Mesa si fermano.

## SSH: le opzioni sparivano anche salvando la configurazione (4/10/2026)

Rivedendo la guida: `retroarch-1007` correggeva il toggle del menu, ma
RetroArch tocca lo stesso file anche in `config_save_file()`. Con SSH acceso
lo apre in scrittura, cioe' lo svuota, a ogni salvataggio della
configurazione, e Lakka ha `config_save_on_exit = "true"`: ogni uscita,
spegnimento o riavvio dal menu. Spegnendo SSH dal menu, poi, il file veniva
cancellato. Quindi `SSH_ARGS="-o PasswordAuthentication=no"` durava fino al
primo riavvio, e la correzione del punto 2 della revisione di sicurezza non
bastava. Lo stesso per `bluez.conf`. Samba no: Lakka lo gestisce gia' con
`samba.disabled` (`retroarch-1000`), e `samba.conf` non viene toccato.

`retroarch-1007` ora fa come LibreELEC (`set_service` del suo add-on delle
impostazioni, ed e' quello che si aspetta `bluetooth-defaults.service`):
spento, `<servizio>.conf` diventa `<servizio>.disabled` con il suo
contenuto; acceso, il `.disabled` torna `.conf`, e solo se non c'e' nessuno
dei due se ne crea uno vuoto; un `.conf` che esiste non si riscrive. Una sola
funzione, `config_set_service_state()` in `configuration.c`, usata dal
salvataggio e dal toggle.

Provato sul RetroArch di Lakka (`69a4f0e`): la serie completa si applica,
1000-1010 senza fuzz, 99 e 999 con lo stesso fuzz di prima; `configuration.c`
e `menu_setting.c` compilano con `HAVE_LAKKA` senza warning; la funzione, con
il `filestream` vero di libretro-common, passa nove casi (acceso da zero,
salvataggio con le opzioni, spento, rispento, riacceso, entrambi i file,
nessun file, percorso senza `.conf`), e il controllo negativo sul codice
originale svuota il file come previsto. Tre righe nuove in `verify-claims`,
provate anche sulla vecchia patch (mancano tutte e tre). Sulle console con
un'immagine precedente la riga `SSH_ARGS` e' gia' andata persa: va rimessa
una volta dopo l'aggiornamento.

## Core: PlayStation, WonderSwan e Lynx nel set di default (4/10/2026)

Il set di default seguiva i sistemi della nostra collezione, ma le immagini
delle release le usa anche chi ha altri giochi, e un core che manca
nell'immagine si aggiunge solo ricompilando. Mancavano la PlayStation, uno
dei sistemi piu' giocati su questi handheld, e WonderSwan e Lynx, che avevano
gia' i loro override di scala intera (`Beetle WonderSwan`, `Handy`) senza
avere il core. Entrano quattro core, da 30 a 34:

| sistema | principale | riserva |
|---|---|---|
| PlayStation | `pcsx_rearmed` | nessuna nel default |
| WonderSwan / Color | `beetle_wswan` | nessuna: unico core WonderSwan |
| Atari Lynx | `handy` | `beetle_lynx` |

Verificati sull'albero pinnato: i quattro `package.mk` esistono, e per
Rockchip Lakka esclude solo `lr_moonlight` e `vitaquake3`, quindi li compila
gia' nelle sue immagini RK3326. `pcsx_rearmed` su aarch64 va con
`platform=unix DYNAREC=ari64`, e al commit pinnato (`3a7850f`) il dynarec ha
il backend arm64 (`assem_arm64.c`, `linkage_arm64.o` con `ARCH` aarch64 da
`-dumpmachine`). I `library_name` letti nei sorgenti ai commit pinnati:
`PCSX-ReARMed`, `Beetle WonderSwan`, `Handy`, `Beetle Lynx`; per l'ultimo un
override nuovo, uguale a quello di Handy (Lynx 4x), e `verify-claims` conta 11
`.cfg`. BIOS dal core-info pinnato (`bd81a0b`): facoltativi per
`pcsx_rearmed` (`scph5500/5501/5502.bin`, `psxonpsp660.bin`) e `handy`
(`lynxboot.img`), obbligatorio per `beetle_lynx`.

Fuori: `swanstation` (DuckStation) come riserva PlayStation: piu' pesante di
`pcsx_rearmed`, e non provato qui; Lakka stessa lo toglie sul Pi Zero 2.
`beetle_psx` lo e' ancora di piu'. Entrambi restano a un `--cores` di
distanza. Niente LTO sui nuovi: la lista resta quella dei core provati.

## Ora di rete: pool.ntp.org come predefinito (4/10/2026)

Il server predefinito era `it.pool.ntp.org`. Ora e' `pool.ntp.org`, come i
`FallbackTimeservers` di connman in LibreELEC: il pool risponde da se' con
server vicini a chi chiede, quindi in Italia non cambia nulla, e fuori
dall'Italia non si va piu' su server italiani. `it.pool.ntp.org` esce anche
dalla tendina (restano `pool.ntp.org`, `time.cloudflare.com`,
`time.google.com`); chi l'aveva scelto a mano lo tiene, perche' lo stato in
`/storage/.config/rf35h/ntp-server` vince sul predefinito.

Un dettaglio: `retroarch.cfg` conserva il valore della tendina, e una chiave
non vuota vince sul predefinito. Sulle console gia' installate il menu
avrebbe continuato a mostrare `it.pool.ntp.org` mentre `rf35h-ntp`, senza
stato, usava gia' il nuovo. Ora `rf35h-ntp on` scrive nello stato anche il
server predefinito, e il menu, che all'apertura rilegge lo stato, mostra
quello vero. La 1003 rigenerata con i due generatori e' identica byte per
byte a quella corretta a mano. Corretto anche un commento: `FallbackNTP` di
timesyncd conta solo con `NTP=` vuoto, quindi non e' un ripiego per il
server scelto; il ripiego e' connman.

Provato `rf35h-ntp` con busybox sh e un `systemctl` finto: il predefinito
finisce nello stato e in `NTP=`, `server time.google.com` lo sostituisce, una
scelta `it.pool.ntp.org` gia' salvata resta.

## Revisione prima della v1.1.0: cinque revisori, le correzioni (4/10/2026)

Chiesto dall'utente: "prepara una release stabile, correggi i bug che
stiamo sottovalutando". Cinque revisioni indipendenti, in parallelo e in
sola lettura (aggiornamento e avvio, sicurezza di rete, patch di RetroArch,
script e device tree, CI e release), poi quattro correzioni in parallelo su
worktree separati, unite qui. Ogni difetto e' stato riprodotto prima di
correggerlo, e ogni controllo nuovo di verify-claims fallisce sul codice
vecchio.

**Sicurezza.**
- Samba: in Lakka l'ospite senza password e' root, Samba e' acceso e non c'e'
  firewall. Chiunque nella stessa Wi-Fi scriveva in `/storage/.config`
  (`autostart.sh` gira come root all'avvio), in `/storage/.cache` (accende
  SSH, legge la password dell'AP) e in `/storage/.update` (un `.tar` li' si
  installa al riavvio), e poteva sostituire un core o far puntare una
  playlist a un `.so`. Scelta dell'utente: via Configfiles, Services e
  Update, Cores e Playlists in sola lettura (`samba-shares-rf35h.patch`;
  `testparm` sul file dopo le sostituzioni di `samba-config`).
- Samba riacceso per sempre dopo il modo transfer della USB-C, se RetroArch
  ripartiva con il flag messo da parte (1007).
- 1007: i toggle toccano i file prima del fork, senza troncare, e systemctl
  parte con un doppio fork (niente zombie, niente gare).
- Scraper: `db_name` di una playlist usato come cartella senza controlli
  (scriveva fuori da `thumbnails`); `scraper.conf` ora 0600.
- `rf35h-i2c`: ogni scrittura all'RK817 (anche tensioni e carica) vuole
  `RF35H_I2C_FORCE=1`, e gli argomenti sono controllati.

**Aggiornamenti e card.**
- La batteria si guardava solo scaricando: il `.tar` pronto stava gia' in
  `.update` e qualunque riavvio lo installava. Ora aspetta in
  `.update/.rf35h-staged` (l'init non lo vede e non lo cancella) e
  `rf35h-update install`, chiamato dal menu, ricontrolla batteria e spazio
  prima di metterlo in `.update`.
- Un'installazione fallita ora si vede nel menu; dall'ultima release si va
  solo avanti (con `TAG`/`URL` in `update.conf` resta possibile tornare
  indietro).
- `rf35h-reflash-system.sh` con un'immagine diversa da quella del primo
  flash lasciava in `extlinux.conf` l'UUID di `/storage` dell'immagine:
  console ferma. Ora prende quello vero della card, controlla il disco come
  `flash-sd.sh` e ha `--loader` per rimettere solo il boot loader.
  `rf35h-rescue.sh` rimette l'`autostart.sh` dell'utente.

**Console.**
- Volume dell'altoparlante sulla scheda sbagliata con un audio USB collegato
  all'avvio (card0): ora per id, `rk817ext`.
- Il colore dei LED salvato come "off" a ogni spegnimento.
- `config.ini` di IKEMEN svuotato con `/storage` pieno (l'awk di busybox
  esce 0 sugli errori di scrittura).
- La diagnostica d'avvio rallentava RetroArch; la sospensione per
  inattivita' interrompeva download, scraper e trasferimenti USB; i crash log
  si fermavano dopo una correzione all'indietro dell'orologio.
- Il link `invocation:` di systemd e' un symlink al suo ID, che come percorso
  non esiste: `path_is_valid()` (stat) e `[ -e ]` lo davano sempre assente.
  Scraper e System Update non si fermavano dalla loro voce, l'ora di rete
  risultava spenta, gli script dei LED non vedevano rf35h-ledd. Ora lstat e
  `-L`.

**Menu.** Valori vecchi subito dopo un cambio a tendina; menu fermo fino a
10-15 s fermando scraper o aggiornamento; uscita audio "usb" salvata per
indice (ora per nome, e senza la scheda si torna agli altoparlanti);
password Wi-Fi di 33-63 caratteri troncate; piu' quattro irrobustimenti
(fgets, fsync della cartella, un buffer della CPU, gli array rf35h nel
caricamento della config).

**CI e release.**
- Il controllo di re3 non poteva mai scattare: `unsquashfs -l | grep -q`
  con pipefail, SIGPIPE.
- Una build che aveva perso core per `--keep-going` diventava la release che
  tutte le console scaricano: ora la release si ferma (salvo
  `allow_incomplete`), con la mappa pacchetto -> core presa dall'albero.
- Core di 0 byte o non ELF fermano l'immagine; i pacchetti interrotti a fine
  parte si rifanno da zero nella parte dopo.
- Un trattino vuol dire sempre pre-release; un tag non pre-release deve stare
  sul ramo principale; "latest" solo alla versione piu' alta.

Provato: `tools/ci-check.sh` (shellcheck su 51 script; test-ci-build 61,
card-tools 34, ikemen 37, ra-guard 9, update 73, verify-tools 38); la serie
di RetroArch dal sorgente pulito, nostre a fuzz 0, 99 e 999 come prima;
1003 e 1004 rigenerate identiche; i file toccati compilano con `HAVE_LAKKA`
senza warning nuovi. Restano aperti, da provare sul device: VBUS sempre
accesa (anche in transfer e in sospensione, secondo il device tree); i task
Wi-Fi di RetroArch (uscita durante una connessione fallita, salvataggi
persi in quei 15 s, righe risolte per indice); "speakers" e' il device ALSA
di default, cioe' card0, che con un audio USB all'avvio e' la USB.

## v1.1.0-rc1 (4/10/2026)

Pre-release dalla run #11 (`b3884fa`, Run workflow con version e
prerelease), 340/340 in 120 minuti al primo tentativo, 34 core, nessuno
escluso; albero di 22 GB (il sorgente del kernel ora resta). Pubblicata alle
17:45 UTC come pre-release: `releases/latest` resta v1.0.0, le console non la
vedono. Note di release con "Changes since v1.0.0" (i sei commit). Da qui:
`rf35h-update` vero con `TAG=v1.1.0-rc1` in `update.conf` e VERSION=v1.0.0
scarica 638 MB, controlla dimensione e sha256, "ready: v1.1.0-rc1"; nel tar il
loader e' il known-good, i moduli sono in `lib/modules/7.2.9` (v1.0.0:
7.2.7).

**L'LTO arriva davvero?** Dimensioni dei `.so` nel SYSTEM, v1.0.0 contro rc1:
- cambiano 14 dei 19 core: cap32, crocods, fceumm (-1,2 MB), gambatte (-1,5
  MB), gearsystem, genesis_plus_gx, mednafen_ngp, mednafen_pce_fast (-1,0
  MB), mednafen_pce (-1,1 MB), nestopia (-1,3 MB), race, snes9x2005,
  stella2014, tgbdual. E Mesa: libgallium -178 KB, libvulkan_panfrost -698 KB;
- identici snes9x, snes9x2010, stella, mgba: i loro build file l'LTO lo
  mettevano gia' da soli (`LTO ?= -flto` nei Makefile per `platform=unix`,
  `BUILD_LTO` acceso in Release nel CMakeLists di mGBA), quindi ce l'avevano
  anche nella v1.0.0;
- identico sameboy, per un altro motivo: il target `libretro` del Makefile di
  SameBoy chiama `make -C libretro` con `CFLAGS="$(WARNINGS)"`, che butta via
  tutti i CFLAGS di LibreELEC: niente LTO e nemmeno `-mtune=cortex-a35`
  (resta il `-O2` del suo Makefile). Si sistema costruendo direttamente
  `-C libretro` (BOOTROMS_DIR e BIN come li passa il target): da fare dopo la
  prova della rc1, con una build di prova.
- invariati, come previsto, i core senza LTO (dynarec, giganti, giochi).

## v1.1.0 e la v1.2.0 (5/10/2026)

v1.1.0 dalla run #12 (`e2fb53c`, il merge della PR #1), pubblicata come
pre-release e poi promossa a mano: e' `releases/latest`. Contiene tutta la
rc1 (`b3884fa` e' sua antenata) piu' 33 commit. Il ramo principale dopo la
v1.1.0 ha solo documentazione: la v1.2.0, chiesta come release cumulativa di
rc1 e v1.1.0, sulla console e' la v1.1.0.

**"interrupted: select to resume" aggiornando dalla v1.0.0.** Il menu della
v1.0.0 (e della rc1) decide "sta girando?" con `path_is_valid()` sul link
`/run/systemd/units/invocation:rf35h-update.service`, che e' un symlink a un
percorso che non esiste: sempre falso. Durante il download lo stato
"downloading ..." diventa quindi "interrupted", e selezionare la voce non
ferma niente (ramo "non gira": `systemctl start` su una unit `Type=simple`
gia' attiva non fa nulla). A download finito lo stato e' "ready: <versione>,
select to restart and install" e la voce riavvia. Corretto da `eaaa503`
(lstat, v1.1.0); chi e' sulla v1.0.0 lo vede con qualunque release: lo dicono
la guida e le note di ogni release.

**Note della release.** "Changes since" partiva dall'ultimo tag senza
trattino: con la v1.1.0 ancora pre-release, le note di una v1.2.0 sarebbero
partite dalla v1.1.0, che nessuna console aveva. Ora, nel job release,
`ci-release-notes.sh` chiede a GitHub l'ultima release pubblicata e non
pre-release, `vX.Y.Z`, antenata del commit (fuori dal job, o se l'API non
risponde, il tag come prima), e mette il link alle sue note per chi aggiorna
da piu' indietro. Prove in `test-ci-build.sh` (7 nuove, una verificata
togliendo il controllo che prova).

## Standby: flicker e lentezza al risveglio (5/10/2026)

Segnalato dall'utente sulla v1.1.0: parte, ma dopo lo standby lo schermo
sfarfalla e la console e' molto lenta. Build della v1.2.0 annullata (run #13,
nessun tag ne' release): sarebbe stata la v1.1.0 con lo stesso problema.

Cosa si sa:
- fra v1.0.0 e v1.1.0 il percorso dello standby (logind, `rf35h-idle`,
  `rf35h-suspend.service`) non cambia in nulla che agisca al risveglio. Il
  kernel passa da 7.2.7 a 7.2.9: nei 896 commit stable nessuna modifica a clk
  rockchip, drm rockchip, pannelli, bridge DSI, phy, cpufreq, devfreq, opp,
  regolatori, mfd, pwm, backlight (`git log v7.2.7..v7.2.9` sui tag di
  gregkh/linux). Del percorso di sospensione toccano solo sched/cache (capacita'
  dell'LLC all'hotplug delle CPU: qui un solo LLC) e il governor step_wise
  (voti con `lower` diverso da 0: i nostri cooling map hanno 0);
- il 22/9, kernel 7.0.1, una ripresa e' nei log (crash-20260922): sospensione
  "deep" (Disabling non-boot CPUs, PSCI), poi il recupero dell'RK915. Del
  display non dicono niente;
- `clk-px30.c` (7.2.9) include `syscore_ops.h` ma non registra suspend ne'
  resume: nessun registro del CRU salvato o ripristinato. ROCKNIX ha
  `034-px30s-cru-suspend-resume-restore` (MODE_CON e CLKSEL_CON(0), sul
  modello di `clk-rk3288.c`) per un crash dopo il resume sul PX30S.

Ipotesi principale: al risveglio il firmware lascia un PLL (CPLL, NPLL o
GPLL) in slow mode, cioe' a 24 MHz. Il kernel non se ne accorge: la sua vista
e' in cache, e `rockchip_rk3036_pll_set_params` rimette in normal solo un PLL
che era gia' in normal. Il VOP con il dclk sbagliato sfarfalla, bus e GPU a 24
MHz rallentano tutto. Da confermare sul device.

`tools/rf35h-resume-diag.sh`: dump di CRU (0xff2b0000) e PMUCRU (0xff2bc000)
con devmem prima e dopo lo standby, stato dei PLL decodificato (modo, MHz dai
divisori, lock, power-down), cpufreq, devfreq, cooling, carico, interrupt,
dmesg; `ripristina` rimette nel modo di prima solo CPLL, NPLL e GPLL, e solo
se accesi e agganciati (APLL dipende dalla tensione della CPU, DPLL e' la
DDR del firmware). Provato sotto busybox con un devmem finto (registri e
maschera hiword).

### La correzione: r-034 di ROCKNIX e z-034 (5/10/2026)

L'utente conferma: anche la v1.0.0 aveva flicker e lentezza dopo lo standby
(non e' una regressione della v1.1.0), e chiede la v1.2.0 con la correzione
di ROCKNIX.

- `r-034-px30-cru-suspend-resume-restore.patch`: la `034` di ROCKNIX
  invariata (commit 633ec4f del 4/10, sha256 nel file). Registra in
  `clk-px30.c` un syscore che prima della sospensione salva MODE_CON (modo di
  APLL, DPLL, CPLL, NPLL) e CLKSEL_CON(0) (divisore della CPU) e al risveglio
  li riscrive (maschera hiword 0xffff0000), come `clk-rk3288.c` upstream. Il
  driver e' lo stesso per PX30 e PX30S. Le API sono quelle della 7.2
  (`struct syscore`, `register_syscore`, callback con `void *data`).
- `z-034-px30-pmucru-gpll-resume.patch`, nostra: il GPLL sta nel PMU CRU, il
  cui registro di modo (PX30_PMU_MODE, 0xff2bc020) r-034 non tocca. Salvato e
  rimesso allo stesso modo, ma solo il suo campo e solo se al risveglio il PLL
  e' acceso e agganciato (PLL_CON1: LOCK_STATUS bit 10, PWRDOWN bit 13, i bit
  di `clk-pll.c`): il modo normal su un PLL spento fermerebbe tutto quello che
  ne deriva. Altrimenti `pr_warn` e modo lasciato com'e'.

Verifiche: le due patch applicano a fuzz 0, in ordine, sulla 7.2.9 (gregkh,
tag v7.2.9); `clk-px30.o` compilato per arm64 (gcc 13.3, defconfig con
CLK_PX30, PM_SLEEP) con `-Werror`, senza avvisi anche con `W=1`;
nel disassemblato il resume legge GPLL_CON1, confronta i bit 10 e 13 (0x2400
contro 0x400), scrive `(modo & 3) | 0x30000` in PMU_MODE, poi CLKSEL_CON(0) e
MODE_CON con `| 0xffff0000`. verify-kernel controlla le due patch nel
sorgente della build, verify-claims nell'albero (220 verifiche).

Da provare sul device: standby e risveglio con la v1.2.0 (pre-release). Se
flicker o lentezza restano, `tools/rf35h-resume-diag.sh` dice quali registri
cambiano ancora.

## v1.2.0, pre-release (5/10/2026)

Run #14 (`de117e4`, Run workflow con version v1.2.0 e prerelease): 344/344
in 89 minuti al primo tentativo, 38 core, nessuno escluso; ccache al 63% di
colpi. Pubblicata pre-release alle 10:30 UTC: `releases/latest` resta la
v1.1.0. Note: "Changes since v1.1.0" (i quattro commit), il link alle note
della v1.1.0, l'avviso per chi aggiorna dalla v1.0.0 o dalla rc1. Verificata
da qui:
- `rf35h-update` della v1.1.0 con `TAG=v1.2.0`: scarica 639 MB, dimensione e
  sha256 giusti, "ready: v1.2.0" in `.rf35h-staged/`; quello della v1.0.0
  lo stesso, nella sua cartella; stesso file;
- nel tar: md5 di KERNEL e SYSTEM giusti; KERNEL Linux 7.2.9 con la stringa
  del `pr_warn` di z-034, che applica solo sopra r-034 (e verify-kernel, a
  fine build, le ha trovate tutte e due nel sorgente); loader = known-good
  (`52850532...`); DTB rf35h; moduli in `lib/modules/7.2.9`; re3 assente
  (l'unico "re3" nell'elenco del SYSTEM e' `pumpkinadventure3.cht`).

Da provare sulla console: standby e risveglio, piu' volte. Se va, la si
promuove senza ricostruirla:
`gh release edit v1.2.0 --repo debianita22/lakka-rf35h --prerelease=false --latest`.

### Standby: l'init del pannello partiva con il DSI spento (5/10/2026, sera)

Lettura del codice della 7.2.9, non piu' ipotesi sui tempi. Il driver del
pannello (z-002) manda tutta la sequenza di init in `prepare()`. `prepare()`
lo chiama il pre_enable del ponte del pannello, e
`drm_atomic_bridge_chain_pre_enable` scorre la catena **dall'ultimo al primo**:
il pannello prima del DSI, a meno che il pannello non chieda
`prepare_prev_first`. `dw-mipi-dsi` accende il controller (`dw_mipi_dsi_mode_set`,
`DSI_PWR_UP`, PHY) proprio nel suo pre_enable. Quindi l'init viene scritto in
un controller in reset: `dw_mipi_dsi_write` aspetta le FIFO vuote, le trova
vuote, ritorna 0. Nessun errore nel dmesg, che e' quello che si vedeva. Allo
spegnimento lo stesso al contrario: il DSI si spegne nel suo post_disable
prima di `unprepare()`, che manda display-off e sleep-in a un controller gia'
spento. I pannelli mainline che fanno l'init in prepare con un host DSI che si
accende in pre_enable mettono `prepare_prev_first` (st7701); st7703 manda
l'init in `enable()`, quando il DSI e' gia' acceso.

Altri progetti (ricerca su ROCKNIX, AURKNIX, arkos4clone, dArkOS, ArkOS,
Batocera, Lakka): nessuna segnalazione identica, quasi tutti sono ancora sul
kernel BSP 4.4 o non supportano lo standby. ROCKNIX `052e117` (GKD Pixel2,
mainline) ha corretto nello stesso driver `unprepare()`: un errore DCS usciva
prima di spegnere e lasciava `prepared` a vero, "schermo bloccato o corrotto
fino al riavvio". La nostra z-002 aveva ancora quella versione. AURKNIX ha lo
stesso driver senza la correzione.

Ramo `ci-test/panel` (da main, senza le prove di `ci-test/standby`):
- z-002: `ctx->panel.prepare_prev_first = prev_first` (parametro
  `panel_generic_dsi.prev_first`, predefinito 1; `=0` sulla riga di comando
  rimette l'ordine vecchio per confronto); `unprepare()` come ROCKNIX, senza
  uscite anticipate e senza il secondo reset ripetuto; una riga nel log a ogni
  accensione e spegnimento del pannello.
- z-036 nuova: una riga quando il DSI si accende e si spegne, e un avviso
  quando un comando DSI parte con `DSI_PWR_UP` in reset ("sent with the host
  powered down: lost").
- `tools/rf35h-panel-diag.sh`: `soc` (PX30 o PX30S dal DDR_GRF), `schermo`
  (spegne e riaccende lo schermo da sway, stesso percorso del risveglio senza
  standby), `standby`; raccoglie quelle righe e dice in che ordine sono andate.

Compilato su 7.2.9 (arm64, W=1, -Werror) con r-025: le patch applicano a fuzz
0 e danno l'albero provato. Non verificato sulla console. Se lo schermo dopo
lo standby e' pulito ma la console resta lenta, la lentezza ha un'altra causa
e va cercata a parte.

### Standby: prova sulla console con ci-21 (6/10/2026)

`rf35h-panel-diag.sh` sulla ci-21-13c91f5: PX30 (non PX30S, DDR_GRF_CON1
0x617). L'ordine ora e' quello giusto, sia spegnendo lo schermo da sway sia in
standby: pannello spento, poi DSI spento; DSI acceso, poi init del pannello;
nessun comando perso. All'avvio lo schermo va. Ma **basta spegnere e
riaccendere lo schermo da sway, senza standby, per avere sfarfallio e
lentezza**; dopo lo standby lo stesso. Quindi: non e' lo standby (clock,
firmware, regolatori), e non e' l'ordine DSI/pannello. E' qualcosa che la
prima accensione all'avvio fa e una riaccensione a sistema avviato no (o il
contrario). `prepare_prev_first` resta: e' corretto e non fa danni.

Registri DSI uguali fra prima e dopo (PWR_UP 1, MODE_CFG video, PHY_RSTZ 0xf);
INT_ST1 bit 7 (errore di scrittura nella FIFO dei pixel DPI) acceso anche nello
stato buono, quindi non discrimina. Prossimo passo:
`tools/rf35h-display-dump.sh` fotografa VOP, IOMMU del VOP, DSI, PHY, GRF del
VO, stato DRM, clock, interrupt al secondo e velocita' di CPU e memoria in
stato buono e rotto, e li confronta.
