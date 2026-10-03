/* rf35h-rumble - fa vibrare il pad interno via evdev, senza RetroArch.
 *
 *   rf35h-rumble            500 ms a piena forza
 *   rf35h-rumble 1500       durata in ms
 *
 * Cerca il device che si chiama retrogame_joypad, controlla che dichiari
 * EV_FF / FF_RUMBLE (se no, il driver non ha registrato il motore: e' il
 * primo posto dove guardare), carica un effetto e lo suona. E' la stessa
 * strada che RetroArch (udev_joypad) usa quando un core chiede il rumble.
 */
#include <dirent.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/input.h>

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define test_bit(bit, arr) ((arr[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

static int find_pad(const char *want)
{
	DIR *d = opendir("/dev/input");
	struct dirent *e;
	if (!d) return -1;
	while ((e = readdir(d))) {
		char path[300], name[256] = {0};
		if (strncmp(e->d_name, "event", 5)) continue;
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		int fd = open(path, O_RDWR);
		if (fd < 0) continue;
		ioctl(fd, EVIOCGNAME(sizeof(name)), name);
		if (!strcmp(name, want)) { closedir(d); return fd; }
		close(fd);
	}
	closedir(d);
	return -1;
}

int main(int argc, char **argv)
{
	int ms = argc > 1 ? atoi(argv[1]) : 500;
	/* fx.replay.length e' un __u16 (max 65535 ms) e l'attesa sotto e'
	 * (ms + 200) * 1000 in int: senza limiti un argomento sbagliato faceva
	 * danni. -5 diventava 65531 ms di vibrazione (oltre un minuto); 3000000
	 * traboccava e lasciava il programma appeso per quasi un'ora. 10 s bastano
	 * per qualunque prova, e stanno lontani da entrambi i limiti. */
	if (ms < 1 || ms > 10000) {
		fprintf(stderr, "rf35h-rumble: durata %d ms fuori intervallo (1-10000)\n", ms);
		return 1;
	}
	int fd = find_pad("retrogame_joypad");
	if (fd < 0) { fprintf(stderr, "rf35h-rumble: retrogame_joypad non trovato in /dev/input\n"); return 1; }

	unsigned long evbits[NBITS(EV_MAX)] = {0}, ffbits[NBITS(FF_MAX)] = {0};
	ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits);
	if (!test_bit(EV_FF, evbits)) {
		fprintf(stderr, "rf35h-rumble: il pad NON dichiara EV_FF: il driver non ha registrato il motore\n");
		return 2;
	}
	ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ffbits)), ffbits);
	printf("EV_FF: si  FF_RUMBLE: %s  FF_PERIODIC: %s\n",
	       test_bit(FF_RUMBLE, ffbits) ? "si" : "no", test_bit(FF_PERIODIC, ffbits) ? "si" : "no");

	struct ff_effect fx;
	memset(&fx, 0, sizeof(fx));
	fx.type = FF_RUMBLE;
	fx.id = -1;
	fx.u.rumble.strong_magnitude = 0xffff;
	fx.u.rumble.weak_magnitude   = 0xffff;
	fx.replay.length = ms;
	if (ioctl(fd, EVIOCSFF, &fx) < 0) { perror("EVIOCSFF"); return 3; }

	struct input_event play = { .type = EV_FF, .code = fx.id, .value = 1 };
	if (write(fd, &play, sizeof(play)) != sizeof(play)) { perror("write"); return 3; }
	printf("vibro per %d ms...\n", ms);
	usleep((ms + 200) * 1000);
	play.value = 0;
	if (write(fd, &play, sizeof(play)) != sizeof(play)) { /* ignoro */ }
	ioctl(fd, EVIOCRMFF, fx.id);
	close(fd);
	printf("fatto. Se non ha vibrato con FF_RUMBLE = si, il problema e' fra GPIO3_A6 e il motore.\n");
	return 0;
}
