/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
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
#include "mplex.h"

struct iostate {
	int size;
	int count;
	int at;

	struct sockifo net[0];
};

static pid_t worker_pid;
static int worker_sock;
static struct queue worker_recvq;
static struct iostate* sockets;

#define worker_printf(x...) fdprintf(worker_sock, x)

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

/*
 * Get a single line from the worker socket. Trailing \n is replaced by null
 * Returned pointer is valid until the next call to worker_gets
 */
char* worker_gets() {
	while (1) {
		char* rv = q_gets(&worker_recvq);
		if (rv)
			return rv;
		if (q_read(worker_sock, &worker_recvq))
			exit(1);
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
	}
	if (ifo->state & STATE_F_SSL) {
		ssl_readable(ifo);
	} else {
		if (q_read(ifo->fd, &ifo->recvq)) {
			ifo->state |= STATE_E_SOCK;
			ifo->msg = strerror(errno);
		}
	}
}

void writable(struct sockifo* ifo) {
	if (ifo->state & STATE_F_CONNPEND) {
		ifo->state &= ~STATE_F_CONNPEND;
	}
	if (ifo->state & STATE_F_SSL) {
		ssl_writable(ifo);
	} else {
		if (q_write(ifo->fd, &ifo->sendq)) {
			ifo->state |= STATE_E_SOCK;
			ifo->msg = strerror(errno);
		}
	}
}

static struct sockifo* alloc_ifo() {
	int id = sockets->count++;
	if (id >= sockets->size) {
		sockets->size += 4;
		sockets = realloc(sockets, sizeof(struct iostate) + sockets->size * sizeof(struct sockifo));
	}
	memset(&(sockets->net[id]), 0, sizeof(struct sockifo));
	return &(sockets->net[id]);
}

void addnet(char* line) {
	int netid = 0;
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

#define WORDSTRING(x) \
	const char* x = NULL; \
	if (*line == ' ') { \
		*line = '\0'; \
		x = ++line; \
		while (*line && *line != ' ') line++; \
	}
	WORDSTRING(port)
	WORDSTRING(bindto)
	WORDSTRING(ssl_key)
	WORDSTRING(ssl_cert)
	WORDSTRING(ssl_ca)
#undef WORDSTRING
	*line = '\0';

	if (!port || !*port)
		exit(2);

	int state = 0;

	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
		.ai_protocol = PF_UNSPEC,
		.ai_flags = (type == 'L' ? AI_PASSIVE | AI_ADDRCONFIG : AI_ADDRCONFIG),
	};
	struct addrinfo* ainfo = NULL;
	int gai_err = getaddrinfo(addr, port, &hints, &ainfo);
	if (gai_err) {
		if (type == 'C') {
			struct sockifo* ifo = alloc_ifo();
			ifo->fd = -1;
			ifo->netid = netid;
			ifo->state = STATE_T_NETWORK | STATE_E_SOCK;
			ifo->msg = gai_strerror(gai_err);
		} else {
			worker_printf("ERR %s\n", gai_strerror(gai_err));
		}
		return;
	}

	int fd = socket(ainfo->ai_family, ainfo->ai_socktype, ainfo->ai_protocol);
	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	if (type == 'C') {
		if (bindto && *bindto) {
			if (ainfo->ai_family == AF_INET6) {
				struct sockaddr_in6 bsa = {
					.sin6_family = AF_INET6,
					.sin6_port = 0,
				};
				inet_pton(AF_INET6, bindto, &bsa.sin6_addr);
				bind(fd, (struct sockaddr*)&bsa, sizeof(bsa));
			} else {
				struct sockaddr_in bsa = {
					.sin_family = AF_INET,
					.sin_port = 0,
				};
				inet_pton(AF_INET, bindto, &bsa.sin_addr);
				bind(fd, (struct sockaddr*)&bsa, sizeof(bsa));
			}
		}
		connect(fd, ainfo->ai_addr, ainfo->ai_addrlen);
		state = STATE_T_NETWORK | STATE_F_CONNPEND;
	} else if (type == 'L') {
		int optval = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(int));
		if (bind(fd, ainfo->ai_addr, ainfo->ai_addrlen)) {
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
	}
	freeaddrinfo(ainfo);

	struct sockifo* ifo = alloc_ifo();
	ifo->fd = fd;
	ifo->state = state;
	ifo->netid = netid;
	if (ssl_key && *ssl_key) {
		ssl_init_client(ifo, ssl_key, ssl_cert, ssl_ca);
	}
}

void delnet_real(struct sockifo* ifo) {
	if (ifo->state & STATE_F_SSL)
		ssl_close(ifo);
	close(ifo->fd);
	free(ifo->sendq.data);
	free(ifo->recvq.data);
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
			return;
		}
	}
	// TODO better error here
	exit(2);
}

