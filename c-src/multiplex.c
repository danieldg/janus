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

	struct sockifo net[0];
};

static const char* conffile;
static int io_stop;
static time_t last_ts;
static struct iostate* sockets;

static void init_worker() {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
		perror("socketpair");
		exit(1);
	}
	pid_t worker_pid = fork();
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
		execlp("perl", "perl", "src/worker.pl", conffile, NULL);
		perror("exec");
		exit(1);
	} else {
		close(sv[1]);
		int flags = fcntl(sv[0], F_GETFL);
		flags |= O_NONBLOCK;
		fcntl(sv[0], F_SETFL, flags);
		sockets->net[0].fd = sv[0];
	}
}

static void reboot(const char* line) {
	line++;
	close(sockets->net[0].fd);
	init_worker();
	q_puts(&sockets->net[0].sendq, "RESTORE", 0);
	q_puts(&sockets->net[0].sendq, line, 1);
}

void esock(struct sockifo* ifo, const char* msg) {
	if (ifo->state & STATE_E_SOCK)
		return;
	ifo->state |= STATE_E_SOCK;
	if (ifo->state & STATE_E_DROP)
		return;
	if (ifo->state & STATE_T_MPLEX)
		exit(1);
	qprintf(&sockets->net[0].sendq, "D %d %s\n", ifo->netid, msg);
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

static void addnet(char* line) {
	int netid = 0;
	line++;
	char type = *line++;
	if (type != 'L' && type != 'C') exit(2);
	if (*line++ != ' ') exit(2);
	while (isdigit(*line)) {
		netid = 10 * netid + *line++ - '0';
	}

#define WORDSTRING(x) \
	const char* x = NULL; \
	if (*line == ' ') { \
		*line = '\0'; \
		x = ++line; \
		while (*line && *line != ' ') line++; \
	}
	WORDSTRING(addr)
	WORDSTRING(port)
	WORDSTRING(bindto)
	WORDSTRING(ssl_key)
	WORDSTRING(ssl_cert)
	WORDSTRING(ssl_ca)
#undef WORDSTRING
	*line = '\0';

	if (!addr || !*addr) {
		if (type == 'C')
			exit(2);
		addr = "::";
	}
	if (!port || !*port)
		exit(2);

	struct sockifo* ifo = alloc_ifo();
	ifo->fd = -1;
	ifo->netid = netid;

	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
		.ai_flags = (type == 'C' ? AI_ADDRCONFIG : AI_PASSIVE | AI_ADDRCONFIG),
	};
	struct addrinfo* ainfo = NULL;
	int gai_err = getaddrinfo(addr, port, &hints, &ainfo);
	if (gai_err) {
		ifo->state = STATE_T_NETWORK;
		esock(ifo, gai_strerror(gai_err));
		return;
	}

	int fd = socket(ainfo->ai_family, ainfo->ai_socktype, ainfo->ai_protocol);
	if (fd < 0)
		goto out_err;
	ifo->fd = fd;
	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	if (type == 'C') {
		ifo->state |= STATE_T_NETWORK;
		if (bindto && *bindto) {
			if (ainfo->ai_family == AF_INET6) {
				struct sockaddr_in6 bsa = {
					.sin6_family = AF_INET6,
					.sin6_port = 0,
				};
				inet_pton(AF_INET6, bindto, &bsa.sin6_addr);
				if (bind(fd, (struct sockaddr*)&bsa, sizeof(bsa)))
					goto out_err;
			} else {
				struct sockaddr_in bsa = {
					.sin_family = AF_INET,
					.sin_port = 0,
				};
				inet_pton(AF_INET, bindto, &bsa.sin_addr);
				if (bind(fd, (struct sockaddr*)&bsa, sizeof(bsa)))
					goto out_err;
			}
		}
		connect(fd, ainfo->ai_addr, ainfo->ai_addrlen);
		ifo->state |= STATE_F_CONNPEND;
	} else if (type == 'L') {
		ifo->state |= STATE_T_LISTEN;
		int optval = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(int));
		if (bind(fd, ainfo->ai_addr, ainfo->ai_addrlen))
			goto out_err;
		if (listen(fd, 2))
			goto out_err;
	}

	if (ssl_key && *ssl_key) {
		ssl_init_client(ifo, ssl_key, ssl_cert, ssl_ca);
	}

