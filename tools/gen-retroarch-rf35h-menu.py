#!/usr/bin/env python3
"""Aggiunge a RetroArch il menu "Device Settings" (impostazioni del device RF35H).

Prende il posto di "Bluetooth" nel menu Settings di Lakka: quella voce viene
nascosta quando il device e' un RF35H (esiste /usr/bin/rf35h-led), e al suo
posto compare il menu nostro. Sugli altri device niente cambia: nessun flag
di build, solo rilevamento a runtime, cosi' un solo binario serve tutti gli
RK3326 dell'albero.

Quattro voci:
  Sleep timer         (minuti, 0 = off)   -> /storage/.config/rf35h-idle.conf + restart rf35h-idle
  Screen brightness   (5..100 %)          -> rf35h-brightness N
  Joystick LEDs       (17 modi di mcu_led)-> rf35h-led <modo>
  Status LEDs         (charge/red/blue/both/off) -> rf35h-statusled <modo>
(poi ne sono arrivate altre: audio, USB, zram, NTP, scraper, aggiornamento)

System Update e' un'azione, come lo scraper: avvia o ferma
rf35h-update.service, il sottotitolo mostra lo stato che scrive rf35h-update,
e con un aggiornamento pronto chiama "rf35h-update install" (che ricontrolla
la batteria) e riavvia solo se esce 0. Sull'RF35H toglie "Update Lakka"
dall'Online Updater: quelle immagini sono per un RK3326 generico (kernel,
SYSTEM e loader), e installate qui lasciano la console senza avvio.

Ogni voce e' un setting vero di RetroArch (finisce in retroarch.cfg), con un
change_handler che applica subito. Quando il menu si apre, i valori vengono
riletti dal sistema: se hai cambiato la luminosita' con L1+vol, il menu
mostra quella, non l'ultima che aveva salvato lui.

Modellato riga per riga sul precedente HAVE_LAKKA_SWITCH (il menu "Nintendo
Switch Options"), che tocca gli stessi dieci file. Ogni ancora e' una stringa
esatta del sorgente: se non si trova, lo script si ferma invece di produrre
una patch a meta'.
"""
import sys, re

SRC = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ra/src"

def edit(path, pairs):
    p = f"{SRC}/{path}"
    s = open(p).read()
    for old, new in pairs:
        if s.count(old) != 1:
            sys.exit(f"{path}: ancora trovata {s.count(old)} volte, attesa 1:\n{old[:120]}")
        s = s.replace(old, new)
    open(p, "w").write(s)
    print(f"  {path}: {len(pairs)} modifiche")

# ---------------------------------------------------------------- msg_hash.h
edit("msg_hash.h", [
    ("   MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,\n",
     "   MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,\n"
     "   MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,\n"),
    ("   MENU_LBL_H(TIMEZONE),\n#endif\n",
     "   MENU_LBL_H(TIMEZONE),\n"
     "   MENU_LABEL(RF35H_SLEEP_MINUTES),\n"
     "   MENU_LABEL(RF35H_BRIGHTNESS),\n"
     "   MENU_LABEL(RF35H_JOYLED),\n"
     "   MENU_LABEL(RF35H_STATUSLED),\n"
     "   MENU_LABEL(RF35H_USB_MODE),\n"
     "   MENU_LABEL(RF35H_AUDIO_OUT),\n"
     "   MENU_LABEL(RF35H_SCRAPE),\n"
     "   MENU_LABEL(RF35H_SCRAPE_MISSING),\n"
     "   MENU_LABEL(RF35H_SCRAPE_REGION),\n"
     "   MENU_LABEL(RF35H_LEDSPEED),\n"
     "   MENU_LABEL(RF35H_ZRAM),\n"
     "   MENU_LABEL(RF35H_NTP),\n"
     "   MENU_LABEL(RF35H_RUMBLE),\n"
     "   MENU_LABEL(RF35H_SPEAKER_VOLUME),\n"
     "   MENU_LABEL(RF35H_NTP_SERVER),\n"
     "   MENU_LABEL(RF35H_UPDATE),\n"
     "#endif\n"),
    ("   MENU_LABEL(LAKKA_SERVICES),\n#ifdef HAVE_LAKKA_SWITCH\n",
     "   MENU_LABEL(LAKKA_SERVICES),\n"
     "#ifdef HAVE_LAKKA\n"
     "   MENU_LABEL(RF35H_SETTINGS),\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n"),
])

# ------------------------------------------------------- intl/msg_hash_lbl.h
edit("intl/msg_hash_lbl.h", [
    ("#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,\n",
     "#ifdef HAVE_LAKKA\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,\n   \"deferred_rf35h_settings_list\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SETTINGS,\n   \"rf35h_settings\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SLEEP_MINUTES,\n   \"rf35h_sleep_minutes\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_BRIGHTNESS,\n   \"rf35h_brightness\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_JOYLED,\n   \"rf35h_joyled\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_STATUSLED,\n   \"rf35h_statusled\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_USB_MODE,\n   \"rf35h_usb_mode\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_AUDIO_OUT,\n   \"rf35h_audio_out\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SCRAPE,\n   \"rf35h_scrape\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SCRAPE_MISSING,\n   \"rf35h_scrape_missing\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SCRAPE_REGION,\n   \"rf35h_scrape_region\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_LEDSPEED,\n   \"rf35h_ledspeed\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_ZRAM,\n   \"rf35h_zram\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_NTP,\n   \"rf35h_ntp\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_RUMBLE,\n   \"rf35h_rumble\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_SPEAKER_VOLUME,\n   \"rf35h_speaker_volume\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_NTP_SERVER,\n   \"rf35h_ntp_server\"\n   )\n"
     "MSG_HASH(\n   MENU_ENUM_LABEL_RF35H_UPDATE,\n   \"rf35h_update\"\n   )\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,\n"),
])

# -------------------------------------------------------- intl/msg_hash_us.h
STRINGS_US = '''MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS,
   "Device Settings"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SETTINGS,
   "Sleep timer, screen brightness, joystick and status LEDs of the XiFan RF35H."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SLEEP_MINUTES,
   "Sleep Timer"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SLEEP_MINUTES,
   "Suspend the console after this many minutes without input. 0 disables it."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_BRIGHTNESS,
   "Screen Brightness"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_BRIGHTNESS,
   "Backlight level. L1 + Volume does the same thing from anywhere."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_JOYLED,
   "Joystick LEDs"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_JOYLED,
   "Colour or effect of the RGB rings around the sticks. 'battery': colour follows the charge, breathes while charging, white when full. 'charging': off, breathes green while charging, solid green when full. 'alert': off, blinks red under 15%. 'rainbow' and 'strobe' animate at the speed below. They turn off while the console sleeps."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_STATUSLED,
   "Status LEDs"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_STATUSLED,
   "The red and blue LEDs. 'charge': red follows charging. 'battery': red under 20%, blinking under 10%, blue while charging. 'heartbeat' / 'activity': blue shows the system pulse or CPU load."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_USB_MODE,
   "USB-C Port"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_USB_MODE,
   "'host': gamepads, USB drives, keyboards, USB-C headphones. 'transfer': the console shows up on your PC as a network card; open \\\\lakka.local or ssh root@192.168.7.1 to copy files."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_AUDIO_OUT,
   "Audio Output"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_AUDIO_OUT,
   "'speakers': internal speakers and the headphone jack. 'usb': USB-C headphones or a USB DAC plugged into the USB-C port (host mode). Switches instantly."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SPEAKER_VOLUME,
   "Speaker Volume"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SPEAKER_VOLUME,
   "Output level of the sound chip, before the built-in amplifier. 28% matches the factory level ArkOS uses on this hardware. Separate from RetroArch's own Volume, which only scales the software mix."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_RUMBLE,
   "Rumble"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_RUMBLE,
   "Vibration motor on or off. On this device the motor is driven by a plain GPIO, so it is either off or at full strength: the 'Rumble Gain' slider under Input has no effect on intensity here."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_NTP,
   "Network Time (NTP)"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_NTP,
   "Keep the clock right over the network. The console has no battery-backed clock, so without this the date is wrong until something else fixes it."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_NTP_SERVER,
   "Time Server"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_NTP_SERVER,
   "Which pool to ask. A nearby one answers faster; the others stay as fallback."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_ZRAM,
   "Compressed RAM (zram)"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_ZRAM,
   "Use half the RAM as LZ4-compressed swap. The console has 730 MB and no swap otherwise: this keeps big cores (arcade, Dreamcast, DS) from being killed when memory runs out. Takes effect immediately."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_LEDSPEED,
   "LED Effect Speed"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_LEDSPEED,
   "Speed of the animated stick effects ('rainbow', 'strobe')."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE,
   "Scrape Thumbnails"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SCRAPE,
   "Box art, screenshots and title screens for every playlist, from ScreenScraper (ArcadeDB for arcade). Needs credentials in /storage/.config/rf35h/scraper.conf. Select again to stop."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE_MISSING,
   "Scrape Only Missing Thumbnails"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SCRAPE_MISSING,
   "Skip games that already have box art. Off fetches everything again."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE_REGION,
   "Scraper Region"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_SCRAPE_REGION,
   "Preferred region for box art when a game has several: Europe, USA, Japan or World."
   )
MSG_HASH(
   MENU_ENUM_LABEL_VALUE_RF35H_UPDATE,
   "System Update"
   )
MSG_HASH(
   MENU_ENUM_SUBLABEL_RF35H_UPDATE,
   "Download the latest release of this system from GitHub, check it, and install it at the next restart. ROMs, saves and settings stay. Select again to stop the download."
   )
'''
# ATTENZIONE all'ancora: la voce dello Switch sta DENTRO #ifdef HAVE_LAKKA_SWITCH.
# Inserire subito prima della MSG_HASH la metteva dentro quell'ifdef: stringhe
# scartate dal preprocessore, "null" a schermo, sottomenu vuoto. E il controllo
# -fsyntax-only non lo vede: codice escluso compila sempre. Si ancora
# sull'#ifdef e si mette PRIMA, dentro il nostro #ifdef HAVE_LAKKA.
edit("intl/msg_hash_us.h", [
    ("#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n",
     "#ifdef HAVE_LAKKA\n" + STRINGS_US + "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n"),
])