static inline int need_read(struct sockifo* ifo) {
	if (ifo->state & STATE_F_CONNPEND)
		return 0;
	if (ifo->state & STATE_F_SSL)
		return ifo->state & STATE_F_SSL_RBLK;
	if (ifo->state & STATE_E_DROP)
		return 0;
	return 1;
}

static inline int need_write(struct sockifo* ifo) {
	if (ifo->state & STATE_F_CONNPEND)
		return 1;
	if (ifo->state & STATE_F_SSL)
		return ifo->state & STATE_F_SSL_WBLK;
	return ifo->sendq.end - ifo->sendq.start;
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
	int maxfd = 0;
	fd_set rok, wok;
	FD_ZERO(&rok);
	FD_ZERO(&wok);
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if ((ifo->state & STATE_TYPE) == STATE_T_NETWORK && !(ifo->state & STATE_F_CONNPEND)) {
			writable(ifo);
		}
		if ((ifo->state & STATE_E_DROP) && (ifo->sendq.end == 0 || ifo->state & STATE_E_SOCK)) {
			delnet_real(ifo);
			i--;
			continue;
		}
		if (ifo->state & STATE_E_SOCK)
			continue;
		if (ifo->fd > maxfd)
			maxfd = ifo->fd;
		if (need_read(ifo))
			FD_SET(ifo->fd, &rok);
		if (need_write(ifo))
			FD_SET(ifo->fd, &wok);
	}
	int ready = select(maxfd + 1, &rok, &wok, NULL, &to);
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

int do_accept(struct sockifo* lifo) {
	struct sockaddr_in6 addr;
	unsigned int addrlen = sizeof(addr);
	char linebuf[8192];
	int fd = accept(lifo->fd, (struct sockaddr*)&addr, &addrlen);
	if (fd < 0) {
		lifo->state &= ~STATE_F_ACCEPT;
		return 0;
	}
	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	inet_ntop(AF_INET6, &addr.sin6_addr, linebuf, sizeof(linebuf));
	worker_printf("PEND %d %s\n", lifo->netid, linebuf);
	char* line = worker_gets();
	int netid = 0;
	if (sscanf(line, "PEND %d", &netid)) {
		struct sockifo* nifo = alloc_ifo();
		nifo->fd = fd;
		nifo->state = STATE_T_NETWORK;
		nifo->netid = netid;
	} else if (!strncmp(line, "PEND-SSL ", 9)) {
		line += 9;
		while (isdigit(*line)) {
			netid = 10 * netid + (*line - '0');
			line++;
		}

#define WORDSTRING(x) \
		const char* x = NULL; \
		if (*line == ' ') { \
			*line = '\0'; \
			x = ++line; \
			while (*line && *line != ' ') line++; \
		}
		WORDSTRING(ssl_key)
		WORDSTRING(ssl_cert)
		WORDSTRING(ssl_ca)
#undef WORDSTRING
		*line = '\0';

		struct sockifo* nifo = alloc_ifo();
		nifo->fd = fd;
		nifo->state = STATE_T_NETWORK;
		nifo->netid = netid;
		ssl_init_server(nifo, ssl_key, ssl_cert, ssl_ca);
	} else {
		close(fd);
	}
	return 1;
}

void oneline() {
	while (sockets->at < sockets->count) {
		struct sockifo* ifo = &sockets->net[sockets->at];
		if (ifo->state & STATE_E_DROP) {
			sockets->at++;
			continue;
		}
		if ((ifo->state & STATE_TYPE) == STATE_T_NETWORK) {
			char* line = q_gets(&ifo->recvq);
			if (line) {
				worker_printf("%d %s\n", ifo->netid, line);
				return;
			}
		} else if ((ifo->state & STATE_TYPE) == STATE_T_LISTEN && (ifo->state & STATE_F_ACCEPT)) {
			if (do_accept(ifo))
				return;
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

void sqfill(char* line) {
	int netid = 0;
	while (isdigit(*line)) {
		netid = 10 * netid + (*line - '0');
		line++;
	}
	line++;
	int i;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->netid == netid) {
			q_puts(&ifo->sendq, line, 1);
			return;
		}
	}
	// TODO report error here
	exit(3);
}

int main(int argc, char** argv) {
	struct sigaction ign = {
		.sa_handler = SIG_IGN,
	};
	sigaction(SIGPIPE, &ign, NULL);
	sigaction(SIGCHLD, &ign, NULL);
	init_worker(argv[1]);
	worker_printf("BOOT 7\n");

	sockets = malloc(sizeof(struct iostate) + 16 * sizeof(struct sockifo));
	sockets->size = 16;
	sockets->count = 0;
	sockets->at = 0;

	ssl_gblinit();

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