out_free:
	freeaddrinfo(ainfo);
	return;
out_err:
	esock(ifo, strerror(gai_err));
	goto out_free;
}

static void delnet_real(struct sockifo* ifo) {
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

static void delnet(const char* line) {
	int netid = 0, i;
	sscanf(line, "D %d", &netid);
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->state & STATE_E_DROP)
			continue;
		if (ifo->netid == netid) {
			ifo->state |= STATE_E_DROP;
			if (ifo->state & STATE_F_SSL)
				ssl_drop(ifo);
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
	if (ifo->state & STATE_F_SSL_WBLK)
		return 1;
	if (ifo->state & STATE_E_DROP && !(ifo->state & STATE_F_SSL_RBLK))
		return 1;
	if (ifo->state & STATE_F_SSL_HSHK)
		return 0;
	return ifo->sendq.end - ifo->sendq.start;
}

static inline int need_drop(struct sockifo* ifo) {
	if (!(ifo->state & STATE_E_DROP))
		return 0;
	if (ifo->state & STATE_E_SOCK)
		return 1;
	if (ifo->state & STATE_F_SSL)
		return !(ifo->state & (STATE_F_SSL_RBLK | STATE_F_SSL_WBLK));
	return ifo->sendq.end == ifo->sendq.start;
}

static void do_accept(int fd, char* line) {
	if (*line++ != ' ')
		exit(2);
	int netid = 0;
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

	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);

	struct sockifo* nifo = alloc_ifo();
	nifo->fd = fd;
	nifo->state = STATE_T_NETWORK;
	nifo->netid = netid;
	if (ssl_key && *ssl_key)
		ssl_init_server(nifo, ssl_key, ssl_cert, ssl_ca);
}

static void line_accept(char* line) {
	int netid = 0, i;
	char type = line[1];
	if (line[1] != 'A' && line[1] != 'D')
		exit(2);
	line += 2;

	if (*line++ != ' ')
		exit(2);
	while (isdigit(*line)) {
		netid = 10 * netid + (*line - '0');
		line++;
	}

	for(i=0; i < sockets->count; i++) {
		struct sockifo* lifo = &sockets->net[i];
		if (lifo->state & STATE_E_DROP)
			continue;
		if (lifo->netid == netid) {
			if (!(lifo->state & STATE_F_ACCEPTED))
				exit(3);
			int fd = lifo->ifo_newfd;
			lifo->state &= ~STATE_F_ACCEPTED;
			if (type == 'A') {
				do_accept(fd, line);
			} else {
				close(fd);
			}
			return;
		}
	}
	// TODO report error here
	exit(3);
}

static void sqfill(char* line) {
	int netid = 0;
	while (isdigit(*line)) {
		netid = 10 * netid + (*line - '0');
		line++;
	}
	line++;
	int i;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->state & STATE_E_DROP)
			continue;
		if (ifo->netid == netid) {
			q_puts(&ifo->sendq, line, 2);
			return;
		}
	}
	// TODO report error here
	exit(3);
}

static void mplex_parse(char* line) {
	switch (*line) {
	case '0' ... '9':
		sqfill(line);
		break;
	case 'I':
		addnet(line);
		break;
	case 'L':
		line_accept(line);
		break;
	case 'D':
		delnet(line);
		break;
	case 'S':
		io_stop = 1;
		break;
	case 'R':
		io_stop = 0;
		reboot(line);
		break;
	default:
		exit(2);
	}
}

