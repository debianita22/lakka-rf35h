/* rf35h-tty - scrive byte grezzi su una seriale a 9600 8N1.
 *
 *   rf35h-tty [-b baud] /dev/ttyS2 0x11 0x15 ...   (baud: qualsiasi intero)
 *
 * -b: velocita' diversa da 9600, per provare sul filo quando il clock della
 *     UART non e' quello che il kernel crede (uart2 su px30 e' a 24 MHz,
 *     uart1 a 100 MHz: se il loader ha lasciato uart2 altrove, i 9600 escono
 *     a un'altra frequenza e l'MCU vede spazzatura).
 *
 * Esiste perche' il busybox di Lakka non ha stty ne' microcom, e senza
 * termios in raw mode il tty fa quello che fa un tty: 0x11 e 0x13 sono
 * XON/XOFF e con IXON spariscono, 0x0a/0x0d vengono tradotti, e in modo
 * canonico niente parte finche' non arriva un newline. Il microcontrollore
 * degli stick dell'RF35H vuole un byte solo, cosi' com'e'.
 *
 * Nessuna dipendenza oltre la libc. Esce 0 se ha scritto tutto.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
/* Niente <termios.h>: ridefinirebbe struct termios. Da <asm/termbits.h>
 * arrivano struct termios2 e BOTHER, che permettono un baud qualsiasi. */
#include <asm/termbits.h>

int main(int argc, char **argv)
{
	long baud = 9600;
	int ai = 1;
	if (argc > 2 && strcmp(argv[1], "-b") == 0) {
		baud = atol(argv[2]);
		if (baud < 50 || baud > 4000000) { fprintf(stderr, "baud fuori range: %s\n", argv[2]); return 2; }
		ai = 3;
	}
	if (argc - ai < 2) {
		fprintf(stderr, "uso: %s [-b baud] <tty> <byte> [byte...]   (byte in esadecimale, es. 0x11)\n", argv[0]);
		return 2;
	}
	const char *tty = argv[ai];

	int fd = open(tty, O_WRONLY | O_NOCTTY | O_NONBLOCK);
	if (fd < 0) {
		fprintf(stderr, "%s: %s\n", tty, strerror(errno));
		return 1;
	}

	/* termios2 con BOTHER: accetta QUALSIASI intero come baud, non solo le
	 * costanti B*. Serve per la scansione sul filo: se il clock della UART
	 * non e' quello che il driver crede, il baud "giusto" da chiedere e' uno
	 * strano (es. 2304 per avere 9600 veri con un clock 4,17x). */
	struct termios2 t;
	if (ioctl(fd, TCGETS2, &t) == 0) {
		t.c_iflag &= ~(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXOFF | IXANY);
		t.c_oflag &= ~OPOST;
		t.c_lflag &= ~(ECHO | ECHONL | ICANON | ISIG | IEXTEN);
		t.c_cflag &= ~(CSIZE | PARENB | CSTOPB | CRTSCTS | CBAUD);
		t.c_cflag |= CS8 | CLOCAL | CREAD | BOTHER;
		t.c_ispeed = t.c_ospeed = (unsigned)baud;
		if (ioctl(fd, TCSETS2, &t) != 0)
			fprintf(stderr, "%s: TCSETS2: %s (provo comunque)\n", tty, strerror(errno));
	}
	/* Un file normale o una pty senza controparte: TCGETS2 puo' fallire.
	 * Non e' fatale - e' il caso dei test - si scrive lo stesso. */

	unsigned char buf[64];
	int n = 0;
	for (int i = ai + 1; i < argc && n < (int)sizeof(buf); i++) {
		char *end;
		long v = strtol(argv[i], &end, 0);
		if (*end || v < 0 || v > 255) {
			fprintf(stderr, "byte non valido: %s\n", argv[i]);
			close(fd);
			return 2;
		}
		buf[n++] = (unsigned char)v;
	}

	/* blocking per la scrittura, cosi' un tty lento non ci fa perdere byte */
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
	int off = 0;
	while (off < n) {
		ssize_t w = write(fd, buf + off, n - off);
		if (w < 0) {
			if (errno == EINTR) continue;
			fprintf(stderr, "write: %s\n", strerror(errno));
			close(fd);
			return 1;
		}
		off += w;
	}
	ioctl(fd, TCSBRK, 1);   /* = tcdrain(): aspetta che la FIFO si vuoti */
	close(fd);
	return 0;
}
