/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

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
	char* msg;

	// TODO ssl state
	// TODO dns state
};

struct iostate {
	int size;
	int count;
	int at;

	int maxfd;
	fd_set readers;
	fd_set writers;
	struct sockifo net[0];
};

#define STATE_TYPE       0x3
#define STATE_T_NETWORK  0x0
#define STATE_T_LISTEN   0x1
#define STATE_T_DNSQ     0x2
#define STATE_F_ACCEPT   0x4
#define STATE_F_CONNPEND 0x8
#define STATE_E_SOCK    0x10
#define STATE_E_DROP    0x20

static pid_t worker_pid;
static int worker_sock;
static struct queue worker_recvq;
static struct iostate* sockets;

void init_worker(const char* conf) {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, PF_UNSPEC, sv)) {
		perror("socketpair");
		exit(1);
	}
	worker_pid = fork();
	if (worker_pid < 0) {
		perror("fork");
		exit(1);
	}
	if (worker_pid == 0) {
		close(sv[0]);
		dup2(sv[1], 0);
		if (sv[1])
			close(sv[1]);
		close(1);
		int log = open("daemon2.log", O_WRONLY| O_CREAT, 0666);
		if (log != 1) {
			perror("open");
			exit(1);
		}
		dup2(1, 2);
		execlp("perl", "perl", "src/worker.pl", conf, NULL);
		perror("exec");
		exit(1);
	} else {
		close(sv[1]);
		worker_sock = sv[0];
	}
}

void worker_printf(const char* format, ...) {
	char line[8192];
	va_list ap;
	va_start(ap, format);
	int n = vsnprintf(line, 8192, format, ap);
	va_end(ap);
	if (n > 8192) {
		abort();
	}
	char* at = line;
	while (n) {
		int r = write(worker_sock, at, n);
		if (r <= 0) {
			exit(1);
		}
		at += r;
		n -= r;
	}
}

int do_recvq(int fd, struct queue* q) {
	if (q->start == q->end) {
		q->start = q->end = 0;
		if (q->size > IDEAL_RECVQ) {
			free(q->data);
			q->data = malloc(IDEAL_RECVQ);
		}
	}
	int slack = q->size - q->end;
	if (slack < MIN_RECVQ) {
		int size = q->end - q->start;
		if (slack + q->start > MIN_RECVQ) {
			memmove(q->data, q->data + q->start, size);
			slack += q->start;
			q->start = 0;
			q->end = size;
		} else {
			int newsiz = (size * 3)/2 + MIN_RECVQ;
			uint8_t* dat = malloc(newsiz);
			memcpy(dat, q->data + q->start, size);
			free(q->data);
			q->data = dat;
			q->size = newsiz;
			q->start = 0;
			q->end = size;
			slack = newsiz - size;
		}
	}
	int len = read(fd, q->data + q->end, slack);
	if (len > 0) {
		q->end += len;
		return 0;
	} else {
		return 1;
	}
}

/*
 * Get a single line from the worker socket. Trailing \n is replaced by null
 * Returned pointer is valid until the next call to worker_gets
 */
char* worker_gets() {
	while (1) {
		int i;
		for(i = worker_recvq.start; i < worker_recvq.end; i++) {
			if (worker_recvq.data[i] == '\n') {
				uint8_t* rv = worker_recvq.data + worker_recvq.start;
				worker_recvq.data[i] = '\0';
				worker_recvq.start = i+1;
				return (char*)rv;
			}
		}
		if (do_recvq(worker_sock, &worker_recvq)) {
			exit(1);
		}
	}
}

void reboot(const char* conf, const char* line) {
	// TODO protocol change, "R <filename>"
	line += 7; // "REBOOT "
	close(worker_sock);
	init_worker(conf);
	worker_printf("RESTORE %s", line);
}