# -------------------------------------------------------- intl/msg_hash_it.h
STRINGS_IT = STRINGS_US.replace("Device Settings", "Impostazioni dispositivo") \
    .replace("Sleep timer, screen brightness, joystick and status LEDs of the XiFan RF35H.",
             "Timer di sospensione, luminosità, LED degli stick e LED di stato dell'XiFan RF35H.") \
    .replace('"Sleep Timer"', '"Timer di sospensione"') \
    .replace("Suspend the console after this many minutes without input. 0 disables it.",
             "Sospende la console dopo questi minuti senza input. 0 lo disattiva.") \
    .replace('"Screen Brightness"', '"Luminosità schermo"') \
    .replace("Backlight level. L1 + Volume does the same thing from anywhere.",
             "Livello della retroilluminazione. L1 + Volume fa lo stesso da qualunque punto.") \
    .replace('"Joystick LEDs"', '"LED degli stick"') \
    .replace("Colour or effect of the RGB rings around the sticks. 'battery': colour follows the charge, breathes while charging, white when full. 'charging': off, breathes green while charging, solid green when full. 'alert': off, blinks red under 15%. 'rainbow' and 'strobe' animate at the speed below. They turn off while the console sleeps.",
             "Colore o effetto degli anelli RGB intorno agli stick. 'battery': il colore segue la carica, respira in carica, bianco a carica completa. 'charging': spenti, respiro verde in carica, verde fisso a carica completa. 'alert': spenti, lampeggio rosso sotto il 15%. 'rainbow' e 'strobe' animano alla velocita' qui sotto. Si spengono quando la console dorme.") \
    .replace('"Status LEDs"', '"LED di stato"') \
    .replace("The red and blue LEDs. 'charge': red follows charging. 'battery': red under 20%, blinking under 10%, blue while charging. 'heartbeat' / 'activity': blue shows the system pulse or CPU load.",
             "I LED rosso e blu. 'charge': il rosso segue la carica. 'battery': rosso sotto il 20%, lampeggia sotto il 10%, blu in carica. 'heartbeat' / 'activity': il blu mostra il battito del sistema o il carico CPU.") \
    .replace('"USB-C Port"', '"Porta USB-C"') \
    .replace("'host': gamepads, USB drives, keyboards, USB-C headphones. 'transfer': the console shows up on your PC as a network card; open \\\\lakka.local or ssh root@192.168.7.1 to copy files.",
             "'host': pad, chiavette, tastiere, cuffie USB-C. 'transfer': la console appare al PC come scheda di rete; apri \\\\lakka.local o ssh root@192.168.7.1 per copiare i file.") \
    .replace('"Audio Output"', '"Uscita audio"') \
    .replace("'speakers': internal speakers and the headphone jack. 'usb': USB-C headphones or a USB DAC plugged into the USB-C port (host mode). Switches instantly.",
             "'speakers': altoparlanti interni e jack cuffie. 'usb': cuffie USB-C o DAC USB nella porta USB-C (modo host). Cambia al volo.") \
    .replace('"Speaker Volume"', '"Volume altoparlante"') \
    .replace("Output level of the sound chip, before the built-in amplifier. 28% matches the factory level ArkOS uses on this hardware. Separate from RetroArch's own Volume, which only scales the software mix.",
             "Livello d'uscita del chip audio, prima dell'amplificatore interno. Il 28% e' il livello di fabbrica di ArkOS su questo hardware. E' separato dal Volume di RetroArch, che scala solo il mix software.") \
    .replace('"Rumble"', '"Vibrazione"') \
    .replace("Vibration motor on or off. On this device the motor is driven by a plain GPIO, so it is either off or at full strength: the 'Rumble Gain' slider under Input has no effect on intensity here.",
             "Motore della vibrazione acceso o spento. Su questo device il motore e' comandato da un GPIO semplice, quindi e' o spento o a piena forza: il cursore 'Rumble Gain' sotto Input qui non cambia l'intensita'.") \
    .replace('"Network Time (NTP)"', '"Ora di rete (NTP)"') \
    .replace("Keep the clock right over the network. The console has no battery-backed clock, so without this the date is wrong until something else fixes it.",
             "Tiene l'ora giusta via rete. La console non ha un orologio tamponato, quindi senza questo la data resta sbagliata finche' non la sistema qualcos'altro.") \
    .replace('"Time Server"', '"Server dell'"'"'ora"') \
    .replace("Which pool to ask. A nearby one answers faster; the others stay as fallback.",
             "A quale pool chiedere. Uno vicino risponde prima; gli altri restano di riserva.") \
    .replace('"Compressed RAM (zram)"', '"RAM compressa (zram)"') \
    .replace("Use half the RAM as LZ4-compressed swap. The console has 730 MB and no swap otherwise: this keeps big cores (arcade, Dreamcast, DS) from being killed when memory runs out. Takes effect immediately.",
             "Usa meta' della RAM come swap compresso LZ4. La console ha 730 MB e nessuno swap: cosi' i core grossi (arcade, Dreamcast, DS) non vengono uccisi quando la memoria finisce. Ha effetto subito.") \
    .replace('"LED Effect Speed"', '"Velocita\' effetti LED"') \
    .replace("Speed of the animated stick effects ('rainbow', 'strobe').", "Velocita' degli effetti animati degli stick ('rainbow', 'strobe').") \
    .replace('"Scrape Thumbnails"', '"Scarica miniature"') \
    .replace("Box art, screenshots and title screens for every playlist, from ScreenScraper (ArcadeDB for arcade). Needs credentials in /storage/.config/rf35h/scraper.conf. Select again to stop.",
             "Copertine, schermate e schermate del titolo per ogni playlist, da ScreenScraper (ArcadeDB per l'arcade). Servono le credenziali in /storage/.config/rf35h/scraper.conf. Premi di nuovo per fermare.") \
    .replace('"Scrape Only Missing Thumbnails"', '"Scarica solo le miniature mancanti"') \
    .replace("Skip games that already have box art. Off fetches everything again.", "Salta i giochi che hanno gia' la copertina. Spento, riscarica tutto.") \
    .replace('"Scraper Region"', '"Regione dello scraper"') \
    .replace("Preferred region for box art when a game has several: Europe, USA, Japan or World.", "Regione preferita per le copertine quando un gioco ne ha piu' d'una: Europa, USA, Giappone o Mondo.") \
    .replace('"System Update"', '"Aggiornamento di sistema"') \
    .replace("Download the latest release of this system from GitHub, check it, and install it at the next restart. ROMs, saves and settings stay. Select again to stop the download.",
             "Scarica da GitHub l'ultima release di questo sistema, la controlla e la installa al prossimo riavvio. ROM, salvataggi e impostazioni restano. Premi di nuovo per fermare il download.")
edit("intl/msg_hash_it.h", [
    ("#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n",
     "#ifdef HAVE_LAKKA\n" + STRINGS_IT + "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\nMSG_HASH(\n   MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n"),
])

# --------------------------------------------------------------- config.def.h
edit("config.def.h", [
    ("#ifdef HAVE_LAKKA_SWITCH\n#define DEFAULT_SWITCH_OC false\n",
     "#ifdef HAVE_LAKKA\n"
     "/* XiFan RF35H: valori iniziali del menu \"Device Settings\". Al primo\n"
     " * avvio contano poco: appena il menu si apre, i valori veri vengono riletti\n"
     " * dal sistema (vedi rf35h_sync_settings in menu_displaylist.c). */\n"
     "#define DEFAULT_RF35H_SLEEP_MINUTES 10\n"
     "#define DEFAULT_RF35H_BRIGHTNESS 60\n"
     "#define DEFAULT_RF35H_JOYLED \"blue\"\n"
     "#define DEFAULT_RF35H_STATUSLED \"charge\"\n"
     "#define DEFAULT_RF35H_USB_MODE \"host\"\n"
     "#define DEFAULT_RF35H_AUDIO_OUT \"speakers\"\n"
     "#define DEFAULT_RF35H_SCRAPE_MISSING true\n"
     "#define DEFAULT_RF35H_SCRAPE_REGION \"eu\"\n"
     "#define DEFAULT_RF35H_LEDSPEED \"normal\"\n"
     "#define DEFAULT_RF35H_ZRAM true\n"
     "#define DEFAULT_RF35H_NTP true\n"
     "#define DEFAULT_RF35H_RUMBLE true\n"
     "#define DEFAULT_RF35H_SPEAKER_VOLUME 28\n"
     "#define DEFAULT_RF35H_NTP_SERVER \"it.pool.ntp.org\"\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n#define DEFAULT_SWITCH_OC false\n"),
])

# ------------------------------------------------------------ configuration.h
edit("configuration.h", [
    ("      unsigned menu_screensaver_timeout;\n",
     "      unsigned menu_screensaver_timeout;\n"
     "#ifdef HAVE_LAKKA\n"
     "      unsigned rf35h_sleep_minutes;\n"
     "      unsigned rf35h_brightness;\n"
     "      unsigned rf35h_speaker_volume;\n"
     "#endif\n"),
    ("      char timezone[TIMEZONE_LENGTH];\n",
     "      char timezone[TIMEZONE_LENGTH];\n"
     "#ifdef HAVE_LAKKA\n"
     "      char rf35h_joyled[32];\n"
     "      char rf35h_statusled[16];\n"
     "      char rf35h_usb_mode[16];\n"
     "      char rf35h_audio_out[16];\n"
     "      char rf35h_scrape_region[8];\n"
     "      char rf35h_ledspeed[8];\n"
     "      char rf35h_ntp_server[64];\n"
     "#endif\n"),
])

