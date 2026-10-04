/* rf35h-i2c - legge/scrive un registro a 8 bit su un device I2C che il kernel
 * sta gia' usando (I2C_SLAVE_FORCE). Solo per diagnosi.
 *   rf35h-i2c <bus> <addr> <reg>            legge
 *   rf35h-i2c <bus> <addr> <reg> <val>      scrive e rilegge
 * Numeri in decimale o in esadecimale (0x..): bus 0-255, addr 0x00-0x7f, reg
 * e val 0x00-0xff. Un argomento storto e' un errore (uscita 2): prima "0x1e4"
 * diventava il registro 0xe4 e "256" il valore 0, in silenzio.            */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>

/* Tutto l'argomento deve essere un numero fra 0 e max: niente segno, spazi o
 * caratteri in coda. Base 0 come strtol: 0x.. esadecimale, 0.. ottale. */
static int num(const char *s, long max, long *out) {
   char *end;
   long v;
   if (*s < '0' || *s > '9') return 0;
   errno = 0;
   v = strtol(s, &end, 0);
   if (errno || *end || v < 0 || v > max) return 0;
   *out = v;
   return 1;
}

int main(int argc, char **argv) {
   long bus, addr, reg, val = -1;
   if (argc < 4 || argc > 5) { fprintf(stderr, "uso: %s <bus> <addr> <reg> [val]\n", argv[0]); return 2; }
   if (!num(argv[1], 255, &bus) || !num(argv[2], 0x7f, &addr) || !num(argv[3], 0xff, &reg)
       || (argc == 5 && !num(argv[4], 0xff, &val))) {
      fprintf(stderr, "rf35h-i2c: argomento non valido (bus 0-255, addr 0x00-0x7f, reg e val 0x00-0xff)\n"
                      "uso: %s <bus> <addr> <reg> [val]\n", argv[0]);
      return 2;
   }
   /* L'rk817 (bus 0, indirizzo 0x20) e' insieme PMIC e codec, e nessuna sua
    * scrittura passa senza RF35H_I2C_FORCE=1. Codec: quelle impostazioni non
    * vengono riscritte da nessun driver all'avvio e la PMIC resta alimentata
    * dalla batteria anche a console spenta, quindi una scrittura sbagliata
    * sopravvive ai riavvii e segue la console anche su un altro sistema
    * operativo - e' successo davvero, con audio distorto su ogni uscita e su
    * ogni OS finche' un evento di alimentazione non ha ripulito lo stato. Il
    * resto e' peggio: tensioni dei regolatori (0xb1-0xf4, CPU, GPU, DDR, I/O),
    * caricabatteria (CHRG_OUT 0xe4: tensione di fine carica), SYS_CFG. Prima
    * il controllo copriva solo il codec (0x10-0x4f) e quelli passavano.
    * Il controllo sta prima di aprire il bus: rifiuta senza toccare il device. */
   if (val >= 0 && bus == 0 && addr == 0x20) {
      const char *force = getenv("RF35H_I2C_FORCE");
      if (!force || strcmp(force, "1") != 0) {
         if (reg >= 0x10 && reg <= 0x4f)
            fprintf(stderr,
               "rf35h-i2c: rifiuto di scrivere nel registro 0x%02lx del codec rk817.\n"
               "Quei valori non vengono ripristinati al boot e la PMIC non si spegne\n"
               "mai: una scrittura sbagliata resta finche' non si stacca la batteria.\n"
               "Per il volume usa rf35h-dac-volume.\n", reg);
         else
            fprintf(stderr,
               "rf35h-i2c: rifiuto di scrivere nel registro 0x%02lx della PMIC rk817.\n"
               "Li' stanno le tensioni dei regolatori (CPU, GPU, RAM, I/O), il\n"
               "caricabatteria (tensione e corrente di carica) e la configurazione\n"
               "di sistema: un valore sbagliato puo' spegnere la console di colpo,\n"
               "danneggiare la batteria o l'hardware, e la PMIC non si azzera\n"
               "spegnendo.\n", reg);
         fprintf(stderr, "Per forzare, sapendo cosa fai: RF35H_I2C_FORCE=1\n");
         return 3;
      }
   }
   unsigned char buf[2] = { (unsigned char)reg, 0 };
   char path[32]; snprintf(path, sizeof(path), "/dev/i2c-%ld", bus);
   int fd = open(path, O_RDWR); if (fd < 0) { perror(path); return 1; }
   if (ioctl(fd, I2C_SLAVE_FORCE, addr) < 0) { perror("I2C_SLAVE_FORCE"); return 1; }
   if (val >= 0) { buf[1] = (unsigned char)val; if (write(fd, buf, 2) != 2) { perror("write"); return 1; } }
   if (write(fd, buf, 1) != 1 || read(fd, &buf[1], 1) != 1) { perror("read"); return 1; }
   printf("0x%02lx = 0x%02x\n", reg, buf[1]); return 0;
}