void readable(struct sockifo* ifo) {
	if ((ifo->state & STATE_TYPE) == STATE_T_LISTEN) {
		ifo->state |= STATE_F_ACCEPT;
		return;
	} else if ((ifo->state & STATE_TYPE) == STATE_T_DNSQ) {
		// TODO support
		exit(2);
		return;
	}
	if (do_recvq(ifo->fd, &ifo->recvq)) {
		ifo->state |= STATE_E_SOCK;
		if (!ifo->msg)
			ifo->msg = strdup(strerror(errno));
	}
}

void writable(struct sockifo* ifo) {
	if (ifo->state & STATE_F_CONNPEND) {
		ifo->state &= ~STATE_F_CONNPEND;
		FD_SET(ifo->fd, &sockets->readers);
	}
	int size = ifo->sendq.end - ifo->sendq.start;
	if (size) {
		int len = write(ifo->fd, ifo->sendq.data + ifo->sendq.start, size);
		if (len > 0) {
			ifo->sendq.start += len;
		} else if (errno == EAGAIN) {
			// drop to FD_SET
		} else {
			ifo->state |= STATE_E_SOCK;
			if (!ifo->msg)
				ifo->msg = strdup(strerror(errno));
			return;
		}
	}
	if (ifo->sendq.start == ifo->sendq.end) {
		ifo->sendq.start = ifo->sendq.end = 0;
		if (ifo->sendq.size > IDEAL_SENDQ) {
			free(ifo->sendq.data);
			ifo->sendq.data = malloc(IDEAL_SENDQ);
		}
		FD_CLR(ifo->fd, &sockets->writers);
	} else {
		FD_SET(ifo->fd, &sockets->writers);
	}
}

void addnet(char* line) {
	int netid = 0, port = 0;
	// TODO protocol change, IC/IL
	line += 4;
	char type = *line++;
	if (*line++ != ' ') exit(1);
	while (isdigit(*line)) {
		netid = 10 * netid + *line++ - '0';
	}
	if (*line++ != ' ') exit(1);

	const char* addr = line;
	int addrtype = 0;
// 0 = IPv4 (or incomplete IPv6/DNS)
// 1 = IPv6/DNS (incomplete)
// 3 = IPv6
// 7 = DNS
	while (*line) {
		char c = *line;
		if (c == ' ') break;
		line++;
		if (isdigit(c) || c == '.')
			continue;
		else if ((c > 'a' && c < 'f') || (c > 'A' && c < 'F'))
			addrtype |= 1;
		else if (c == ':')
			addrtype |= 3;
		else
			addrtype |= 7;
	}

	if (*line != ' ') exit(1);
	*line++ = '\0';

	while (isdigit(*line)) {
		port = 10 * port + *line++ - '0';
	}
	const char* bindto = NULL;
	if (*line == ' ') {
		bindto = ++line;
		while (*line && *line != ' ') line++;
		if (*line) {
			*line++ = '\0';
			// TODO SSL parse
		}
	}

	int state = 0;
	// TODO DNS

	int fd = socket(AF_INET6, SOCK_STREAM, 0);
	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	struct sockaddr_in6 sa = {
		.sin6_family = AF_INET6,
		.sin6_port = htons(port),
	};
	inet_pton(AF_INET6, addr, &sa.sin6_addr);
	if (type == 'C') {
		if (*bindto) {
			struct sockaddr_in6 bsa = {
				.sin6_family = AF_INET6,
				.sin6_port = 0,
			};
			inet_pton(AF_INET6, bindto, &bsa.sin6_addr);
			bind(fd, (struct sockaddr*)&bsa, sizeof(bsa));
		}
		connect(fd, (struct sockaddr*)&sa, sizeof(sa));
		state = STATE_T_NETWORK | STATE_F_CONNPEND;
		FD_SET(fd, &sockets->writers);
	} else if (type == 'L') {
		if (bind(fd, (struct sockaddr*)&sa, sizeof(sa))) {
			worker_printf("ERR %s\n", strerror(errno));
			close(fd);
			return;
		}
		if (listen(fd, 2)) {
			worker_printf("ERR %s\n", strerror(errno));
			close(fd);
			return;
		}
		state = STATE_T_LISTEN;
		worker_printf("OK\n");
		FD_SET(fd, &sockets->readers);
	}
	// TODO SSL init

	int id = sockets->count++;
	if (id >= sockets->size) {
		sockets->size += 4;
		sockets = realloc(sockets, sizeof(struct iostate) + sockets->size * sizeof(struct sockifo));
	}
	if (sockets->maxfd < fd)
		sockets->maxfd = fd;
	memset(&(sockets->net[id]), 0, sizeof(struct sockifo));
	sockets->net[id].fd = fd;
	sockets->net[id].state = state;
	sockets->net[id].netid = netid;
}