# ------------------------------------------------------------ configuration.c
edit("configuration.h", [
    ("      bool menu_show_online_updater;\n",
     "      bool menu_show_online_updater;\n"
     "#ifdef HAVE_LAKKA\n"
     "      bool rf35h_scrape_missing;\n"
     "      bool rf35h_zram;\n"
     "      bool rf35h_ntp;\n"
     "      bool rf35h_rumble;\n"
     "#endif\n"),
])
# devaOS RF35H: le 7 chiavi a tendina sono array, e per gli array l'ultimo
# argomento di SETTING_ARRAY (handle) decide se la chiave si rilegge dal file.
# Fino al 23/9 era false, copiato dallo schema dei bool dove non conta nulla:
# il menu mostrava valori vuoti, e il salvataggio successivo li scriveva.
RF35H_ARRAYS_FILL = r'''#ifdef HAVE_LAKKA
/* devaOS RF35H: fino al 23/9 le 7 chiavi a tendina erano registrate con
 * handle=false, che per gli array vuol dire "non rileggere dal file":
 * RetroArch le perdeva a ogni avvio e il salvataggio successivo scriveva il
 * valore vuoto. Il device non ne risentiva, perche' gli script conservano il
 * loro stato in /storage/.config/rf35h, ma il menu mostrava valori vuoti. Una
 * chiave vuota o assente prende quello stato reale, altrimenti il predefinito.
 * Nessuna delle opzioni ammette il valore vuoto. */
static void rf35h_array_fill(char *s, size_t len, const char *state,
      const char *def)
{
   size_t n;

   if (!string_is_empty(s))
      return;
   if (state)
   {
      char path[PATH_MAX_LENGTH];
      FILE *f;
      snprintf(path, sizeof(path), "/storage/.config/rf35h/%s", state);
      if ((f = fopen(path, "r")))
      {
         if (!fgets(s, (int)len, f))
            s[0] = '\0';
         fclose(f);
      }
   }
   /* una sola parola scritta da uno script: minuscole, cifre, '.' e '-' */
   for (n = 0; s[n] && s[n] != '\n' && s[n] != '\r'; n++)
   {
      if (!(   (s[n] >= 'a' && s[n] <= 'z')
            || (s[n] >= '0' && s[n] <= '9')
            || s[n] == '.' || s[n] == '-'))
      {
         n = 0;
         break;
      }
   }
   s[n] = '\0';
   if (!*s)
      strlcpy(s, def, len);
}

/* devaOS RF35H: quanto e' grande l'array a cui punta ptr. config_load_file
 * leggeva ogni array con PATH_MAX_LENGTH: le nostre tendine sono di 8-64
 * byte, e un valore lungo scritto a mano in retroarch.cfg traboccava sui
 * campi vicini di settings_t. Gli array di RetroArch restano come sono. */
static size_t rf35h_array_size(settings_t *settings, const char *ptr)
{
#define RF35H_ARRAY_SIZE(a) if (ptr == settings->arrays.a) return sizeof(settings->arrays.a)
   RF35H_ARRAY_SIZE(rf35h_joyled);
   RF35H_ARRAY_SIZE(rf35h_statusled);
   RF35H_ARRAY_SIZE(rf35h_usb_mode);
   RF35H_ARRAY_SIZE(rf35h_audio_out);
   RF35H_ARRAY_SIZE(rf35h_scrape_region);
   RF35H_ARRAY_SIZE(rf35h_ledspeed);
   RF35H_ARRAY_SIZE(rf35h_ntp_server);
#undef RF35H_ARRAY_SIZE
   return PATH_MAX_LENGTH;
}

/* devaOS RF35H: con "Audio Output = usb" audio_device nomina la scheda USB-C
 * (plughw:CARD=<id>,DEV=0; prima plughw:<indice>,0). La USB-C e' anche la
 * porta di ricarica: se all'avvio quella scheda non c'e', ALSA non apre il
 * dispositivo e RetroArch resta senza audio finche' non si cambia
 * l'impostazione. Si controlla qui, al caricamento, prima che l'audio parta:
 * una scheda che non e' in /proc/asound vuol dire dispositivo predefinito
 * (""), cioe' gli altoparlanti. Solo per i driver ALSA. */
static void rf35h_audio_device_check(settings_t *settings)
{
   char path[64];
   char *dev     = settings->arrays.audio_device;
   const char *c = strstr(dev, "CARD=");
   bool digits   = true;
   size_t n, i;

   if (!strstr(settings->arrays.audio_driver, "alsa"))
      return;
   if (c)
      c += STRLEN_CONST("CARD=");
   else if (!strncmp(dev, "hw:", 3) || !strncmp(dev, "plughw:", 7))
      c = strchr(dev, ':') + 1;
   else
      return;
   n = strcspn(c, ",");
   if (!n || n > 32)
      return;
   for (i = 0; i < n; i++)
   {
      if (c[i] < '0' || c[i] > '9')
         digits = false;
      if (!(   (c[i] >= 'a' && c[i] <= 'z') || (c[i] >= 'A' && c[i] <= 'Z')
            || (c[i] >= '0' && c[i] <= '9') || c[i] == '_' || c[i] == '-'))
         return;
   }
   /* un numero e' l'indice (cardN); un nome e' l'id, e ALSA mette in
    * /proc/asound un collegamento per ogni id */
   snprintf(path, sizeof(path), "/proc/asound/%s%.*s",
         digits ? "card" : "", (int)n, c);
   if (path_is_valid(path))
      return;
   RARCH_WARN("[RF35H] audio_device \"%s\": scheda assente, uso il dispositivo predefinito.\n",
         dev);
   dev[0] = '\0';
   strlcpy(settings->arrays.rf35h_audio_out, "speakers",
         sizeof(settings->arrays.rf35h_audio_out));
}

static void rf35h_arrays_fill(settings_t *settings)
{
   rf35h_array_fill(settings->arrays.rf35h_joyled,
         sizeof(settings->arrays.rf35h_joyled), "led", DEFAULT_RF35H_JOYLED);
   rf35h_array_fill(settings->arrays.rf35h_statusled,
         sizeof(settings->arrays.rf35h_statusled), "statusled", DEFAULT_RF35H_STATUSLED);
   rf35h_array_fill(settings->arrays.rf35h_ledspeed,
         sizeof(settings->arrays.rf35h_ledspeed), "ledspeed", DEFAULT_RF35H_LEDSPEED);
   rf35h_array_fill(settings->arrays.rf35h_ntp_server,
         sizeof(settings->arrays.rf35h_ntp_server), "ntp-server", DEFAULT_RF35H_NTP_SERVER);
   rf35h_array_fill(settings->arrays.rf35h_usb_mode,
         sizeof(settings->arrays.rf35h_usb_mode), "usb", DEFAULT_RF35H_USB_MODE);
   rf35h_array_fill(settings->arrays.rf35h_scrape_region,
         sizeof(settings->arrays.rf35h_scrape_region), NULL, DEFAULT_RF35H_SCRAPE_REGION);
   rf35h_audio_device_check(settings);
   /* audio_out non ha file di stato: il suo gestore imposta audio_device */
   if (string_is_empty(settings->arrays.rf35h_audio_out))
      strlcpy(settings->arrays.rf35h_audio_out,
            strncmp(settings->arrays.audio_device, "plughw:", 7) ? "speakers" : "usb",
            sizeof(settings->arrays.rf35h_audio_out));
}
#endif

'''
RF35H_ARRAY_LOOP = ('   /* Array settings  */\n'
    '   for (i = 0; i < (unsigned)array_settings_size; i++)\n'
    '   {\n'
    '      if (array_settings[i].flags & CFG_BOOL_FLG_HANDLE)\n'
    '         config_get_array(conf, array_settings[i].ident,\n'
    '               array_settings[i].ptr, PATH_MAX_LENGTH);\n'
    '   }\n')
# devaOS RF35H: le 7 tendine sono array di 8-64 byte dentro settings_t, e il
# ciclo li leggeva con PATH_MAX_LENGTH: un valore lungo scritto a mano in
# retroarch.cfg traboccava sui campi vicini. Per le nostre il ciclo passa la
# dimensione vera (rf35h_array_size); gli array di RetroArch restano come sono.
# (Non con un campo in config_array_setting riempito da SETTING_ARRAY: quella
# macro registra anche due path, log_dir e app_icon, in populate_settings_path.)
RF35H_ARRAY_LOOP_LEN = RF35H_ARRAY_LOOP.replace(
    '               array_settings[i].ptr, PATH_MAX_LENGTH);\n',
    '#ifdef HAVE_LAKKA\n'
    '               array_settings[i].ptr,\n'
    '               rf35h_array_size(settings, array_settings[i].ptr));\n'
    '#else\n'
    '               array_settings[i].ptr, PATH_MAX_LENGTH);\n'
    '#endif\n')
edit("configuration.c", [
    ('   SETTING_BOOL("menu_show_online_updater",      &settings->bools.menu_show_online_updater, true, DEFAULT_MENU_SHOW_ONLINE_UPDATER, false);\n',
     '   SETTING_BOOL("menu_show_online_updater",      &settings->bools.menu_show_online_updater, true, DEFAULT_MENU_SHOW_ONLINE_UPDATER, false);\n'
     '#ifdef HAVE_LAKKA\n'
     '   SETTING_BOOL("rf35h_scrape_missing",          &settings->bools.rf35h_scrape_missing, true, DEFAULT_RF35H_SCRAPE_MISSING, false);\n'
     '   SETTING_BOOL("rf35h_zram",                    &settings->bools.rf35h_zram, true, DEFAULT_RF35H_ZRAM, false);\n'
     '   SETTING_BOOL("rf35h_ntp",                     &settings->bools.rf35h_ntp, true, DEFAULT_RF35H_NTP, false);\n'
     '   SETTING_BOOL("rf35h_rumble",                  &settings->bools.rf35h_rumble, true, DEFAULT_RF35H_RUMBLE, false);\n'
     '#endif\n'),
    ('   SETTING_UINT("menu_screensaver_timeout",      &settings->uints.menu_screensaver_timeout, true, DEFAULT_MENU_SCREENSAVER_TIMEOUT, false);\n',
     '   SETTING_UINT("menu_screensaver_timeout",      &settings->uints.menu_screensaver_timeout, true, DEFAULT_MENU_SCREENSAVER_TIMEOUT, false);\n'
     '#ifdef HAVE_LAKKA\n'
     '   SETTING_UINT("rf35h_sleep_minutes",           &settings->uints.rf35h_sleep_minutes, true, DEFAULT_RF35H_SLEEP_MINUTES, false);\n'
     '   SETTING_UINT("rf35h_brightness",              &settings->uints.rf35h_brightness, true, DEFAULT_RF35H_BRIGHTNESS, false);\n'
     '   SETTING_UINT("rf35h_speaker_volume",          &settings->uints.rf35h_speaker_volume, true, DEFAULT_RF35H_SPEAKER_VOLUME, false);\n'
     '#endif\n'),
    ('   SETTING_ARRAY("audio_driver",                 settings->arrays.audio_driver, false, NULL, true);\n',
     '   SETTING_ARRAY("audio_driver",                 settings->arrays.audio_driver, false, NULL, true);\n'
     '#ifdef HAVE_LAKKA\n'
     '   SETTING_ARRAY("rf35h_joyled",                 settings->arrays.rf35h_joyled, true, DEFAULT_RF35H_JOYLED, true);\n'
     '   SETTING_ARRAY("rf35h_statusled",              settings->arrays.rf35h_statusled, true, DEFAULT_RF35H_STATUSLED, true);\n'
     '   SETTING_ARRAY("rf35h_usb_mode",               settings->arrays.rf35h_usb_mode, true, DEFAULT_RF35H_USB_MODE, true);\n'
     '   SETTING_ARRAY("rf35h_audio_out",              settings->arrays.rf35h_audio_out, true, DEFAULT_RF35H_AUDIO_OUT, true);\n'
     '   SETTING_ARRAY("rf35h_scrape_region",          settings->arrays.rf35h_scrape_region, true, DEFAULT_RF35H_SCRAPE_REGION, true);\n'
     '   SETTING_ARRAY("rf35h_ledspeed",               settings->arrays.rf35h_ledspeed, true, DEFAULT_RF35H_LEDSPEED, true);\n'
     '   SETTING_ARRAY("rf35h_ntp_server",             settings->arrays.rf35h_ntp_server, true, DEFAULT_RF35H_NTP_SERVER, true);\n'
     '#endif\n'),
    ("static bool config_load_file(global_t *global,\n",
     RF35H_ARRAYS_FILL + "static bool config_load_file(global_t *global,\n"),
    (RF35H_ARRAY_LOOP,
     RF35H_ARRAY_LOOP_LEN + "#ifdef HAVE_LAKKA\n   rf35h_arrays_fill(settings);\n#endif\n"),
])

# --------------------------------------------------------- menu_displaylist.h
edit("menu/menu_displaylist.h", [
    ("   DISPLAYLIST_LAKKA_SERVICES_LIST,\n#ifdef HAVE_LAKKA_SWITCH\n",
     "   DISPLAYLIST_LAKKA_SERVICES_LIST,\n"
     "#ifdef HAVE_LAKKA\n"
     "   DISPLAYLIST_RF35H_SETTINGS_LIST,\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n"),
])

# ---------------------------------------------------------------- menu_cbs.h
edit("menu/menu_cbs.h", [
    ("   ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST,\n",
     "   ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST,\n"
     "   ACTION_OK_DL_RF35H_SETTINGS_LIST,\n"),
])