static void readable(struct sockifo* ifo) {
	if (ifo->state & STATE_T_LISTEN) {
		if (ifo->state & STATE_F_ACCEPTED)
			return;
		struct sockaddr_in6 addr;
		unsigned int addrlen = sizeof(addr);
		char linebuf[8192];
		int fd = accept(ifo->fd, (struct sockaddr*)&addr, &addrlen);
		if (fd < 0)
			return;
		if (addr.sin6_family == AF_INET6) {
			inet_ntop(AF_INET6, &addr.sin6_addr, linebuf, sizeof(linebuf));
			char* atxt = linebuf;
			if (!strncmp("::ffff:", linebuf, 7))
				atxt += 7;
			qprintf(&sockets->net[0].sendq, "P %d %s\n", ifo->netid, atxt);
		} else {
			struct sockaddr_in* p = (struct sockaddr_in*)&addr;
			inet_ntop(AF_INET, &(p->sin_addr), linebuf, sizeof(linebuf));
			qprintf(&sockets->net[0].sendq, "P %d %s\n", ifo->netid, linebuf);
		}
		ifo->ifo_newfd = fd;
		ifo->state |= STATE_F_ACCEPTED;
		return;
	}
	if (ifo->state & STATE_F_SSL) {
		ssl_readable(ifo);
	} else {
		if (q_read(ifo->fd, &ifo->recvq)) {
			esock(ifo, strerror(errno));
		}
	}
	while (1) {
		char* line = q_gets(&ifo->recvq);
		if (!line)
			return;
		if (ifo->state & STATE_T_NETWORK && !(ifo->state & STATE_E_DROP)) {
			qprintf(&sockets->net[0].sendq, "%d %s\n", ifo->netid, line);
		} else if (ifo->state & STATE_T_MPLEX) {
			mplex_parse(line);
		}
	}
}

static void writable(struct sockifo* ifo) {
	if (ifo->state & STATE_F_CONNPEND) {
		ifo->state &= ~STATE_F_CONNPEND;
	}
	if (ifo->state & STATE_F_SSL) {
		ssl_writable(ifo);
	} else {
		if (q_write(ifo->fd, &ifo->sendq)) {
			esock(ifo, strerror(errno));
		}
	}
}

static void mplex() {
	struct timeval timeout = {
		.tv_sec = 1,
		.tv_usec = 0,
	};
	int i;
	int maxfd = 0;
	fd_set rok, wok;
	FD_ZERO(&rok);
	FD_ZERO(&wok);
	if (io_stop == 1) {
		io_stop = 2;
		q_puts(&sockets->net[0].sendq, "S", 1);
	}
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (need_write(ifo) && !(ifo->state & STATE_F_CONNPEND)) {
			writable(ifo);
		}
		if (need_drop(ifo)) {
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
		if (io_stop == 2)
			break;
	}
	int ready = select(maxfd + 1, &rok, &wok, NULL, &timeout);
	time_t now = time(NULL);
	if (now != last_ts && io_stop != 2) {
		qprintf(&sockets->net[0].sendq, "T %d\n", now);
		last_ts = now;
	}
	if (ready == 0)
		return;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (FD_ISSET(ifo->fd, &wok)) {
			writable(ifo);
		}
		if (FD_ISSET(ifo->fd, &rok)) {
			readable(ifo);
		}
		if (io_stop == 2)
			return;
	}
	q_puts(&sockets->net[0].sendq, "Q\n", 0);
}

int main(int argc, char** argv) {
	if (argc > 1)
		conffile = argv[1];
	else
		conffile = "janus.conf";

	struct sigaction ign = {
		.sa_handler = SIG_IGN,
	};
	sigaction(SIGPIPE, &ign, NULL);
	sigaction(SIGCHLD, &ign, NULL);
	close(0);
	close(1);
	close(2);

	sockets = malloc(sizeof(struct iostate) + 16 * sizeof(struct sockifo));
	sockets->size = 16;
	sockets->count = 1;
	sockets->net[0].state = STATE_T_MPLEX;

	init_worker();
	q_puts(&sockets->net[0].sendq, "BOOT 10\n", 0);

	ssl_gblinit();

	while (1)
		mplex();

	return 0;
}