void delnet_real(struct sockifo* ifo) {
	int fd = ifo->fd;
	FD_CLR(fd, &sockets->readers);
	FD_CLR(fd, &sockets->writers);
	close(fd);
	free(ifo->sendq.data);
	free(ifo->recvq.data);
	free(ifo->msg);
	sockets->count--;
	struct sockifo* last = &(sockets->net[sockets->count]);
	if (ifo != last) {
		memcpy(ifo, last, sizeof(struct sockifo));
	}
}

void delnet(const char* line) {
	int netid = 0, i;
	sscanf(line, "DELNET %d", &netid);
	for(i=0; i < sockets->count; i++) {
		if (sockets->net[i].netid == netid) {
			sockets->net[i].state |= STATE_E_DROP;
			FD_CLR(sockets->net[i].fd, &sockets->readers);
			return;
		}
	}
	// TODO better error here
	exit(2);
}

void iowait(const char* line) {
	time_t now = time(NULL);
	int ts_end = now;
	sscanf(line, "W %d", &ts_end);
	int wait = ts_end - now;
	if (wait < 1) wait = 1;
	struct timeval to = {
		.tv_sec = wait,
		.tv_usec = 0,
	};
	int i;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (FD_ISSET(ifo->fd, &sockets->writers) && !(ifo->state & STATE_F_CONNPEND)) {
			// dump sendq before calling select()
			writable(ifo);
		}
		if (ifo->state & STATE_E_DROP && (ifo->sendq.end == 0 || ifo->state & STATE_E_SOCK)) {
			delnet_real(ifo);
			i--;
		}
	}
	fd_set rok = sockets->readers;
	fd_set wok = sockets->writers;
	int ready = select(sockets->maxfd + 1, &rok, &wok, NULL, &to);
	worker_printf("DONE\n");
	sockets->at = 0;
	if (ready > 0) {
		for(i=0; i < sockets->count; i++) {
			if (FD_ISSET(sockets->net[i].fd, &wok)) {
				writable(&sockets->net[i]);
			}
			if (FD_ISSET(sockets->net[i].fd, &rok)) {
				readable(&sockets->net[i]);
			}
		}
	}
}

