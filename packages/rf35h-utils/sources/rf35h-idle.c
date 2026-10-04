/* rf35h-idle - sospende il device dopo N minuti senza input.
 *
 * Lakka non ha niente per questo: swayidle non e' impacchettato, IdleAction
 * di logind vuole sessioni che riportino l'idle e RetroArch gira come
 * servizio senza sessione, e RetroArch non ha un "comando su idle". Questo fa
 * l'unica cosa sensata su un portatile: apre tutti gli evdev, aspetta con
 * poll(), e se per N minuti non arriva nessun evento chiama systemctl suspend.
 *
 * Non fa grab: RetroArch continua a ricevere tutto. Riapre i device ogni tanto
 * perche' un pad USB collegato dopo l'avvio deve contare come input.
 *
 *   rf35h-idle [minuti]        default: RF35H_IDLE_MINUTES o 10; 0 = disattivo
 *
 * Per i test: RF35H_IDLE_CMD sostituisce "systemctl suspend",
 * RF35H_IDLE_DIR sostituisce /dev/input, RF35H_UNITS_DIR /run/systemd/units
 * e RF35H_GADGET_UDC il file UDC del gadget di rf35h-usb.
 */
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <linux/input.h>

#define MAX_DEVS 32
#define RESCAN_S 30

static int fds[MAX_DEVS];
static int nfds;

static void close_all(void)
{
	for (int i = 0; i < nfds; i++) close(fds[i]);
	nfds = 0;
}

static void open_all(const char *dir)
{
	close_all();
	DIR *d = opendir(dir);
	if (!d) return;
	struct dirent *e;
	while ((e = readdir(d)) && nfds < MAX_DEVS) {
		if (strncmp(e->d_name, "event", 5) != 0) continue;
		char path[512];
		snprintf(path, sizeof(path), "%s/%s", dir, e->d_name);
		int fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd >= 0) fds[nfds++] = fd;
	}
	closedir(d);
}

static long now_s(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec;
}

/* Lavori che non danno input ma non vanno interrotti: System Update che
 * scarica, lo scraper delle copertine, la porta USB-C in "transfer" (il PC
 * legge e scrive via rete). Sospendere li' rompeva il download, lo scraping o
 * la copia. Se uno e' in corso la sospensione si rimanda; quella a mano (tasto
 * power, via logind) non passa di qui.
 *
 * Una unit e' attiva finche' esiste il suo link "invocation:" in
 * /run/systemd/units. E' un symlink verso l'invocation id, che come file non
 * esiste: lstat, non stat o access. "transfer" e' il gadget di rf35h-usb legato
 * a un UDC, cioe' il suo file UDC non vuoto. */
static const char *busy(void)
{
	static const char *const units[] = { "rf35h-update.service", "rf35h-scrape.service" };
	const char *dir = getenv("RF35H_UNITS_DIR");
	const char *udc = getenv("RF35H_GADGET_UDC");
	char path[512];
	struct stat st;

	if (!dir) dir = "/run/systemd/units";
	if (!udc) udc = "/sys/kernel/config/usb_gadget/rf35h/UDC";
	for (size_t i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
		snprintf(path, sizeof(path), "%s/invocation:%s", dir, units[i]);
		if (lstat(path, &st) == 0) return units[i];
	}
	FILE *f = fopen(udc, "r");
	if (f) {
		int c = fgetc(f);
		fclose(f);
		if (c != EOF && c != '\n') return "porta USB-C in transfer";
	}
	return NULL;
}

int main(int argc, char **argv)
{
	const char *dir = getenv("RF35H_IDLE_DIR");
	if (!dir) dir = "/dev/input";
	const char *cmd = getenv("RF35H_IDLE_CMD");
	if (!cmd) cmd = "systemctl suspend";

	long minutes = 10;
	const char *env = getenv("RF35H_IDLE_MINUTES");
	if (argc > 1) minutes = atol(argv[1]);
	else if (env) minutes = atol(env);
	if (minutes <= 0) {
		fprintf(stderr, "rf35h-idle: disattivato (minuti = %ld)\n", minutes);
		return 0;
	}
	long idle_s = minutes * 60;

	open_all(dir);
	long last_input = now_s(), last_scan = last_input;
	fprintf(stderr, "rf35h-idle: %d device, sospendo dopo %ld min senza input\n", nfds, minutes);

	for (;;) {
		struct pollfd p[MAX_DEVS];
		for (int i = 0; i < nfds; i++) { p[i].fd = fds[i]; p[i].events = POLLIN; p[i].revents = 0; }

		long now = now_s();
		long wait = idle_s - (now - last_input);
		if (wait > RESCAN_S) wait = RESCAN_S;
		if (wait < 0) wait = 0;

		int r = poll(p, nfds, (int)(wait * 1000));
		now = now_s();

		if (r > 0) {
			struct input_event ev[16];
			for (int i = 0; i < nfds; i++) {
				/* Prima i dati, poi l'eventuale chiusura: il kernel puo'
				 * segnalare POLLIN e POLLHUP nello stesso poll (un pad USB
				 * che manda gli ultimi eventi e sparisce, o un cavo ballerino
				 * che si riaggancia di continuo). Trattando prima il POLLHUP
				 * quegli eventi venivano buttati e il timer non si azzerava:
				 * con un pad cosi' la console si sospendeva mentre ci giocavi.
				 * Visto eseguendo il demone contro una FIFO. */
				if (p[i].revents & POLLIN) {
					/* svuoto, e ogni evento reale (non SYN) e' attivita' */
					ssize_t n;
					while ((n = read(fds[i], ev, sizeof(ev))) > 0)
						for (int k = 0; k < (int)(n / sizeof(ev[0])); k++)
							if (ev[k].type != EV_SYN) last_input = now;
				}
				/* device sparito (pad USB staccato): senza questo il suo fd
				 * torna POLLHUP a ogni poll e il loop gira a vuoto fino alla
				 * riscansione. Si riscansiona subito. */
				if (p[i].revents & (POLLHUP | POLLERR | POLLNVAL)) { last_scan = 0; continue; }
			}
		}

		if (now - last_input >= idle_s) {
			const char *why = busy();
			if (why) {
				/* rimandata di un intervallo intero, come se ci fosse stato input */
				fprintf(stderr, "rf35h-idle: %ld min senza input, sospensione rimandata (%s)\n", minutes, why);
				last_input = now;
			} else {
				fprintf(stderr, "rf35h-idle: %ld min senza input, sospendo\n", minutes);
				if (system(cmd)) { /* ignore */ }
				/* al risveglio ripartiamo da zero: il tasto power stesso e' un evento,
				 * ma per sicurezza il conto ricomincia adesso */
				last_input = now_s();
				last_scan = 0;   /* i device possono essere cambiati */
			}
		}

		if (now - last_scan >= RESCAN_S) {
			open_all(dir);
			last_scan = now;
		}
	}
}
