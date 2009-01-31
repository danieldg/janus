/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <stdint.h>
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
	char* msg;
	struct queue sendq, recvq;
	// TODO more SSL state
	// TODO dns state
};

#define STATE_TYPE       0x3
#define STATE_T_NETWORK  0x0
#define STATE_T_LISTEN   0x1
#define STATE_T_DNSQ     0x2

#define STATE_F_ACCEPT   0x010
#define STATE_F_CONNPEND 0x020
#define STATE_E_SOCK     0x040
#define STATE_E_DROP     0x080
#define STATE_F_SSL      0x100
#define STATE_F_SSL_RBLK 0x200
#define STATE_F_SSL_WBLK 0x400

int q_read(int fd, struct queue* q);
int q_write(int fd, struct queue* q);

char* q_gets(struct queue* q);
void q_puts(struct queue* q, char* line, int wide_newline);
void fdprintf(int fd, const char* format, ...);
