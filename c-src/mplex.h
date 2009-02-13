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

#define MIN_QUEUE 16384
#define IDEAL_QUEUE 32768
#define QUEUE_JUMP 32768

struct queue {
	uint8_t* data;
	int start;
	int end;
	int size;
};

struct sockifo {
	int fd;
	int netid;
	struct {
		unsigned int type:2;
		unsigned int poll:2;

		unsigned int mplex_dropped:1;
		unsigned int connpend:1;
		unsigned int frozen:1;

#if SSL_GNUTLS
		unsigned int ssl:2;
#endif
	} state;

	struct queue sendq, recvq;
#define ifo_newfd recvq.start
#if SSL_GNUTLS
	gnutls_certificate_credentials_t xcred;
	gnutls_session_t ssl;
#endif
};

#define TYPE_NETWORK 0
#define TYPE_LISTEN 1
#define TYPE_MPLEX 2

enum polling {
	POLL_NORMAL,
	POLL_FORCE_ROK,
	POLL_FORCE_WOK,
	POLL_HANG,
};

enum ssl_state {
	PLAIN = 0,
	SSL_HSHK,
	SSL_ACTIVE,
	SSL_BYE,
};

void esock(struct sockifo* ifo, const char* msg);

int q_bound(struct queue* q, int min, int ideal);
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
void ssl_free(struct sockifo* ifo);
#endif

