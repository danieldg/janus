/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#if SSL_GNUTLS
#define SSL_ENABLED 1
#endif

#include <stdint.h>
#if SSL_GNUTLS
#include <gnutls/gnutls.h>
#endif
#define MIN_RECVQ 8192
#define IDEAL_SENDQ 16384
#define IDEAL_RECVQ 16384

struct queue {
	uint8_t* data;
	int start;
	int end;
	int size;
};

struct sockifo {
	int fd;
	int state;

	int netid;
	struct queue sendq, recvq;
#define ifo_newfd recvq.start
#if SSL_GNUTLS
	gnutls_certificate_credentials_t xcred;
	gnutls_session_t ssl;
#endif
};

#define STATE_T_NETWORK  0x1
#define STATE_T_LISTEN   0x2
#define STATE_T_MPLEX    0x4

#define STATE_F_ACCEPTED 0x010
#define STATE_F_CONNPEND 0x020
#define STATE_E_SOCK     0x040
#define STATE_E_DROP     0x080

#if SSL_ENABLED
#define STATE_F_SSL      0x100
#define STATE_F_SSL_RBLK 0x200
#define STATE_F_SSL_WBLK 0x400
#define STATE_F_SSL_HSHK 0x1000
#define STATE_F_SSL_BYE  0x2000
#define STATE_SSL_OK(x) (!((x) & 0x3000))
#else
#define STATE_F_SSL      0
#define STATE_F_SSL_RBLK 0
#define STATE_F_SSL_WBLK 0
#define STATE_F_SSL_HSHK 0
#endif

void esock(struct sockifo* ifo, const char* msg);

int q_bound(struct queue* q, int min, int ideal, int max);
int q_read(int fd, struct queue* q);
int q_write(int fd, struct queue* q);

char* q_gets(struct queue* q);
void q_puts(struct queue* q, const char* line, int newlines);
void qprintf(struct queue* q, const char* format, ...);

#if SSL_ENABLED
void ssl_gblinit();
void ssl_init(struct sockifo* ifo, const char* key, const char* cert, const char* ca, int server);
void ssl_readable(struct sockifo* ifo);
void ssl_writable(struct sockifo* ifo);
void ssl_drop(struct sockifo* ifo);
void ssl_close(struct sockifo* ifo);
#else
#define ssl_gblinit() do {} while (0)
#define ssl_readable(i) do {} while (0)
#define ssl_writable(i) do {} while (0)
#define ssl_drop(i) do {} while (0)
#define ssl_close(i) do {} while (0)
#endif

