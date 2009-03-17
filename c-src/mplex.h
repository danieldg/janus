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
#define TIMEOUT 150

struct queue {
	uint8_t* data;
	int start;
	int end;
	int size;
};

struct line {
	uint8_t* data;
	int len;
};

struct sockifo {
	int fd;
	int netid;
	time_t death_time;
	struct {
		unsigned int type:2;
		unsigned int poll:2;

		unsigned int mplex_dropped:1;
		unsigned int connpend:1;
		unsigned int frozen:1;

#if SSL_GNUTLS
		unsigned int ssl:2;
		unsigned int ssl_verify_type:2;
#endif
	} state;

	struct queue sendq, recvq;
#define ifo_newfd recvq.start
#if SSL_GNUTLS
	gnutls_certificate_credentials_t xcred;
	gnutls_session_t ssl;
	char* fingerprint;
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

enum ssl_verify_type {
	VERIFY_NONE,
	VERIFY_CA,
	VERIFY_FP,
};

void esock(struct sockifo* ifo, const char* msg);

int q_bound(struct queue* q, int min);
int q_read(int fd, struct queue* q);
int q_write(int fd, struct queue* q);

struct line q_getl(struct queue* q);
void q_putl(struct queue* q, struct line line, int newlines);
void qprintf(struct queue* q, const char* format, ...);
#define q_puts(q, s) q_putl(q, (struct line){ (uint8_t*)(s ""), sizeof(s) - 1}, 0)

void sscan(struct line line, const char* format, void* dst);

#if SSL_ENABLED
void ssl_gblinit();
void ssl_init(struct sockifo* ifo, const char* key, const char* cert, const char* ca, int server);
void ssl_readable(struct sockifo* ifo);
void ssl_writable(struct sockifo* ifo);
void ssl_drop(struct sockifo* ifo);
void ssl_free(struct sockifo* ifo);
#endif

