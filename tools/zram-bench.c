/* Confronto degli algoritmi di zram su dati realistici, eseguito su arm64.
 * Misura cio' che conta per un handheld: velocita' di DEcompressione (ogni
 * page fault la paga) e rapporto (quanta RAM si guadagna). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "lz4.h"
#include "zstd.h"
#include "lzo_api.h"

#define PAGE 4096
static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec/1e9; }

static unsigned char *data; static size_t nbytes, npages;
static char lzo_wrk[LZO1X_1_MEM_COMPRESS];

int main(int argc, char **argv) {
   FILE *f = fopen(argv[1], "rb");
   if (!f) { perror(argv[1]); return 1; }
   fseek(f, 0, SEEK_END); nbytes = ftell(f); fseek(f, 0, SEEK_SET);
   nbytes -= nbytes % PAGE; npages = nbytes / PAGE;
   data = malloc(nbytes);
   if (fread(data, 1, nbytes, f) != nbytes) { fprintf(stderr, "read\n"); return 1; }
   fclose(f);
   printf("dati: %zu pagine da 4 KB (%zu KB)\n\n", npages, nbytes/1024);
   printf("%-10s %8s %10s %10s\n", "algoritmo", "rapporto", "comp MB/s", "decomp MB/s");

   unsigned char *cbuf = malloc(PAGE*2), *dbuf = malloc(PAGE*2);
   const int REP = 20;

   /* --- LZ4 --- */
   { size_t tot=0; double t0,t1,tc=0,td=0;
     size_t *clen = malloc(npages*sizeof(size_t));
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++) clen[i]=LZ4_compress_default((char*)data+i*PAGE,(char*)cbuf,PAGE,PAGE*2); t1=now(); tc=t1-t0;
     for (size_t i=0;i<npages;i++) tot+=clen[i]?clen[i]:PAGE;
     /* decomp: ricomprimo una pagina alla volta e la decomprimo */
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++){ int c=LZ4_compress_default((char*)data+i*PAGE,(char*)cbuf,PAGE,PAGE*2); if(c>0) LZ4_decompress_safe((char*)cbuf,(char*)dbuf,c,PAGE);} t1=now(); td=(t1-t0)-tc;
     printf("%-10s %7.2fx %10.0f %10.0f\n","lz4",(double)nbytes/tot,nbytes*REP/tc/1e6, td>0?nbytes*REP/td/1e6:0);
     free(clen); }

   /* --- zstd livello 1 (quello che usa zram) --- */
   { size_t tot=0; double t0,t1,tc,td;
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++){ size_t c=ZSTD_compress(cbuf,PAGE*2,data+i*PAGE,PAGE,1); if(r==0) tot+=ZSTD_isError(c)?PAGE:c; } t1=now(); tc=t1-t0;
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++){ size_t c=ZSTD_compress(cbuf,PAGE*2,data+i*PAGE,PAGE,1); if(!ZSTD_isError(c)) ZSTD_decompress(dbuf,PAGE*2,cbuf,c);} t1=now(); td=(t1-t0)-tc;
     printf("%-10s %7.2fx %10.0f %10.0f\n","zstd-1",(double)nbytes/tot,nbytes*REP/tc/1e6, td>0?nbytes*REP/td/1e6:0); }

   /* --- LZO (lzo1x-1, la base di lzo-rle) --- */
   { size_t tot=0; double t0,t1,tc,td; size_t cl, dl;
     
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++){ lzorle1x_1_compress(data+i*PAGE,PAGE,cbuf,&cl,lzo_wrk); if(r==0) tot+=cl; } t1=now(); tc=t1-t0;
     t0=now(); for (int r=0;r<REP;r++) for (size_t i=0;i<npages;i++){ lzorle1x_1_compress(data+i*PAGE,PAGE,cbuf,&cl,lzo_wrk); lzo1x_decompress_safe(cbuf,cl,dbuf,&dl);} t1=now(); td=(t1-t0)-tc;
     printf("%-10s %7.2fx %10.0f %10.0f\n","lzo-rle",(double)nbytes/tot,nbytes*REP/tc/1e6, td>0?nbytes*REP/td/1e6:0); }
   return 0;
}
