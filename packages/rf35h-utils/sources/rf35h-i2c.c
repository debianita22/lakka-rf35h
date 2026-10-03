/* rf35h-i2c - legge/scrive un registro a 8 bit su un device I2C che il kernel
 * sta gia' usando (I2C_SLAVE_FORCE). Solo per diagnosi.
 *   rf35h-i2c <bus> <addr> <reg>            legge
 *   rf35h-i2c <bus> <addr> <reg> <val>      scrive e rilegge          */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/i2c-dev.h>
#include <linux/i2c.h>
int main(int argc, char **argv) {
   if (argc < 4) { fprintf(stderr, "uso: %s <bus> <addr> <reg> [val]\n", argv[0]); return 2; }
   unsigned char reg = strtol(argv[3], 0, 0);
   unsigned char buf[2] = { reg, 0 };
   /* Scrivere a mano nei registri analogici dell'rk817 e' pericoloso: il chip
    * e' insieme PMIC e codec, quelle impostazioni non vengono riscritte da
    * nessun driver all'avvio, e la PMIC resta alimentata dalla batteria anche
    * a console spenta. Una scrittura sbagliata sopravvive quindi ai riavvii e
    * segue la console anche su un altro sistema operativo: e' successo
    * davvero, con audio distorto su ogni uscita e su ogni OS finche' un
    * evento di alimentazione non ha ripulito lo stato. Per forzare comunque:
    * RF35H_I2C_FORCE=1. */
   if (argc > 4 && strtol(argv[1], 0, 0) == 0 && strtol(argv[2], 0, 0) == 0x20
       && reg >= 0x10 && reg <= 0x4f && !getenv("RF35H_I2C_FORCE")) {
      fprintf(stderr,
         "rf35h-i2c: rifiuto di scrivere nel registro 0x%02x del codec rk817.\n"
         "Quei valori non vengono ripristinati al boot e la PMIC non si spegne\n"
         "mai: una scrittura sbagliata resta finche' non si stacca la batteria.\n"
         "Per il volume usa rf35h-dac-volume. Per forzare: RF35H_I2C_FORCE=1\n",
         reg);
      return 3;
   }
   char path[32]; snprintf(path, sizeof(path), "/dev/i2c-%ld", strtol(argv[1], 0, 0));
   int fd = open(path, O_RDWR); if (fd < 0) { perror(path); return 1; }
   if (ioctl(fd, I2C_SLAVE_FORCE, strtol(argv[2], 0, 0)) < 0) { perror("I2C_SLAVE_FORCE"); return 1; }
   if (argc > 4) { buf[1] = strtol(argv[4], 0, 0); if (write(fd, buf, 2) != 2) { perror("write"); return 1; } }
   if (write(fd, &reg, 1) != 1 || read(fd, &buf[1], 1) != 1) { perror("read"); return 1; }
   printf("0x%02x = 0x%02x\n", reg, buf[1]); return 0;
}