# --------------------------------------------------------- cbs/menu_cbs_ok.c
edit("menu/cbs/menu_cbs_ok.c", [
    ("#ifdef HAVE_LAKKA_SWITCH\n      case ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST;\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\n      case ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST;\n#endif\n"
     "#ifdef HAVE_LAKKA\n      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n         return MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST;\n#endif\n"),
    ("      case ACTION_OK_DL_LAKKA_SERVICES_LIST:\n#ifdef HAVE_LAKKA_SWITCH\n      case ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST:\n#endif\n",
     "      case ACTION_OK_DL_LAKKA_SERVICES_LIST:\n#ifdef HAVE_LAKKA_SWITCH\n      case ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST:\n#endif\n"
     "#ifdef HAVE_LAKKA\n      case ACTION_OK_DL_RF35H_SETTINGS_LIST:\n#endif\n"),
    ("#ifdef HAVE_LAKKA_SWITCH\nSTATIC_DEFAULT_ACTION_OK_FUNC(action_ok_lakka_switch_options, ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST)\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\nSTATIC_DEFAULT_ACTION_OK_FUNC(action_ok_lakka_switch_options, ACTION_OK_DL_LAKKA_SWITCH_OPTIONS_LIST)\n#endif\n"
     "#ifdef HAVE_LAKKA\nSTATIC_DEFAULT_ACTION_OK_FUNC(action_ok_rf35h_settings, ACTION_OK_DL_RF35H_SETTINGS_LIST)\n"
     "/* Scraper: parte in background; se sta girando, la stessa voce lo ferma. */\n"
     "static int action_ok_rf35h_scrape(const char *path,\n"
     "      const char *label, unsigned type, size_t idx, size_t entry_idx)\n"
     "{\n"
     "   settings_t *settings = config_get_ptr();\n"
     "   const char *msg      = NULL;\n"
     "   (void)path; (void)label; (void)type; (void)idx; (void)entry_idx;\n"
     "   /* Sta girando? Lo dice systemd: il link invocation:<unit> esiste solo\n"
     "    * mentre la unit e' attiva. Il file di stato dopo un crash puo' mentire. */\n"
     "   if (path_is_valid(\"/run/systemd/units/invocation:rf35h-scrape.service\"))\n"
     "   {\n"
     "      /* devaOS RF35H: --no-block. Lo stop sincrono aspettava la fine del\n"
     "       * servizio, fino al suo TimeoutStopSec (10 s), col menu fermo. */\n"
     "      if (system(\"systemctl --no-block stop rf35h-scrape.service >/dev/null 2>&1\")) { }\n"
     "      msg = \"Scraping stopped\";\n"
     "   }\n"
     "   else if (!path_is_valid(\"/storage/.config/rf35h/scraper.conf\"))\n"
     "      msg = \"No ScreenScraper credentials: run rf35h-scrape --init over ssh and fill scraper.conf\";\n"
     "   else\n"
     "   {\n"
     "      FILE *a = fopen(\"/storage/.config/rf35h/scraper.args\", \"w\");\n"
     "      if (a)\n"
     "      {\n"
     "         fprintf(a, \"SCRAPE_ARGS=--region %s%s\\n\",\n"
     "               settings->arrays.rf35h_scrape_region,\n"
     "               settings->bools.rf35h_scrape_missing ? \"\" : \" --all\");\n"
     "         fclose(a);\n"
     "      }\n"
     "      if (system(\"systemctl start rf35h-scrape.service >/dev/null 2>&1\")) { }\n"
     "      msg = \"Scraping started, progress in Device Settings\";\n"
     "   }\n"
     "   runloop_msg_queue_push(msg, strlen(msg), 1, 180, true, NULL,\n"
     "         MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_INFO);\n"
     "   return 0;\n"
     "}\n"
     "#include <sys/wait.h>\n"
     "/* Aggiornamento di sistema: rf35h-update con la sua unit, come lo scraper.\n"
     " * Se sta girando, la stessa voce lo ferma (il file a meta' resta, il giro\n"
     " * dopo riprende). Con un aggiornamento pronto, \"rf35h-update install\" lo\n"
     " * mette in /storage/.update dopo aver ricontrollato la batteria, e si\n"
     " * riavvia solo se esce 0: l'init lo installa all'avvio. */\n"
     "static int action_ok_rf35h_update(const char *path,\n"
     "      const char *label, unsigned type, size_t idx, size_t entry_idx)\n"
     "{\n"
     "   const char *msg                   = NULL;\n"
     "   enum message_queue_category cat   = MESSAGE_QUEUE_CATEGORY_INFO;\n"
     "   char ready[PATH_MAX_LENGTH];\n"
     "   char why[192];\n"
     "   FILE *f;\n"
     "   (void)path; (void)label; (void)type; (void)idx; (void)entry_idx;\n"
     "   ready[0] = '\\0';\n"
     "   if (path_is_valid(\"/run/systemd/units/invocation:rf35h-update.service\"))\n"
     "   {\n"
     "      /* devaOS RF35H: --no-block, come lo scraper: lo stop sincrono teneva\n"
     "       * fermo il menu fino al TimeoutStopSec del servizio (15 s). */\n"
     "      if (system(\"systemctl --no-block stop rf35h-update.service >/dev/null 2>&1\")) { }\n"
     "      msg = \"System update stopped: select again to resume\";\n"
     "   }\n"
     "   else\n"
     "   {\n"
     "      if ((f = fopen(\"/storage/.config/rf35h/update.ready\", \"r\")))\n"
     "      {\n"
     "         if (!fgets(ready, sizeof(ready), f))\n"
     "            ready[0] = '\\0';\n"
     "         fclose(f);\n"
     "         ready[strcspn(ready, \"\\r\\n\")] = '\\0';\n"
     "      }\n"
     "      /* devaOS RF35H: pronto e ancora li'. Prima si riavviava subito, e la\n"
     "       * batteria era stata controllata solo al download: un'installazione\n"
     "       * interrotta all'avvio lascia la card da riscrivere. Ora \"rf35h-update\n"
     "       * install\" ricontrolla la batteria e mette l'aggiornamento in\n"
     "       * /storage/.update (meno di un secondo): esce 0 se si deve riavviare,\n"
     "       * altrimenti stampa il motivo su una riga e si resta nel menu. */\n"
     "      if (ready[0] && path_is_valid(ready))\n"
     "      {\n"
     "         char line[192];\n"
     "         int st = -1;\n"
     "         why[0] = '\\0';\n"
     "         if ((f = popen(\"/usr/bin/rf35h-update install\", \"r\")))\n"
     "         {\n"
     "            /* tutto l'output, per non lasciarlo a meta' (SIGPIPE): conta\n"
     "             * la prima riga */\n"
     "            while (fgets(line, sizeof(line), f))\n"
     "            {\n"
     "               if (!why[0])\n"
     "                  strlcpy(why, line, sizeof(why));\n"
     "            }\n"
     "            st = pclose(f);\n"
     "         }\n"
     "         if (st != -1 && WIFEXITED(st) && WEXITSTATUS(st) == 0)\n"
     "         {\n"
     "            /* CMD_EVENT_REBOOT salva la configurazione, come il riavvio\n"
     "             * del menu */\n"
     "            command_event(CMD_EVENT_REBOOT, NULL);\n"
     "            return 0;\n"
     "         }\n"
     "         why[strcspn(why, \"\\r\\n\")] = '\\0';\n"
     "         msg = why[0] ? why : \"System update not installed: rf35h-update install failed\";\n"
     "         cat = MESSAGE_QUEUE_CATEGORY_WARNING;\n"
     "      }\n"
     "      else\n"
     "      {\n"
     "         if (system(\"systemctl start rf35h-update.service >/dev/null 2>&1\")) { }\n"
     "         msg = \"Checking for updates, progress below the menu entry\";\n"
     "      }\n"
     "   }\n"
     "   runloop_msg_queue_push(msg, strlen(msg), 1,\n"
     "         cat == MESSAGE_QUEUE_CATEGORY_WARNING ? 300 : 180, true, NULL,\n"
     "         MESSAGE_QUEUE_ICON_DEFAULT, cat);\n"
     "   return 0;\n"
     "}\n"
     "#endif\n"),
    ("#ifdef HAVE_LAKKA_SWITCH\n         {MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS,                action_ok_lakka_switch_options},\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\n         {MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS,                action_ok_lakka_switch_options},\n#endif\n"
     "#ifdef HAVE_LAKKA\n         {MENU_ENUM_LABEL_RF35H_SETTINGS,                      action_ok_rf35h_settings},\n         {MENU_ENUM_LABEL_RF35H_SCRAPE,                        action_ok_rf35h_scrape},\n         {MENU_ENUM_LABEL_RF35H_UPDATE,                        action_ok_rf35h_update},\n#endif\n"),
])

# ------------------------------------------------------ cbs/menu_cbs_title.c
edit("menu/cbs/menu_cbs_title.c", [
    ("#ifdef HAVE_LAKKA_SWITCH\nDEFAULT_TITLE_MACRO(action_get_lakka_switch_options_list,       MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS)\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\nDEFAULT_TITLE_MACRO(action_get_lakka_switch_options_list,       MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS)\n#endif\n"
     "#ifdef HAVE_LAKKA\nDEFAULT_TITLE_MACRO(action_get_rf35h_settings_list,             MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS)\n#endif\n"),
    ("#ifdef HAVE_LAKKA_SWITCH\n      {MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,            action_get_lakka_switch_options_list},\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\n      {MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST,            action_get_lakka_switch_options_list},\n#endif\n"
     "#ifdef HAVE_LAKKA\n      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST,                  action_get_rf35h_settings_list},\n#endif\n"),
])

