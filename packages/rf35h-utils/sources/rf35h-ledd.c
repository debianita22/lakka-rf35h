/* rf35h-ledd - effetti per gli stick e i LED di stato che l'hardware da solo
 * non ha.
 *
 * Gli stick li pilota un microcontrollore su /dev/ttyS2 (9600 8N1) con un
 * protocollo a un byte e 17 modi fissi: colori pieni, "flow", respiri. Tutto
 * cio' che va oltre (colore che segue la batteria, ciclo di colori, lampeggio
 * di allarme) si ottiene mandando quei byte in sequenza al momento giusto: e'
 * quello che fa questo demone. I LED di stato (rosso/blu, GPIO) hanno i
 * trigger del kernel (timer, heartbeat, activity) e qui si combinano con lo
 * stato della batteria.
 *
 * Event-driven: inotify su /storage/.config/rf35h per ricaricare i modi
 * appena rf35h-led / rf35h-statusled scrivono i loro file; poll() con timeout
 * = prossimo frame dell'animazione, 5 s se serve solo la batteria, infinito se
 * tutto e' statico (zero risvegli). Non manda mai due volte lo stesso byte,
 * non scrive due volte lo stesso trigger, e sta zitto quando l'MCU e' senza
 * corrente (joyled-power a 0, cioe' durante la sospensione).
 *
 * Modi degli stick gestiti qui:      battery, charging, alert, rainbow, strobe
 * Modi dei LED di stato gestiti qui: battery
 * Tutti gli altri li applicano gli script direttamente; il demone li ignora.
 *
 * Variabili d'ambiente (test): RF35H_STATE_DIR, RF35H_LED_TTY,
 * RF35H_JOYLED_POWER, RF35H_LED_RED, RF35H_LED_BLUE, RF35H_PS_DIR.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* --- byte dell'MCU (tabella di ArkOS4Clone, verificata) ------------------ */
enum { B_OFF = 0x00, B_GREEN = 0x01, B_BLUE = 0x02, B_RED = 0x03, B_CYAN = 0x04,
       B_ORANGE = 0x05, B_PURPLE = 0x06, B_WHITE = 0x07, B_FLOW = 0x08,
       B_BR_GREEN = 0x11, B_BR_BLUE = 0x12, B_BR_RED = 0x13, B_BR_CYAN = 0x14,
       B_BR_ORANGE = 0x15, B_BR_PURPLE = 0x16, B_BR_WHITE = 0x17, B_BREATHING = 0x18 };

static const char *env_or(const char *k, const char *d) { const char *v = getenv(k); return (v && *v) ? v : d; }

static const char *STATE, *TTY, *POWER, *RED, *BLUE, *PSDIR;
static char PATH_LED[512], PATH_STATUS[512], PATH_SPEED[512];

static volatile sig_atomic_t g_stop = 0, g_reload = 0;
static void on_term(int s) { (void)s; g_stop = 1; }
static void on_hup(int s) { (void)s; g_reload = 1; }