void oneline() {
	while (sockets->at < sockets->count) {
		struct sockifo* ifo = &sockets->net[sockets->at];
		if (ifo->state & STATE_E_DROP) {
			sockets->at++;
			continue;
		}
		if ((ifo->state & STATE_TYPE) == STATE_T_NETWORK) {
			int i = ifo->recvq.start;
			while (i < ifo->recvq.end) {
				if (ifo->recvq.data[i] == '\r' && ifo->recvq.data[i+1] == '\n') {
					ifo->recvq.data[i] = '\n';
				}
				if (ifo->recvq.data[i] == '\n') {
					if (ifo->recvq.start == i) {
						ifo->recvq.start++;
					} else {
						ifo->recvq.data[i] = '\0';
						worker_printf("%d %s\n", ifo->netid, ifo->recvq.data + ifo->recvq.start);
						ifo->recvq.start = i+1;
						return;
					}
				}
				i++;
			}
		} else if ((ifo->state & STATE_TYPE) == STATE_T_LISTEN && (ifo->state & STATE_F_ACCEPT)) {
			struct sockaddr_in6 addr;
			unsigned int addrlen = sizeof(addr);
			char linebuf[8192];
			int fd = accept(ifo->fd, (struct sockaddr*)&addr, &addrlen);
			if (fd < 0) {
				ifo->state &= ~STATE_F_ACCEPT;
			} else {
				int flags = fcntl(fd, F_GETFL);
				flags |= O_NONBLOCK;
				fcntl(fd, F_SETFL, flags);
				fcntl(fd, F_SETFD, FD_CLOEXEC);
				inet_ntop(AF_INET6, &addr.sin6_addr, linebuf, sizeof(linebuf));
				worker_printf("PEND %d %s\n", ifo->netid, linebuf);
				char* line = worker_gets();
				int netid = 0;
				if (sscanf(line, "PEND %d", &netid)) {
					int id = sockets->count++;
					if (id >= sockets->size) {
						sockets->size += 4;
						sockets = realloc(sockets, sizeof(struct iostate) + sockets->size * sizeof(struct sockifo));
					}
					if (sockets->maxfd < fd)
						sockets->maxfd = fd;
					memset(&(sockets->net[id]), 0, sizeof(struct sockifo));
					sockets->net[id].fd = fd;
					sockets->net[id].state = STATE_T_NETWORK;
					sockets->net[id].netid = netid;
					FD_SET(fd, &sockets->readers);
				} else {
					// TODO PEND-SSL
					close(fd);
				}
				return;
			}
		}
		sockets->at++;
		if (ifo->state & STATE_E_SOCK) {
			const char* msg = ifo->msg ? ifo->msg : "Unknown connection error";
			worker_printf("DELINK %d %s\n", ifo->netid, msg);
			return;
		}
	}
	worker_printf("L\n");
	sockets->at = 0;
}

void sqfill(const char* line) {
	int netid = 0;
	while (isdigit(*line)) {
		netid = 10 * netid + (*line - '0');
		line++;
	}
	line++;
	int i;
	struct queue* sq;
	for(i=0; i < sockets->count; i++) {
		if (sockets->net[i].netid == netid)
			goto found;
	}
	// TODO report error here
	exit(2);
	return;
found:
	sq = &(sockets->net[i].sendq);
	while (1) {
		if (sq->end < sq->size) {
			uint8_t c = *line++;
			if (c == '\0')
				c = '\n';
			sq->data[sq->end++] = c;
			if (c == '\n')
				break;
		} else {
			sq->size += sq->end - sq->start;
			if (sq->size < IDEAL_SENDQ)
				sq->size = IDEAL_SENDQ;
			uint8_t* data = malloc(sq->size);
			memcpy(data, sq->data + sq->start, sq->end - sq->start);
			free(sq->data);
			sq->data = data;
			sq->end = sq->end - sq->start;
			sq->start = 0;
		}
	}
	FD_SET(sockets->net[i].fd, &sockets->writers);
}


int main(int argc, char** argv) {
	init_worker(argv[1]);

	sockets = malloc(sizeof(struct iostate) + 16 * sizeof(struct sockifo));
	sockets->size = 16;
	sockets->count = 0;
	sockets->maxfd = 1;
	sockets->at = 0;
	FD_ZERO(&sockets->readers);
	FD_ZERO(&sockets->writers);

	worker_printf("BOOT 7\n");

	while (1) {
		char* line = worker_gets();
		switch (*line) {
		case 'W':
			iowait(line);
			break;
		case 'N':
			oneline();
			break;
		case '0' ... '9':
			sqfill(line);
			break;
		case 'I':
			addnet(line);
			break;
		case 'D':
			delnet(line);
			break;
		case 'R':
			reboot(argv[1], line);
			break;
		default:
			return 1;
		}
	}

	return 0;
}