# --------------------------------------------------- cbs/menu_cbs_sublabel.c
edit("menu/cbs/menu_cbs_sublabel.c", [
    ("#ifdef HAVE_LAKKA_SWITCH\nDEFAULT_SUBLABEL_MACRO(action_bind_sublabel_switch_options,                MENU_ENUM_SUBLABEL_LAKKA_SWITCH_OPTIONS)\n",
     "#ifdef HAVE_LAKKA\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_settings,                MENU_ENUM_SUBLABEL_RF35H_SETTINGS)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_sleep_minutes,           MENU_ENUM_SUBLABEL_RF35H_SLEEP_MINUTES)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_brightness,              MENU_ENUM_SUBLABEL_RF35H_BRIGHTNESS)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_joyled,                  MENU_ENUM_SUBLABEL_RF35H_JOYLED)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_statusled,               MENU_ENUM_SUBLABEL_RF35H_STATUSLED)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_usb_mode,                MENU_ENUM_SUBLABEL_RF35H_USB_MODE)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_audio_out,               MENU_ENUM_SUBLABEL_RF35H_AUDIO_OUT)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_scrape_missing,          MENU_ENUM_SUBLABEL_RF35H_SCRAPE_MISSING)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_ledspeed,                MENU_ENUM_SUBLABEL_RF35H_LEDSPEED)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_zram,                    MENU_ENUM_SUBLABEL_RF35H_ZRAM)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_ntp,                     MENU_ENUM_SUBLABEL_RF35H_NTP)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_rumble,                  MENU_ENUM_SUBLABEL_RF35H_RUMBLE)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_speaker_volume,          MENU_ENUM_SUBLABEL_RF35H_SPEAKER_VOLUME)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_ntp_server,              MENU_ENUM_SUBLABEL_RF35H_NTP_SERVER)\n"
     "DEFAULT_SUBLABEL_MACRO(action_bind_sublabel_rf35h_scrape_region,           MENU_ENUM_SUBLABEL_RF35H_SCRAPE_REGION)\n"
     "#include <features/features_cpu.h>\n"
     "/* Lo stato dello scraper nel sottotitolo: idle, running n/m, done, error. */\n"
     "static int action_bind_sublabel_rf35h_scrape(\n"
     "      file_list_t *list, unsigned type, unsigned i,\n"
     "      const char *label, const char *path,\n"
     "      char *s, size_t len)\n"
     "{\n"
     "   /* Ozone chiama questo callback a ogni frame: il file si rilegge al\n"
     "    * massimo due volte al secondo, il resto e' cache. */\n"
     "   static char st[96];\n"
     "   static retro_time_t last_read = 0;\n"
     "   retro_time_t now = cpu_features_get_time_usec();\n"
     "   if (!last_read || now - last_read > 500000)\n"
     "   {\n"
     "      FILE *f   = fopen(\"/storage/.config/rf35h/scraper.status\", \"r\");\n"
     "      last_read = now;\n"
     "      st[0]     = '\\0';\n"
     "      if (f)\n"
     "      {\n"
     "         if (fgets(st, sizeof(st), f))\n"
     "            string_remove_all_chars(st, '\\n');\n"
     "         else\n"
     "            st[0] = '\\0';\n"
     "         fclose(f);\n"
     "      }\n"
     "      if (!strncmp(st, \"running\", 7) &&\n"
     "          !path_is_valid(\"/run/systemd/units/invocation:rf35h-scrape.service\"))\n"
     "         strlcpy(st, \"interrupted (select to start again)\", sizeof(st));\n"
     "   }\n"
     "   snprintf(s, len, \"%s\\n%s\", msg_hash_to_str(MENU_ENUM_SUBLABEL_RF35H_SCRAPE),\n"
     "         st[0] ? st : \"idle\");\n"
     "   return 1;\n"
     "}\n"
     "/* Lo stato dell'aggiornamento: la riga che scrive rf35h-update, o la\n"
     " * versione installata (VERSION di /etc/os-release) se non c'e' niente in\n"
     " * corso. Riletta al massimo due volte al secondo, come quella dello scraper. */\n"
     "static int action_bind_sublabel_rf35h_update(\n"
     "      file_list_t *list, unsigned type, unsigned i,\n"
     "      const char *label, const char *path,\n"
     "      char *s, size_t len)\n"
     "{\n"
     "   static char st[112];\n"
     "   static retro_time_t last_read = 0;\n"
     "   retro_time_t now = cpu_features_get_time_usec();\n"
     "   if (!last_read || now - last_read > 500000)\n"
     "   {\n"
     "      FILE *f   = fopen(\"/storage/.config/rf35h/update.status\", \"r\");\n"
     "      last_read = now;\n"
     "      st[0]     = '\\0';\n"
     "      if (f)\n"
     "      {\n"
     "         if (fgets(st, sizeof(st), f))\n"
     "            string_remove_all_chars(st, '\\n');\n"
     "         else\n"
     "            st[0] = '\\0';\n"
     "         fclose(f);\n"
     "      }\n"
     "      /* a meta' ma senza il servizio: fermato, o RetroArch riavviato */\n"
     "      if ((!strncmp(st, \"checking\", 8) || !strncmp(st, \"downloading\", 11)\n"
     "               || !strncmp(st, \"verifying\", 9))\n"
     "            && !path_is_valid(\"/run/systemd/units/invocation:rf35h-update.service\"))\n"
     "         strlcpy(st, \"interrupted: select to resume\", sizeof(st));\n"
     "      if (!st[0])\n"
     "      {\n"
     "         char line[128];\n"
     "         FILE *o = fopen(\"/etc/os-release\", \"r\");\n"
     "         strlcpy(st, \"installed: ?\", sizeof(st));\n"
     "         if (o)\n"
     "         {\n"
     "            while (fgets(line, sizeof(line), o))\n"
     "            {\n"
     "               if (!strncmp(line, \"VERSION=\", 8))\n"
     "               {\n"
     "                  string_remove_all_chars(line, '\"');\n"
     "                  string_remove_all_chars(line, '\\n');\n"
     "                  snprintf(st, sizeof(st), \"installed: %s\", line + 8);\n"
     "                  break;\n"
     "               }\n"
     "            }\n"
     "            fclose(o);\n"
     "         }\n"
     "      }\n"
     "   }\n"
     "   snprintf(s, len, \"%s\\n%s\", msg_hash_to_str(MENU_ENUM_SUBLABEL_RF35H_UPDATE), st);\n"
     "   return 1;\n"
     "}\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\nDEFAULT_SUBLABEL_MACRO(action_bind_sublabel_switch_options,                MENU_ENUM_SUBLABEL_LAKKA_SWITCH_OPTIONS)\n"),
    ("#ifdef HAVE_LAKKA_SWITCH\n         case MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_switch_options);\n",
     "#ifdef HAVE_LAKKA\n"
     "         case MENU_ENUM_LABEL_RF35H_SETTINGS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_settings);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_SLEEP_MINUTES:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_sleep_minutes);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_BRIGHTNESS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_brightness);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_JOYLED:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_joyled);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_STATUSLED:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_statusled);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_USB_MODE:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_usb_mode);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_AUDIO_OUT:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_audio_out);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_LEDSPEED:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_ledspeed);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_ZRAM:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_zram);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_NTP:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_ntp);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_RUMBLE:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_rumble);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_SPEAKER_VOLUME:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_speaker_volume);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_NTP_SERVER:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_ntp_server);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_SCRAPE:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_scrape);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_SCRAPE_MISSING:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_scrape_missing);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_SCRAPE_REGION:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_scrape_region);\n            break;\n"
     "         case MENU_ENUM_LABEL_RF35H_UPDATE:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_rf35h_update);\n            break;\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n         case MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS:\n            BIND_ACTION_SUBLABEL(cbs, action_bind_sublabel_switch_options);\n"),
])

# ---------------------------------------------- cbs/menu_cbs_deferred_push.c
edit("menu/cbs/menu_cbs_deferred_push.c", [
    ("#ifdef HAVE_LAKKA_SWITCH\nGENERIC_DEFERRED_PUSH(deferred_push_lakka_switch_options_list,      DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST)\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\nGENERIC_DEFERRED_PUSH(deferred_push_lakka_switch_options_list,      DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST)\n#endif\n"
     "#ifdef HAVE_LAKKA\nGENERIC_DEFERRED_PUSH(deferred_push_rf35h_settings_list,            DISPLAYLIST_RF35H_SETTINGS_LIST)\n#endif\n"),
    ("#ifdef HAVE_LAKKA_SWITCH\n      {MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST, deferred_push_lakka_switch_options_list},\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\n      {MENU_ENUM_LABEL_DEFERRED_LAKKA_SWITCH_OPTIONS_LIST, deferred_push_lakka_switch_options_list},\n#endif\n"
     "#ifdef HAVE_LAKKA\n      {MENU_ENUM_LABEL_DEFERRED_RF35H_SETTINGS_LIST, deferred_push_rf35h_settings_list},\n#endif\n"),
])

# --------------------------------------------------------- menu_displaylist.c
SYNC_FN = r'''
#ifdef HAVE_LAKKA
/* XiFan RF35H. Il menu "Device Settings" compare solo se gli script del
 * device ci sono: cosi' lo stesso RetroArch serve tutti gli RK3326 e sugli
 * altri non cambia niente. */
#define RF35H_LED_BIN        "/usr/bin/rf35h-led"
#define RF35H_STATE_DIR      "/storage/.config/rf35h"
#define RF35H_IDLE_CONF      "/storage/.config/rf35h-idle.conf"

static bool rf35h_present(void)
{
   return path_is_valid(RF35H_LED_BIN);
}

static bool rf35h_read_line(const char *path, char *s, size_t len)
{
   RFILE *f = filestream_open(path, RETRO_VFS_FILE_ACCESS_READ,
         RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (!f)
      return false;
   if (!filestream_gets(f, s, len))
   {
      filestream_close(f);
      return false;
   }
   filestream_close(f);
   string_trim_whitespace(s);
   return s[0] != '\0';
}

/* l'ora dell'ultimo script lanciato dal menu (rf35h_run, menu_setting.c) */
extern retro_time_t rf35h_last_run;

/* Rilegge dal sistema quello che il menu mostra. L1+vol cambia la
 * luminosita' senza passare da qui; rf35h-idle.conf si puo' editare a mano;
 * i modi dei LED li salvano gli script. Il menu deve dire la verita'. */
static void rf35h_sync_settings(settings_t *settings)
{
   char buf[64];

   /* devaOS RF35H: scelto un valore da una tendina, RetroArch ricostruisce
    * subito la lista, ma il gestore ha appena lanciato lo script in
    * background e il file di stato dice ancora il valore di prima: il menu
    * mostrava quello (e al salvataggio lo scriveva in retroarch.cfg). Per
    * 3 secondi dall'ultimo script valgono i valori in memoria, cioe' quelli
    * appena scelti. */
   if (rf35h_last_run
         && cpu_features_get_time_usec() - rf35h_last_run < 3000000)
      return;

   if (rf35h_read_line(RF35H_STATE_DIR "/brightness", buf, sizeof(buf)))
   {
      unsigned v = (unsigned)strtoul(buf, NULL, 10);
      if (v >= 5 && v <= 100)
         settings->uints.rf35h_brightness = v;
   }
   if (rf35h_read_line(RF35H_STATE_DIR "/led", buf, sizeof(buf)))
      strlcpy(settings->arrays.rf35h_joyled, buf, sizeof(settings->arrays.rf35h_joyled));
   if (rf35h_read_line(RF35H_STATE_DIR "/statusled", buf, sizeof(buf)))
      strlcpy(settings->arrays.rf35h_statusled, buf, sizeof(settings->arrays.rf35h_statusled));
   if (rf35h_read_line(RF35H_STATE_DIR "/ledspeed", buf, sizeof(buf)))
      strlcpy(settings->arrays.rf35h_ledspeed, buf, sizeof(settings->arrays.rf35h_ledspeed));
   /* zram: lo stato vero e' /proc/swaps, non il file: se il modulo non c'e' o
    * swapon e' fallita, la voce deve dire "off" anche con il file a "on". */
   {
      RFILE *sw = filestream_open("/proc/swaps", RETRO_VFS_FILE_ACCESS_READ,
            RETRO_VFS_FILE_ACCESS_HINT_NONE);
      bool on = false;
      if (sw)
      {
         while (filestream_gets(sw, buf, sizeof(buf)))
            if (strstr(buf, "/dev/zram0"))
            {
               on = true;
               break;
            }
         filestream_close(sw);
      }
      settings->bools.rf35h_zram = on;
   }
   /* Volume altoparlante: il percento salvato dallo script (0..100) */
   if (rf35h_read_line(RF35H_STATE_DIR "/dac-volume", buf, sizeof(buf)))
   {
      unsigned v = (unsigned)strtoul(buf, NULL, 10);
      if (v <= 100)
         settings->uints.rf35h_speaker_volume = v;
   }
   /* Rumble: la verita' e' il sysfs del driver, non il file */
   if (rf35h_read_line("/sys/devices/platform/rocknix-singleadc-joypad/rumble_enable", buf, sizeof(buf)))
      settings->bools.rf35h_rumble = (buf[0] == '1');
   /* NTP: lo stato vero e' la unit attiva, non il file */
   settings->bools.rf35h_ntp = path_is_valid(
         "/run/systemd/units/invocation:systemd-timesyncd.service");
   if (rf35h_read_line(RF35H_STATE_DIR "/ntp-server", buf, sizeof(buf)))
      strlcpy(settings->arrays.rf35h_ntp_server, buf,
            sizeof(settings->arrays.rf35h_ntp_server));
   if (rf35h_read_line(RF35H_STATE_DIR "/usb", buf, sizeof(buf)))
      strlcpy(settings->arrays.rf35h_usb_mode, buf, sizeof(settings->arrays.rf35h_usb_mode));
   /* l'uscita audio la dice RetroArch stesso: se audio_device punta a una
    * scheda hw diversa dalla 0, siamo su USB */
   strlcpy(settings->arrays.rf35h_audio_out,
         (strstr(settings->arrays.audio_device, "hw:") && !strstr(settings->arrays.audio_device, "hw:0")) ? "usb" : "speakers",
         sizeof(settings->arrays.rf35h_audio_out));
   if (rf35h_read_line(RF35H_IDLE_CONF, buf, sizeof(buf)))
   {
      const char *eq = strchr(buf, '=');
      if (eq)
      {
         unsigned m = (unsigned)strtoul(eq + 1, NULL, 10);
         if (m <= 60)
            settings->uints.rf35h_sleep_minutes = m;
      }
   }
}
#endif
'''
edit("menu/menu_displaylist.c", [
    # Settings > Services: anche qui c'e' un toggle Bluetooth, e la board non ha
    # il Bluetooth. La lista e' un array fisso con un for: si salta la voce.
    # (Ancora presa byte per byte dal sorgente: c'e' una riga vuota prima del for.)
    ('               {MENU_ENUM_LABEL_BLUETOOTH_ENABLE,                                      PARSE_ONLY_BOOL},\n               {MENU_ENUM_LABEL_LOCALAP_ENABLE,                                        PARSE_ONLY_BOOL},\n               {MENU_ENUM_LABEL_TIMEZONE,                                              PARSE_ONLY_STRING_OPTIONS},\n            };\n\n            for (i = 0; i < ARRAY_SIZE(build_list); i++)\n            {\n               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(list,\n',
     '               {MENU_ENUM_LABEL_BLUETOOTH_ENABLE,                                      PARSE_ONLY_BOOL},\n               {MENU_ENUM_LABEL_LOCALAP_ENABLE,                                        PARSE_ONLY_BOOL},\n               {MENU_ENUM_LABEL_TIMEZONE,                                              PARSE_ONLY_STRING_OPTIONS},\n            };\n\n            for (i = 0; i < ARRAY_SIZE(build_list); i++)\n            {\n               /* RF35H: niente Bluetooth sulla board, niente toggle. */\n               if (build_list[i].enum_idx == MENU_ENUM_LABEL_BLUETOOTH_ENABLE && rf35h_present())\n                  continue;\n               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(list,\n'),

    # helper: subito prima della funzione che costruisce le liste
    ("unsigned menu_displaylist_build_list(\n",
     SYNC_FN + "\nunsigned menu_displaylist_build_list(\n"),
    # la lista del sottomenu
    ("#ifdef HAVE_LAKKA_SWITCH\n      case DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST:\n         {\n            static const menu_displaylist_build_info_t build_list[] = {\n",
     "#ifdef HAVE_LAKKA\n      case DISPLAYLIST_RF35H_SETTINGS_LIST:\n         {\n"
     "            static const menu_displaylist_build_info_t build_list[] = {\n"
     "               {MENU_ENUM_LABEL_RF35H_SLEEP_MINUTES,                                   PARSE_ONLY_UINT},\n"
     "               {MENU_ENUM_LABEL_RF35H_BRIGHTNESS,                                      PARSE_ONLY_UINT},\n"
     "               {MENU_ENUM_LABEL_RF35H_JOYLED,                                          PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_STATUSLED,                                       PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_LEDSPEED,                                        PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_USB_MODE,                                        PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_AUDIO_OUT,                                       PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_SPEAKER_VOLUME,                                  PARSE_ONLY_UINT},\n"
     "               {MENU_ENUM_LABEL_RF35H_RUMBLE,                                          PARSE_ONLY_BOOL},\n"
     "               {MENU_ENUM_LABEL_RF35H_ZRAM,                                            PARSE_ONLY_BOOL},\n"
     "               {MENU_ENUM_LABEL_RF35H_NTP,                                             PARSE_ONLY_BOOL},\n"
     "               {MENU_ENUM_LABEL_RF35H_NTP_SERVER,                                      PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_SCRAPE,                                          PARSE_ACTION},\n"
     "               {MENU_ENUM_LABEL_RF35H_SCRAPE_MISSING,                                  PARSE_ONLY_BOOL},\n"
     "               {MENU_ENUM_LABEL_RF35H_SCRAPE_REGION,                                   PARSE_ONLY_STRING_OPTIONS},\n"
     "               {MENU_ENUM_LABEL_RF35H_UPDATE,                                          PARSE_ACTION},\n"
     "            };\n\n"
     "            rf35h_sync_settings(settings);\n\n"
     "            for (i = 0; i < ARRAY_SIZE(build_list); i++)\n"
     "            {\n"
     "               if (MENU_DISPLAYLIST_PARSE_SETTINGS_ENUM(list,\n"
     "                        build_list[i].enum_idx,  build_list[i].parse_type,\n"
     "                        false) == 0)\n"
     "                  count++;\n"
     "            }\n"
     "         }\n"
     "         break;\n"
     "#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n      case DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST:\n         {\n            static const menu_displaylist_build_info_t build_list[] = {\n"),
    # la voce nel menu Settings, al posto di Bluetooth
    ("               {MENU_ENUM_LABEL_BLUETOOTH_SETTINGS,          PARSE_ACTION, true},\n#ifdef HAVE_NETWORKING\n",
     "               {MENU_ENUM_LABEL_BLUETOOTH_SETTINGS,          PARSE_ACTION, true},\n"
     "#ifdef HAVE_LAKKA\n"
     "               {MENU_ENUM_LABEL_RF35H_SETTINGS,              PARSE_ACTION, true},\n"
     "#endif\n"
     "#ifdef HAVE_NETWORKING\n"),
    # il filtro: Bluetooth via, RF35H dentro, solo sull'RF35H
    ("                     /* MISSING:\n                      * MENU_ENUM_LABEL_BLUETOOTH_SETTINGS\n",
     "#ifdef HAVE_LAKKA\n"
     "                  case MENU_ENUM_LABEL_BLUETOOTH_SETTINGS:\n"
     "                     build_list[i].checked = !rf35h_present();\n"
     "                     break;\n"
     "                  case MENU_ENUM_LABEL_RF35H_SETTINGS:\n"
     "                     build_list[i].checked = rf35h_present();\n"
     "                     break;\n"
     "#endif\n"
     "                     /* MISSING:\n                      * MENU_ENUM_LABEL_BLUETOOTH_SETTINGS\n"),
    # Online Updater: "Update Lakka" scarica le immagini di Lakka per un RK3326
    # generico. Installate qui lascerebbero la console senza avvio (il loader
    # e il kernel non sono i nostri), e il download sta tutto in RAM. Sull'RF35H
    # si aggiorna da Device Settings > System Update.
    ("#ifdef HAVE_LAKKA\n               if (menu_entries_append(info->list,\n                        msg_hash_to_str(MENU_ENUM_LABEL_VALUE_UPDATE_LAKKA),\n",
     "#ifdef HAVE_LAKKA\n"
     "               /* RF35H: gli aggiornamenti di Lakka sono per un RK3326\n"
     "                * generico e lascerebbero la console senza avvio: si\n"
     "                * aggiorna da Device Settings > System Update. */\n"
     "               if (!rf35h_present() && menu_entries_append(info->list,\n"
     "                        msg_hash_to_str(MENU_ENUM_LABEL_VALUE_UPDATE_LAKKA),\n"),
    # il case che manda la lista al parser generico
    ("         case DISPLAYLIST_LAKKA_SERVICES_LIST:\n#ifdef HAVE_LAKKA_SWITCH\n         case DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST:\n#endif\n",
     "         case DISPLAYLIST_LAKKA_SERVICES_LIST:\n"
     "#ifdef HAVE_LAKKA\n         case DISPLAYLIST_RF35H_SETTINGS_LIST:\n#endif\n"
     "#ifdef HAVE_LAKKA_SWITCH\n         case DISPLAYLIST_LAKKA_SWITCH_OPTIONS_LIST:\n#endif\n"),
])