/* --- utilita' ----------------------------------------------------------- */
static bool read_line(const char *p, char *out, size_t n) {
	FILE *f = fopen(p, "r");
	if (!f) return false;
	if (!fgets(out, (int)n, f)) { fclose(f); out[0] = 0; return false; }
	fclose(f);
	out[strcspn(out, "\r\n")] = 0;
	return out[0] != 0;
}
static bool write_str(const char *p, const char *s) {
	int fd = open(p, O_WRONLY | O_CLOEXEC);
	if (fd < 0) return false;
	ssize_t n = write(fd, s, strlen(s));
	close(fd);
	return n == (ssize_t)strlen(s);
}
static long long now_ms(void) {
	struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
	return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

/* --- batteria: primo power_supply di tipo Battery ------------------------ */
struct batt { int capacity; enum { DISCHARGING, CHARGING, FULL } status; bool valid; };
static char g_batt_dir[512];
static void find_battery(void) {
	DIR *d = opendir(PSDIR);
	struct dirent *e;
	g_batt_dir[0] = 0;
	if (!d) return;
	while ((e = readdir(d))) {
		char p[600], t[32];
		if (e->d_name[0] == '.') continue;
		snprintf(p, sizeof(p), "%s/%s/type", PSDIR, e->d_name);
		if (read_line(p, t, sizeof(t)) && !strcmp(t, "Battery")) {
			snprintf(g_batt_dir, sizeof(g_batt_dir), "%s/%s", PSDIR, e->d_name);
			break;
		}
	}
	closedir(d);
}
static struct batt read_battery(void) {
	struct batt b = { 100, DISCHARGING, false };
	char p[600], s[32];
	if (!g_batt_dir[0]) find_battery();
	if (!g_batt_dir[0]) return b;
	snprintf(p, sizeof(p), "%s/capacity", g_batt_dir);
	if (read_line(p, s, sizeof(s))) { b.capacity = atoi(s); b.valid = true; }
	snprintf(p, sizeof(p), "%s/status", g_batt_dir);
	if (read_line(p, s, sizeof(s))) {
		if (!strcmp(s, "Charging")) b.status = CHARGING;
		else if (!strcmp(s, "Full")) b.status = FULL;
		else b.status = DISCHARGING;
	}
	return b;
}

/* --- stick: seriale verso l'MCU ------------------------------------------ */
static int g_tty = -1;
static int g_last_byte = -1;
static bool mcu_powered(void) {
	char s[8];
	if (access(POWER, R_OK) != 0) return true;   /* niente GPIO nel DTB: assumo acceso */
	return read_line(POWER, s, sizeof(s)) && atoi(s) != 0;
}
static bool open_tty(void) {
	struct termios t;
	if (g_tty >= 0) return true;
	g_tty = open(TTY, O_WRONLY | O_NOCTTY | O_CLOEXEC | O_APPEND);   /* APPEND: ininfluente su un tty, rende leggibile un file di test */
	if (g_tty < 0) return false;
	if (isatty(g_tty) && tcgetattr(g_tty, &t) == 0) {
		cfmakeraw(&t);                 /* niente XON/XOFF: 0x11 e 0x13 sono comandi */
		cfsetispeed(&t, B9600); cfsetospeed(&t, B9600);
		t.c_cflag |= CLOCAL | CREAD;
		tcsetattr(g_tty, TCSANOW, &t);
	}
	return true;
}
static void send_byte(int b) {
	unsigned char c = (unsigned char)b;
	if (b == g_last_byte) return;
	if (!mcu_powered()) { g_last_byte = -1; return; }   /* sospeso: al risveglio si rimanda */
	if (!open_tty()) return;
	if (write(g_tty, &c, 1) == 1) g_last_byte = b;
	else { close(g_tty); g_tty = -1; g_last_byte = -1; }
}

/* --- LED di stato ------------------------------------------------------- */
static char g_last_red[48], g_last_blue[48];
/* spec: "off" | "on" | "timer:ON:OFF" | "trigger:NAME" */
static void set_led(const char *dir, const char *spec, char *last) {
	char p[600], v[32];
	if (!strcmp(spec, last)) return;
	if (!strncmp(spec, "trigger:", 8)) {
		snprintf(p, sizeof(p), "%s/trigger", dir); write_str(p, spec + 8);
	} else if (!strncmp(spec, "timer:", 6)) {
		int on = 500, off = 500;
		sscanf(spec + 6, "%d:%d", &on, &off);
		snprintf(p, sizeof(p), "%s/trigger", dir); write_str(p, "timer");
		snprintf(p, sizeof(p), "%s/delay_on", dir);  snprintf(v, sizeof(v), "%d", on);  write_str(p, v);
		snprintf(p, sizeof(p), "%s/delay_off", dir); snprintf(v, sizeof(v), "%d", off); write_str(p, v);
	} else {
		snprintf(p, sizeof(p), "%s/trigger", dir); write_str(p, "none");
		snprintf(p, sizeof(p), "%s/brightness", dir); write_str(p, !strcmp(spec, "on") ? "1" : "0");
	}
	snprintf(last, 48, "%s", spec);
}

/* --- modi ---------------------------------------------------------------- */
/* I 17 modi fissi dell'MCU. Li applica il demone, non lo script: con due
 * scrittori sulla stessa seriale un frame gia' calcolato dal demone poteva
 * arrivare dopo il byte dello script, e il modo scelto non si vedeva - o
 * "off" non spegneva. Un solo scrittore, nessuna corsa. */
static const struct { const char *name; int byte; } STATIC_JOY[] = {
	{ "off", B_OFF }, { "green", B_GREEN }, { "blue", B_BLUE }, { "red", B_RED },
	{ "cyan", B_CYAN }, { "orange", B_ORANGE }, { "purple", B_PURPLE }, { "white", B_WHITE },
	{ "flow", B_FLOW }, { "breathing-green", B_BR_GREEN }, { "breathing-blue", B_BR_BLUE },
	{ "breathing-red", B_BR_RED }, { "breathing-cyan", B_BR_CYAN },
	{ "breathing-orange", B_BR_ORANGE }, { "breathing-purple", B_BR_PURPLE },
	{ "breathing-white", B_BR_WHITE }, { "breathing", B_BREATHING },
};
static int static_joy_byte(const char *m) {
	for (size_t i = 0; i < sizeof(STATIC_JOY) / sizeof(STATIC_JOY[0]); i++)
		if (!strcmp(m, STATIC_JOY[i].name)) return STATIC_JOY[i].byte;
	return -1;
}

enum joymode { J_STATIC, J_BATTERY, J_CHARGING, J_ALERT, J_RAINBOW, J_STROBE };
enum stmode  { S_STATIC, S_BATTERY };
/* Modi statici dei LED di stato, con la stessa regola del singolo scrittore.
 * "charge" e i due trigger del kernel lasciano il rosso all'indicatore di
 * carica; gli altri pilotano brightness a mano. */
static void apply_static_status(const char *m, const char *red, const char *blue,
                                char *lr, char *lb) {
	const char *CH = "trigger:battery-charging-or-full";
	if (!strcmp(m, "charge"))         { set_led(red, CH, lr);   set_led(blue, "off", lb); }
	else if (!strcmp(m, "heartbeat")) { set_led(red, CH, lr);   set_led(blue, "trigger:heartbeat", lb); }
	else if (!strcmp(m, "activity"))  { set_led(red, CH, lr);   set_led(blue, "trigger:activity", lb); }
	else if (!strcmp(m, "red"))       { set_led(red, "on", lr); set_led(blue, "off", lb); }
	else if (!strcmp(m, "blue"))      { set_led(red, "off", lr);set_led(blue, "on", lb); }
	else if (!strcmp(m, "both"))      { set_led(red, "on", lr); set_led(blue, "on", lb); }
	else if (!strcmp(m, "off"))       { set_led(red, "off", lr);set_led(blue, "off", lb); }
}
static enum joymode joy_from(const char *m) {
	if (!strcmp(m, "battery"))  return J_BATTERY;
	if (!strcmp(m, "charging")) return J_CHARGING;
	if (!strcmp(m, "alert"))    return J_ALERT;
	if (!strcmp(m, "rainbow"))  return J_RAINBOW;
	if (!strcmp(m, "strobe"))   return J_STROBE;
	return J_STATIC;
}
static int period_ms(const char *speed) {
	if (!strcmp(speed, "slow")) return 3000;
	if (!strcmp(speed, "fast")) return 700;
	return 1500;
}

static int joy_byte_for_battery(const struct batt *b, enum joymode m, int frame) {
	int base;
	switch (m) {
	case J_BATTERY:
		base = b->capacity >= 50 ? B_GREEN : b->capacity >= 20 ? B_ORANGE : B_RED;
		if (b->status == FULL)     return B_WHITE;
		if (b->status == CHARGING) return base == B_GREEN ? B_BR_GREEN : base == B_ORANGE ? B_BR_ORANGE : B_BR_RED;
		return base;
	case J_CHARGING:
		if (b->status == FULL)     return B_GREEN;
		if (b->status == CHARGING) return B_BR_GREEN;
		return B_OFF;
	case J_ALERT:
		if (b->status == DISCHARGING && b->valid && b->capacity < 15) return (frame & 1) ? B_OFF : B_RED;
		return B_OFF;
	default: return B_OFF;
	}
}

int main(void) {
	STATE = env_or("RF35H_STATE_DIR", "/storage/.config/rf35h");
	TTY   = env_or("RF35H_LED_TTY", "/dev/ttyS2");
	POWER = env_or("RF35H_JOYLED_POWER", "/sys/class/leds/joyled-power/brightness");
	RED   = env_or("RF35H_LED_RED", "/sys/class/leds/red");
	BLUE  = env_or("RF35H_LED_BLUE", "/sys/class/leds/blue");
	PSDIR = env_or("RF35H_PS_DIR", "/sys/class/power_supply");
	snprintf(PATH_LED, sizeof(PATH_LED), "%s/led", STATE);
	snprintf(PATH_STATUS, sizeof(PATH_STATUS), "%s/statusled", STATE);
	snprintf(PATH_SPEED, sizeof(PATH_SPEED), "%s/ledspeed", STATE);
	mkdir(STATE, 0755);

	signal(SIGTERM, on_term); signal(SIGINT, on_term); signal(SIGHUP, on_hup);

	int ino = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
	/* Senza watch, nei modi statici il demone aspetta all'infinito (wait = -1)
	 * e i cambi di colore dal menu non arrivano piu': rf35h-led scrive il file
	 * ma non manda HUP. Con un solo watch inotify praticamente non fallisce,
	 * quindi niente ripiego a polling - rileggere lo stato di continuo
	 * reinvierebbe i byte al microcontrollore - ma il guasto non deve restare
	 * silenzioso: lo si scrive nel journal, dove andrebbe cercato. Un
	 * "systemctl reload" (HUP) forza comunque la rilettura. */
	if (ino < 0)
		fprintf(stderr, "rf35h-ledd: inotify_init1 fallito (%s): i cambi dal menu richiedono un riavvio del servizio\n", strerror(errno));
	else if (inotify_add_watch(ino, STATE, IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_ATTRIB) < 0)
		fprintf(stderr, "rf35h-ledd: watch su %s fallito (%s): i cambi dal menu richiedono un riavvio del servizio\n", STATE, strerror(errno));

	static const int rainbow[] = { B_GREEN, B_CYAN, B_BLUE, B_PURPLE, B_RED, B_ORANGE, B_WHITE };
	enum joymode jm = J_STATIC; enum stmode sm = S_STATIC;
	int period = 1500, frame = -1;   /* -1: il primo tick porta a 0, cosi' il rainbow parte dal primo colore */
	long long next_anim = 0, next_batt = 0;
	struct batt b = { 100, DISCHARGING, false };
	bool reload = true;
	g_last_red[0] = g_last_blue[0] = 0;

	while (!g_stop) {
		if (reload || g_reload) {
			char joy[64], stat[64], sp[64];
			/* variabili distinte: riusare lo stesso buffer per i due modi
			 * faceva arrivare a static_joy_byte() il nome dei LED di stato. */
			bool has_joy  = read_line(PATH_LED, joy, sizeof(joy));
			bool has_stat = read_line(PATH_STATUS, stat, sizeof(stat));
			jm = has_joy ? joy_from(joy) : J_STATIC;
			sm = (has_stat && !strcmp(stat, "battery")) ? S_BATTERY : S_STATIC;
			period = period_ms(read_line(PATH_SPEED, sp, sizeof(sp)) ? sp : "normal");
			g_last_byte = -1; g_last_red[0] = g_last_blue[0] = 0;
			next_anim = next_batt = 0; frame = -1;
			/* Modi statici: applicati una volta qui e poi basta. Li applica il
			 * demone e non lo script, cosi' sulla seriale e sui LED scrive uno
			 * solo: con due, un frame gia' calcolato arrivava dopo il byte
			 * dello script e il modo scelto non si vedeva. */
			if (jm == J_STATIC && has_joy) {
				int b = static_joy_byte(joy);
				if (b >= 0) send_byte(b);
			}
			if (sm == S_STATIC && has_stat)
				apply_static_status(stat, RED, BLUE, g_last_red, g_last_blue);
			reload = false; g_reload = 0;
		}
		const long long t = now_ms();
		const bool needs_batt = (jm == J_BATTERY || jm == J_CHARGING || jm == J_ALERT || sm == S_BATTERY);
		const bool anim       = (jm == J_RAINBOW || jm == J_STROBE || jm == J_ALERT);

		if (needs_batt && t >= next_batt) { b = read_battery(); next_batt = t + 5000; }
		if (anim && t >= next_anim) { frame++; next_anim = t + (jm == J_STROBE ? period / 4 : jm == J_ALERT ? 500 : period); }

		switch (jm) {
		case J_RAINBOW:  send_byte(rainbow[frame % 7]); break;
		case J_STROBE:   send_byte((frame & 1) ? B_RED : B_BLUE); break;
		case J_BATTERY: case J_CHARGING: case J_ALERT: send_byte(joy_byte_for_battery(&b, jm, frame)); break;
		default: break;
		}
		if (sm == S_BATTERY) {
			/* rosso: sotto il 20% acceso, sotto il 10% lampeggia; blu: acceso in carica */
			if (b.status == DISCHARGING && b.valid && b.capacity < 10) set_led(RED, "timer:250:250", g_last_red);
			else if (b.status == DISCHARGING && b.valid && b.capacity < 20) set_led(RED, "on", g_last_red);
			else set_led(RED, "off", g_last_red);
			set_led(BLUE, b.status == CHARGING ? "on" : "off", g_last_blue);
		}

		/* dormo fino al prossimo evento che conta */
		long long wait = -1;
		if (anim)       wait = next_anim - now_ms();
		if (needs_batt) { long long w = next_batt - now_ms(); if (wait < 0 || w < wait) wait = w; }
		if (wait >= 0 && wait < 20) wait = 20;
		struct pollfd pf = { ino, POLLIN, 0 };
		int r = poll(&pf, ino >= 0 ? 1 : 0, wait < 0 ? -1 : (int)wait);
		if (r > 0 && (pf.revents & POLLIN)) {
			char buf[4096];
			ssize_t n = read(ino, buf, sizeof(buf));
			for (ssize_t off = 0; n > 0 && off < n; ) {
				struct inotify_event *ev = (struct inotify_event *)(buf + off);
				if (ev->len && (!strcmp(ev->name, "led") || !strcmp(ev->name, "statusled") || !strcmp(ev->name, "ledspeed"))) reload = true;
				off += sizeof(*ev) + ev->len;
			}
		}
	}
	if (g_tty >= 0) close(g_tty);
	if (ino >= 0) close(ino);
	return 0;
}