# ------------------------------------------------------------ menu_setting.c
HANDLERS = r'''
#if defined(HAVE_LAKKA)
/* XiFan RF35H: ogni voce del menu applica subito, chiamando gli script del
 * device. I valori restano anche in retroarch.cfg, ma la verita' e' quella
 * degli script (vedi rf35h_sync_settings in menu_displaylist.c). */
#define RF35H_JOYLED_MODES \
   "off|green|blue|red|cyan|orange|purple|white|flow|breathing|" \
   "breathing-red|breathing-green|breathing-blue|breathing-cyan|" \
   "breathing-orange|breathing-purple|breathing-white|" \
   "battery|charging|alert|rainbow|strobe"
#define RF35H_LED_SPEEDS "slow|normal|fast"
#include <retro_dirent.h>
#include <features/features_cpu.h>
/* devaOS RF35H: quando e' partito l'ultimo script (rf35h_run). Lo legge
 * rf35h_sync_settings in menu_displaylist.c: lo script gira in background, e
 * per qualche secondo il suo file di stato dice ancora il valore di prima. */
retro_time_t rf35h_last_run = 0;
#ifndef RF35H_STATE_DIR
#define RF35H_STATE_DIR      "/storage/.config/rf35h"
#endif
#define RF35H_STATUSLED_MODES "charge|battery|heartbeat|activity|red|blue|both|off"
#define RF35H_USB_MODES       "host|transfer"
#define RF35H_AUDIO_OUTS      "speakers|usb"
#define RF35H_SCRAPE_REGIONS  "eu|us|jp|wor"
#define RF35H_NTP_SERVERS     "it.pool.ntp.org|pool.ntp.org|time.cloudflare.com|time.google.com"

static void rf35h_run(const char *fmt, ...)
{
   char cmd[256];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(cmd, sizeof(cmd), fmt, ap);
   va_end(ap);
   rf35h_last_run = cpu_features_get_time_usec();
   if (system(cmd)) { /* gli script scrivono gia' su stderr */ }
}

static void rf35h_sleep_minutes_change_handler(rarch_setting_t *setting)
{
   unsigned m = *setting->value.target.unsigned_integer;
   rf35h_run("sh -c 'echo RF35H_IDLE_MINUTES=%u > /storage/.config/rf35h-idle.conf; "
             "systemctl restart rf35h-idle.service' &", m);
}

/* La luminosita' e' l'unica voce che si regola a scatti ripetuti: sh + script
 * a ogni passo (30-50 ms su A35) faceva scattare il menu tenendo premuto.
 * Si scrive in sysfs direttamente, con la stessa aritmetica di
 * rf35h-brightness (arrotondamento, minimo 5%, stesso file di stato), cosi'
 * L1+volume e il menu restano d'accordo. */
static void rf35h_brightness_change_handler(rarch_setting_t *setting)
{
   static char bl[PATH_MAX_LENGTH];
   char path[PATH_MAX_LENGTH];
   char buf[32];
   unsigned p = *setting->value.target.unsigned_integer;
   unsigned max = 255, v;
   RFILE *f;
   if (p < 5)   p = 5;
   if (p > 100) p = 100;
   if (bl[0] == '\0')
   {
      /* primo backlight con un file brightness, come find_backlight() */
      struct RDIR *d = retro_opendir("/sys/class/backlight");
      if (d)
      {
         while (retro_readdir(d))
         {
            const char *n = retro_dirent_get_name(d);
            if (!n || n[0] == '.')
               continue;
            fill_pathname_join_special(path, "/sys/class/backlight", n, sizeof(path));
            fill_pathname_join_special(bl, path, "brightness", sizeof(bl));
            if (path_is_valid(bl))
            {
               strlcpy(bl, path, sizeof(bl));
               break;
            }
            bl[0] = '\0';
         }
         retro_closedir(d);
      }
      if (bl[0] == '\0')
      {
         /* nessun backlight in sysfs: lascio fare allo script, che sa lamentarsi */
         rf35h_run("/usr/bin/rf35h-brightness %u >/dev/null 2>&1 &", p);
         return;
      }
   }
   fill_pathname_join_special(path, bl, "max_brightness", sizeof(path));
   f = filestream_open(path, RETRO_VFS_FILE_ACCESS_READ, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (f)
   {
      if (filestream_gets(f, buf, sizeof(buf)) && atoi(buf) > 0)
         max = (unsigned)atoi(buf);
      filestream_close(f);
   }
   v = (p * max + 50) / 100;
   if (v < 1) v = 1;
   fill_pathname_join_special(path, bl, "brightness", sizeof(path));
   f = filestream_open(path, RETRO_VFS_FILE_ACCESS_WRITE, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (f)
   {
      filestream_printf(f, "%u\n", v);
      filestream_close(f);
   }
   path_mkdir(RF35H_STATE_DIR);
   f = filestream_open(RF35H_STATE_DIR "/brightness", RETRO_VFS_FILE_ACCESS_WRITE, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   if (f)
   {
      filestream_printf(f, "%u\n", p);
      filestream_close(f);
   }
}

static void rf35h_joyled_change_handler(rarch_setting_t *setting)
{
   /* il nome del modo e' uno della lista chiusa: niente da sanificare */
   rf35h_run("/usr/bin/rf35h-led %s >/dev/null 2>&1 &", setting->value.target.string);
}

static void rf35h_statusled_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-statusled %s >/dev/null 2>&1 &", setting->value.target.string);
}
static void rf35h_ledspeed_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-led --speed %s >/dev/null 2>&1 &", setting->value.target.string);
}
/* zram: on/off salva anche lo stato, cosi' al boot la unit lo rispetta.
 * Asincrono: swapoff con pagine dentro puo' metterci qualche secondo. */
static void rf35h_zram_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-zram %s >/dev/null 2>&1 &",
         *setting->value.target.boolean ? "on" : "off");
}
/* L'ora di rete la fa systemd-timesyncd, che nell'immagine c'era gia' ma era
 * disattivato da una condizione della sua unit; rf35h-ntp la aggira e sceglie
 * il server. Asincrono: contattare un pool puo' metterci qualche secondo. */
/* Il driver rocknix-singleadc-joypad espone rumble_enable in sysfs. Sull'RF35H il
 * motore e' su un GPIO semplice (nessun PWM nel device tree), quindi il driver
 * fa solo start/stop: qualunque intensita' non nulla e' piena forza. E' per
 * questo che il "Rumble Gain" di RetroArch qui non regola nulla e questo
 * interruttore e' il controllo onesto. Scrive direttamente in sysfs, come la
 * luminosita', e salva lo stato per il ripristino al boot (rf35h-state). */
/* Volume dell'altoparlante: percentuale lineare sul registro del DAC, che e' gia'
 * in passi di dB (vedi rf35h-dac-volume). Separato dal volume di RetroArch. */
static void rf35h_speaker_volume_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-dac-volume %u >/dev/null 2>&1 &",
         *setting->value.target.unsigned_integer);
}
static size_t setting_get_string_representation_uint_rf35h_speaker_volume(
      rarch_setting_t *setting, char *s, size_t len)
{
   if (!setting)
      return 0;
   return snprintf(s, len, "%u%%", *setting->value.target.unsigned_integer);
}
static void rf35h_rumble_change_handler(rarch_setting_t *setting)
{
   /* rf35h-vibra scrive il sysfs del driver e salva lo stato per il
    * ripristino al boot (rf35h-state), creando la directory se manca. */
   rf35h_run("/usr/bin/rf35h-vibra %s >/dev/null 2>&1 &",
         *setting->value.target.boolean ? "on" : "off");
}
static void rf35h_ntp_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-ntp %s >/dev/null 2>&1 &",
         *setting->value.target.boolean ? "on" : "off");
}
static void rf35h_ntp_server_change_handler(rarch_setting_t *setting)
{
   rf35h_run("/usr/bin/rf35h-ntp server %s >/dev/null 2>&1 &",
         setting->value.target.string);
}

static void rf35h_usb_mode_change_handler(rarch_setting_t *setting)
{
   /* il cambio di ruolo e il gadget prendono un secondo: in background,
    * cosi' il menu non si blocca */
   rf35h_run("/usr/bin/rf35h-usb %s >/dev/null 2>&1 &", setting->value.target.string);
}

/* La prima scheda USB in /proc/asound/cards: l'indice ALSA, o -1, e in id
 * il suo id ("" se non e' fatto solo di lettere, cifre, '_' e '-').
 * Una riga tipo: " 1 [Headphones     ]: USB-Audio - USB-C Headphones"
 * (la seconda riga di ogni scheda, il nome lungo, non ha le parentesi). */
static int rf35h_usb_audio_card(char *id, size_t len)
{
   char line[256];
   int found = -1;
   RFILE *f = filestream_open("/proc/asound/cards",
         RETRO_VFS_FILE_ACCESS_READ, RETRO_VFS_FILE_ACCESS_HINT_NONE);
   id[0] = '\0';
   if (!f)
      return -1;
   while (filestream_gets(f, line, sizeof(line)))
   {
      const char *b = strchr(line, '[');
      const char *e = b ? strstr(b, "]: ") : NULL;
      if (!e)
         continue;
      if (strstr(e, "USB-Audio") || strstr(e, "USB Audio"))
      {
         const char *p = b + 1;
         size_t n      = 0;
         found         = atoi(line);
         /* l'id finisce al primo spazio (allineamento) o alla ']' */
         while (p + n < e && p[n] != ' ' && n + 1 < len)
         {
            char c = p[n];
            if (!(   (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c == '_' || c == '-'))
               break;
            id[n++] = c;
         }
         /* fermato prima della fine (carattere strano, troppo lungo): niente id */
         if (p + n < e && p[n] != ' ')
            n = 0;
         id[n] = '\0';
         break;
      }
   }
   filestream_close(f);
   return found;
}

/* L'unica voce che non passa da uno script: audio_device e' di RetroArch, e
 * CMD_EVENT_AUDIO_REINIT e' quello che il suo stesso menu Audio > Device fa.
 * Niente riavvio: l'audio passa alla cuffia USB-C mentre il gioco gira. */
static void rf35h_audio_out_change_handler(rarch_setting_t *setting)
{
   settings_t *settings = config_get_ptr();
   if (string_is_equal(setting->value.target.string, "usb"))
   {
      char id[32];
      int card = rf35h_usb_audio_card(id, sizeof(id));
      if (card < 0)
      {
         const char *_msg = "No USB audio device found: keep the USB-C port in host mode and plug the headphones in first.";
         runloop_msg_queue_push(_msg, strlen(_msg), 1, 180, true, NULL,
               MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_WARNING);
         strlcpy(setting->value.target.string, "speakers",
               sizeof(settings->arrays.rf35h_audio_out));
         return;
      }
      /* devaOS RF35H: la scheda per id, non per indice. L'indice dipende
       * dall'ordine in cui le schede compaiono, e al riavvio dopo poteva
       * essere un'altra scheda o nessuna; l'id resta lo stesso. Se all'avvio
       * la scheda non c'e', rf35h_audio_device_check (configuration.c)
       * torna al dispositivo predefinito. */
      if (id[0])
         snprintf(settings->arrays.audio_device, sizeof(settings->arrays.audio_device),
               "plughw:CARD=%s,DEV=0", id);
      else
         snprintf(settings->arrays.audio_device, sizeof(settings->arrays.audio_device),
               "plughw:%d,0", card);
   }
   else
      settings->arrays.audio_device[0] = '\0';
   command_event(CMD_EVENT_AUDIO_REINIT, NULL);
}

static size_t setting_get_string_representation_uint_rf35h_sleep_minutes(
      rarch_setting_t *setting, char *s, size_t len)
{
   if (!setting)
      return 0;
   if (*setting->value.target.unsigned_integer == 0)
      return strlcpy(s, msg_hash_to_str(MENU_ENUM_LABEL_VALUE_OFF), len);
   return snprintf(s, len, "%u min", *setting->value.target.unsigned_integer);
}

static size_t setting_get_string_representation_uint_rf35h_brightness(
      rarch_setting_t *setting, char *s, size_t len)
{
   if (!setting)
      return 0;
   return snprintf(s, len, "%u%%", *setting->value.target.unsigned_integer);
}
#endif
'''
SETTINGS_BLOCK = r'''#if defined(HAVE_LAKKA)
      case SETTINGS_LIST_RF35H:
         {
            START_GROUP(list, list_info, &group_info,
                  msg_hash_to_str(MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS),
                  parent_group);
            /* Come le liste native dello stesso tipo (VIDEO, AUDIO, DRIVERS):
             * senza questo il gruppo creato da START_GROUP resta senza
             * enum_idx e non e' rintracciabile con menu_setting_find_enum().
             * Lo fanno 31 delle 56 liste di RetroArch. */
            MENU_SETTINGS_LIST_CURRENT_ADD_ENUM_IDX_PTR(list, list_info,
                  MENU_ENUM_LABEL_RF35H_SETTINGS);

            parent_group = msg_hash_to_str(MENU_ENUM_LABEL_SETTINGS);

            START_SUB_GROUP(list, list_info,
                  msg_hash_to_str(MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS),
                  &group_info, &subgroup_info, parent_group);

            CONFIG_UINT(
                  list, list_info,
                  &settings->uints.rf35h_sleep_minutes,
                  MENU_ENUM_LABEL_RF35H_SLEEP_MINUTES,
                  MENU_ENUM_LABEL_VALUE_RF35H_SLEEP_MINUTES,
                  DEFAULT_RF35H_SLEEP_MINUTES,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            /* _special, non setting_action_ok_uint: la tendina "semplice" ricava
             * il valore come indice+offset e da' per scontato passo 1. Con
             * 5..100 a passo 5, "100" e' la voce 19 -> 19%. La _special legge il
             * numero dal testo della voce (atoi), come menu_screensaver_timeout. */
            (*list)[list_info->index - 1].action_ok = &setting_action_ok_uint_special;
            (*list)[list_info->index - 1].get_string_representation =
                  &setting_get_string_representation_uint_rf35h_sleep_minutes;
            (*list)[list_info->index - 1].change_handler = rf35h_sleep_minutes_change_handler;
            menu_settings_list_current_add_range(list, list_info, 0, 60, 5, true, true);

            CONFIG_UINT(
                  list, list_info,
                  &settings->uints.rf35h_brightness,
                  MENU_ENUM_LABEL_RF35H_BRIGHTNESS,
                  MENU_ENUM_LABEL_VALUE_RF35H_BRIGHTNESS,
                  DEFAULT_RF35H_BRIGHTNESS,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok = &setting_action_ok_uint_special;
            (*list)[list_info->index - 1].get_string_representation =
                  &setting_get_string_representation_uint_rf35h_brightness;
            (*list)[list_info->index - 1].change_handler = rf35h_brightness_change_handler;
            menu_settings_list_current_add_range(list, list_info, 5, 100, 5, true, true);

            /* devaOS RF35H: config_string_options() marca i values con
             * SD_FREE_FLAG_VALUES e setting_string_setting_options() ne
             * conserva il puntatore: all'uscita menu_setting_free() li passa
             * a free(). Vanno quindi allocati, come fanno i chiamanti
             * originali (config_get_*_options). Una costante qui causava
             * "free(): invalid pointer" e SIGABRT a ogni uscita di RetroArch. */
            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_joyled,
                  sizeof(settings->arrays.rf35h_joyled),
                  MENU_ENUM_LABEL_RF35H_JOYLED,
                  MENU_ENUM_LABEL_VALUE_RF35H_JOYLED,
                  DEFAULT_RF35H_JOYLED,
                  strdup(RF35H_JOYLED_MODES),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_joyled_change_handler;

            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_statusled,
                  sizeof(settings->arrays.rf35h_statusled),
                  MENU_ENUM_LABEL_RF35H_STATUSLED,
                  MENU_ENUM_LABEL_VALUE_RF35H_STATUSLED,
                  DEFAULT_RF35H_STATUSLED,
                  strdup(RF35H_STATUSLED_MODES),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_statusled_change_handler;

            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_ledspeed,
                  sizeof(settings->arrays.rf35h_ledspeed),
                  MENU_ENUM_LABEL_RF35H_LEDSPEED,
                  MENU_ENUM_LABEL_VALUE_RF35H_LEDSPEED,
                  DEFAULT_RF35H_LEDSPEED,
                  strdup(RF35H_LED_SPEEDS),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_ledspeed_change_handler;

            CONFIG_BOOL(
                  list, list_info,
                  &settings->bools.rf35h_zram,
                  MENU_ENUM_LABEL_RF35H_ZRAM,
                  MENU_ENUM_LABEL_VALUE_RF35H_ZRAM,
                  DEFAULT_RF35H_ZRAM,
                  MENU_ENUM_LABEL_VALUE_OFF,
                  MENU_ENUM_LABEL_VALUE_ON,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler,
                  SD_FLAG_NONE);
            (*list)[list_info->index - 1].change_handler = rf35h_zram_change_handler;

            CONFIG_UINT(
                  list, list_info,
                  &settings->uints.rf35h_speaker_volume,
                  MENU_ENUM_LABEL_RF35H_SPEAKER_VOLUME,
                  MENU_ENUM_LABEL_VALUE_RF35H_SPEAKER_VOLUME,
                  DEFAULT_RF35H_SPEAKER_VOLUME,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok = &setting_action_ok_uint_special;
            (*list)[list_info->index - 1].get_string_representation =
                  &setting_get_string_representation_uint_rf35h_speaker_volume;
            (*list)[list_info->index - 1].change_handler = rf35h_speaker_volume_change_handler;
            menu_settings_list_current_add_range(list, list_info, 0, 100, 4, true, true);

            CONFIG_BOOL(
                  list, list_info,
                  &settings->bools.rf35h_rumble,
                  MENU_ENUM_LABEL_RF35H_RUMBLE,
                  MENU_ENUM_LABEL_VALUE_RF35H_RUMBLE,
                  DEFAULT_RF35H_RUMBLE,
                  MENU_ENUM_LABEL_VALUE_OFF,
                  MENU_ENUM_LABEL_VALUE_ON,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler,
                  SD_FLAG_NONE);
            (*list)[list_info->index - 1].change_handler = rf35h_rumble_change_handler;

            CONFIG_BOOL(
                  list, list_info,
                  &settings->bools.rf35h_ntp,
                  MENU_ENUM_LABEL_RF35H_NTP,
                  MENU_ENUM_LABEL_VALUE_RF35H_NTP,
                  DEFAULT_RF35H_NTP,
                  MENU_ENUM_LABEL_VALUE_OFF,
                  MENU_ENUM_LABEL_VALUE_ON,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler,
                  SD_FLAG_NONE);
            (*list)[list_info->index - 1].change_handler = rf35h_ntp_change_handler;
            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_ntp_server,
                  sizeof(settings->arrays.rf35h_ntp_server),
                  MENU_ENUM_LABEL_RF35H_NTP_SERVER,
                  MENU_ENUM_LABEL_VALUE_RF35H_NTP_SERVER,
                  DEFAULT_RF35H_NTP_SERVER,
                  strdup(RF35H_NTP_SERVERS),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_ntp_server_change_handler;

            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_usb_mode,
                  sizeof(settings->arrays.rf35h_usb_mode),
                  MENU_ENUM_LABEL_RF35H_USB_MODE,
                  MENU_ENUM_LABEL_VALUE_RF35H_USB_MODE,
                  DEFAULT_RF35H_USB_MODE,
                  strdup(RF35H_USB_MODES),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_usb_mode_change_handler;

            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_audio_out,
                  sizeof(settings->arrays.rf35h_audio_out),
                  MENU_ENUM_LABEL_RF35H_AUDIO_OUT,
                  MENU_ENUM_LABEL_VALUE_RF35H_AUDIO_OUT,
                  DEFAULT_RF35H_AUDIO_OUT,
                  strdup(RF35H_AUDIO_OUTS),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok      = setting_action_ok_uint;
            (*list)[list_info->index - 1].change_handler = rf35h_audio_out_change_handler;

            /* Scraper: un'azione (action_ok in menu_cbs_ok.c legge il bool e la
             * regione per comporre la riga di comando) e due impostazioni. */
            CONFIG_ACTION(
                  list, list_info,
                  MENU_ENUM_LABEL_RF35H_SCRAPE,
                  MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE,
                  &group_info,
                  &subgroup_info,
                  parent_group);
            CONFIG_BOOL(
                  list, list_info,
                  &settings->bools.rf35h_scrape_missing,
                  MENU_ENUM_LABEL_RF35H_SCRAPE_MISSING,
                  MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE_MISSING,
                  DEFAULT_RF35H_SCRAPE_MISSING,
                  MENU_ENUM_LABEL_VALUE_OFF,
                  MENU_ENUM_LABEL_VALUE_ON,
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler,
                  SD_FLAG_NONE);
            CONFIG_STRING_OPTIONS(
                  list, list_info,
                  settings->arrays.rf35h_scrape_region,
                  sizeof(settings->arrays.rf35h_scrape_region),
                  MENU_ENUM_LABEL_RF35H_SCRAPE_REGION,
                  MENU_ENUM_LABEL_VALUE_RF35H_SCRAPE_REGION,
                  DEFAULT_RF35H_SCRAPE_REGION,
                  strdup(RF35H_SCRAPE_REGIONS),
                  &group_info,
                  &subgroup_info,
                  parent_group,
                  general_write_handler,
                  general_read_handler);
            (*list)[list_info->index - 1].action_ok = setting_action_ok_uint;

            /* System Update: un'azione (action_ok_rf35h_update in menu_cbs_ok.c) */
            CONFIG_ACTION(
                  list, list_info,
                  MENU_ENUM_LABEL_RF35H_UPDATE,
                  MENU_ENUM_LABEL_VALUE_RF35H_UPDATE,
                  &group_info,
                  &subgroup_info,
                  parent_group);

            END_SUB_GROUP(list, list_info, parent_group);
            END_GROUP(list, list_info, parent_group);
         }
         break;
#endif
'''
edit("menu/menu_setting.c", [
    # Wi-Fi Access Point: il toggle OFF di Lakka fa "connmanctl tether wifi off"
    # solo se connman riporta Tethering=True, e non tocca mai il flag di boot
    # localap.conf: al riavvio l'hotspot torna. Con wpa_supplicant al posto di
    # iwd lo stato e lo smontaggio dell'AP non sono affidabili. rf35h-ap spegne
    # con verifica e ripiego e mette il flag da parte. Solo se lo script c'e'.
    ("static void localap_enable_toggle_change_handler(rarch_setting_t *setting)\n"
     "{\n"
     "   driver_wifi_tether_start_stop(*setting->value.target.boolean,\n",
     "static void localap_enable_toggle_change_handler(rarch_setting_t *setting)\n"
     "{\n"
     "   if (path_is_valid(\"/usr/bin/rf35h-ap\"))\n"
     "   {\n"
     "      /* devaOS RF35H: la password dell'access point e' casuale per\n"
     "       * dispositivo (quella di default di Lakka, \"RetroArch\", e'\n"
     "       * pubblica, e dietro c'e' SSH con root/root). Casuale vuol dire\n"
     "       * che va mostrata: \"prepare\" crea o converte la config in modo\n"
     "       * sincrono, poi la si legge e la si mette a schermo per 10 s. Il\n"
     "       * codice originale lo faceva; chiamare rf35h-ap in background lo\n"
     "       * saltava, e la password restava invisibile. */\n"
     "      if (*setting->value.target.boolean)\n"
     "      {\n"
     "         char name[64] = \"\", pass[64] = \"\", line[128], msg[192];\n"
     "         FILE *f;\n"
     "         if (system(\"/usr/bin/rf35h-ap prepare >/dev/null 2>&1\")) { }\n"
     "         if ((f = fopen(LAKKA_LOCALAP_PATH, \"r\")))\n"
     "         {\n"
     "            while (fgets(line, sizeof(line), f))\n"
     "            {\n"
     "               line[strcspn(line, \"\\r\\n\")] = '\\0';\n"
     "               if (!strncmp(line, \"APNAME=\", 7))\n"
     "                  strlcpy(name, line + 7, sizeof(name));\n"
     "               else if (!strncmp(line, \"PASSWORD=\", 9))\n"
     "                  strlcpy(pass, line + 9, sizeof(pass));\n"
     "            }\n"
     "            fclose(f);\n"
     "         }\n"
     "         if (name[0] && pass[0])\n"
     "         {\n"
     "            snprintf(msg, sizeof(msg), \"Access point %s - password: %s\", name, pass);\n"
     "            runloop_msg_queue_push(msg, strlen(msg), 1, 600, true, NULL,\n"
     "                  MESSAGE_QUEUE_ICON_DEFAULT, MESSAGE_QUEUE_CATEGORY_INFO);\n"
     "         }\n"
     "      }\n"
     "      rf35h_run(\"/usr/bin/rf35h-ap %s >/dev/null 2>&1 &\",\n"
     "            *setting->value.target.boolean ? \"on\" : \"off\");\n"
     "      return;\n"
     "   }\n"
     "   driver_wifi_tether_start_stop(*setting->value.target.boolean,\n"),

    # LA voce nel menu Settings: senza questo CONFIG_ACTION il PARSE_ACTION della
    # displaylist non trova nessun setting per l'enum e non aggiunge niente.
    # E' il pezzo che mancava alla prima build: Bluetooth spariva (la condizione
    # scattava) ma la nostra voce non compariva.
    ("#ifdef HAVE_LAKKA_SWITCH\n         CONFIG_ACTION(\n               list, list_info,\n               MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS,\n               MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n               &group_info,\n               &subgroup_info,\n               parent_group);\n#endif\n",
     "#ifdef HAVE_LAKKA_SWITCH\n         CONFIG_ACTION(\n               list, list_info,\n               MENU_ENUM_LABEL_LAKKA_SWITCH_OPTIONS,\n               MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS,\n               &group_info,\n               &subgroup_info,\n               parent_group);\n#endif\n"
     "#ifdef HAVE_LAKKA\n         CONFIG_ACTION(\n               list, list_info,\n               MENU_ENUM_LABEL_RF35H_SETTINGS,\n               MENU_ENUM_LABEL_VALUE_RF35H_SETTINGS,\n               &group_info,\n               &subgroup_info,\n               parent_group);\n#endif\n"),
    ("   SETTINGS_LIST_LAKKA_SERVICES,\n#ifdef HAVE_LAKKA_SWITCH\n   SETTINGS_LIST_LAKKA_SWITCH_OPTIONS,\n",
     "   SETTINGS_LIST_LAKKA_SERVICES,\n#if defined(HAVE_LAKKA)\n   SETTINGS_LIST_RF35H,\n#endif\n#ifdef HAVE_LAKKA_SWITCH\n   SETTINGS_LIST_LAKKA_SWITCH_OPTIONS,\n"),
    ("      SETTINGS_LIST_LAKKA_SERVICES,\n#ifdef HAVE_LAKKA_SWITCH\n      SETTINGS_LIST_LAKKA_SWITCH_OPTIONS,\n#endif\n",
     "      SETTINGS_LIST_LAKKA_SERVICES,\n#if defined(HAVE_LAKKA)\n      SETTINGS_LIST_RF35H,\n#endif\n#ifdef HAVE_LAKKA_SWITCH\n      SETTINGS_LIST_LAKKA_SWITCH_OPTIONS,\n#endif\n"),
    ("static void ssh_enable_toggle_change_handler(rarch_setting_t *setting)\n",
     HANDLERS + "\nstatic void ssh_enable_toggle_change_handler(rarch_setting_t *setting)\n"),
    # ATTENZIONE all'ancora: il case dello Switch sta DENTRO #ifdef HAVE_LAKKA_SWITCH.
    # Ancorarsi al "case" lo metteva dentro quell'ifdef: blocco compilato via,
    # voce presente ma sottomenu vuoto. Si ancora sull'#ifdef e si mette PRIMA.
    ("#ifdef HAVE_LAKKA_SWITCH\n      case SETTINGS_LIST_LAKKA_SWITCH_OPTIONS:\n         {\n            START_GROUP(list, list_info, &group_info,\n                  msg_hash_to_str(MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS),\n",
     SETTINGS_BLOCK + "#ifdef HAVE_LAKKA_SWITCH\n      case SETTINGS_LIST_LAKKA_SWITCH_OPTIONS:\n         {\n            START_GROUP(list, list_info, &group_info,\n                  msg_hash_to_str(MENU_ENUM_LABEL_VALUE_LAKKA_SWITCH_OPTIONS),\n"),
])

print("tutte le ancore trovate, sorgente modificato")
