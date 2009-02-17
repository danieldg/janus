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
static pid_t worker_pid;

#define WORDSTRING(x) \
	const char* x = NULL; \
	if (*line == ' ') { \
		*line++ = '\0'; \
		x = line; \
		while (*line && *line != ' ') line++; \
	}

#define INTSTRING(x) \
	int x = 0; \
	if (*line == ' ') { \
		*line++ = '\0'; \
		while (isdigit(*line)) { \
			x = 10 * x + *line++ - '0'; \
		} \
	}

#define ENDSTRING() do { *line = '\0'; } while (0)

static void init_worker() {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
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
		int log = open("daemon.log", O_WRONLY| O_CREAT, 0666);
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
	if (ifo->fd == -1)
		return;
	close(ifo->fd);
	ifo->fd = -1;
	if (ifo->state.mplex_dropped)
		return;
	if (ifo->state.type == TYPE_MPLEX)
		exit(0);
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

static struct sockifo* find(int netid) {
	int i;
	if (netid <= 0)
		return NULL;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = sockets->net + i;
		if (ifo->state.mplex_dropped)
			continue;
		if (ifo->netid == netid)
			return ifo;
	}
	return NULL;
}

static void writable(struct sockifo* ifo) {
	if (ifo->state.connpend) {
		ifo->state.connpend = 0;
		int err = 0;
		socklen_t esize = sizeof(int);
		getsockopt(ifo->fd, SOL_SOCKET, SO_ERROR, &err, &esize);
		if (err) {
			esock(ifo, strerror(err));
			return;
		}
		ifo->state.poll = ifo->state.frozen ? POLL_HANG : POLL_NORMAL;
	}
#if SSL_ENABLED
	if (ifo->state.ssl) {
		ssl_writable(ifo);
	} else
#endif
	{
		int r = q_write(ifo->fd, &ifo->sendq);
		if (r) {
			esock(ifo, r == 1 ? "Connection closed" : strerror(errno));
		} else if (ifo->state.mplex_dropped && ifo->sendq.start == ifo->sendq.end) {
			close(ifo->fd);
			ifo->fd = -1;
		}
	}
}

static void addnet(char* line) {
	line++;
	char type = *line++;
	if (type != 'L' && type != 'C') exit(2);

	INTSTRING(netid);
	WORDSTRING(addr);
	WORDSTRING(port);
	WORDSTRING(bindto);
	INTSTRING(freeze);
	ENDSTRING();

	if (!addr || !*addr) {
		if (type == 'C')
			exit(2);
		addr = "::";
	}
	if (!netid || !port || !*port)
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
		ifo->state.type = TYPE_NETWORK;
		ifo->state.frozen = freeze;
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
		ifo->state.connpend = 1;
		ifo->state.poll = POLL_FORCE_WOK;
	} else if (type == 'L') {
		ifo->state.type = TYPE_LISTEN;
		ifo->state.poll = POLL_FORCE_ROK;
		ifo->ifo_newfd = -1;
		int optval = 1;
		setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, sizeof(int));
		if (bind(fd, ainfo->ai_addr, ainfo->ai_addrlen))
			goto out_err;
		if (listen(fd, 2))
			goto out_err;
	}

out_free:
	freeaddrinfo(ainfo);
	return;
out_err:
	esock(ifo, strerror(gai_err));
	goto out_free;
}

static void delnet_real(struct sockifo* ifo) {
#if SSL_ENABLED
	if (ifo->state.ssl)
		ssl_free(ifo);
#endif
	if (ifo->fd >= 0)
		close(ifo->fd);
	free(ifo->sendq.data);
	free(ifo->recvq.data);
	sockets->count--;
	struct sockifo* last = &(sockets->net[sockets->count]);
	if (ifo != last) {
		memcpy(ifo, last, sizeof(struct sockifo));
	}
}

static void delnet(char* line) {
	line++;
	INTSTRING(netid);
	struct sockifo* ifo = find(netid);

	if (!ifo)
		exit(2);
	ifo->state.mplex_dropped = 1;
	if (ifo->fd >= 0)
		qprintf(&sockets->net[0].sendq, "D %d Drop Requested\n", ifo->netid);

#if SSL_ENABLED
	if (ifo->state.ssl)
		ssl_drop(ifo);
	else
#endif
	{
		ifo->state.poll = POLL_FORCE_WOK;
		writable(ifo);
	}
}

static void freeze_net(char* line) {
	line++;
	INTSTRING(netid);
	INTSTRING(freeze);
	struct sockifo* ifo = find(netid);
	if (!ifo)
		exit(2);
	ifo->state.frozen = freeze;
	writable(ifo);
}

static void start_ssl(char* line) {
	char type = line[1];
	line += 2;
	INTSTRING(netid);

	struct sockifo* ifo = find(netid);
	if (!ifo) {
		exit(2);
	}

#if SSL_ENABLED
	WORDSTRING(ssl_key);
	WORDSTRING(ssl_cert);
	WORDSTRING(ssl_ca);
	ENDSTRING();

	ifo->state.frozen = 0;
	if (ifo->state.poll == POLL_HANG)
		ifo->state.poll = POLL_NORMAL;

	int server = (type == 'S');
	ssl_init(ifo, ssl_key, ssl_cert, ssl_ca, server);
#else
	esock(ifo, "SSL support not enabled");
#endif
}

static void line_accept(char* line) {
	char type = line[1];
	if (type != 'A' && type != 'D')
		exit(2);
	line += 2;

	INTSTRING(lnetid);

	struct sockifo* lifo = find(lnetid);

	if (!lifo || lifo->state.type != TYPE_LISTEN)
		exit(2);
	int fd = lifo->ifo_newfd;
	if (fd <= 0)
		exit(3);
	lifo->ifo_newfd = -1;
	lifo->state.poll = POLL_FORCE_ROK;
	if (type == 'D') {
		close(fd);
		return;
	}

	INTSTRING(nnetid);
	INTSTRING(freeze);

	if (!nnetid)
		exit(2);

	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);

	struct sockifo* nifo = alloc_ifo();
	nifo->fd = fd;
	nifo->netid = nnetid;
	nifo->state.type = TYPE_NETWORK;
	nifo->state.frozen = freeze;
	nifo->state.poll = freeze ? POLL_HANG : POLL_FORCE_ROK;
}



static void sqfill(char* line) {
	int netid = 0;
	while (isdigit(*line)) {
		netid = 10 * netid + *line++ - '0';
	}
	struct sockifo* ifo = find(netid);
	if (!ifo)
		exit(3);
	line++;
	q_puts(&ifo->sendq, line, 2);
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
	case 'F':
		freeze_net(line);
		break;
	case 'D':
		delnet(line);
		break;
	case 'S':
		start_ssl(line);
		break;
	case 'X':
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
	if (ifo->state.type == TYPE_LISTEN) {
		if (ifo->ifo_newfd >= 0) {
			ifo->state.poll = POLL_HANG;
			return;
		}
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
		ifo->state.poll = POLL_HANG;
		return;
	}
#if SSL_ENABLED
	if (ifo->state.ssl) {
		ssl_readable(ifo);
	}
	else
#endif
	{
		int r = q_read(ifo->fd, &ifo->recvq);
		if (r) {
			esock(ifo, r == 1 ? "Connection closed" : strerror(errno));
		}
	}
	while (1) {
		char* line = q_gets(&ifo->recvq);
		if (!line)
			return;
		if (ifo->state.type == TYPE_NETWORK && !ifo->state.mplex_dropped) {
			qprintf(&sockets->net[0].sendq, "%d %s\n", ifo->netid, line);
		} else if (ifo->state.type == TYPE_MPLEX) {
			mplex_parse(line);
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
	fd_set rok, wok, xok;
	FD_ZERO(&rok);
	FD_ZERO(&wok);
	FD_ZERO(&xok);
	if (io_stop == 1) {
		io_stop = 2;
		q_puts(&sockets->net[0].sendq, "X", 1);
	}
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->fd < 0) {
			if (ifo->state.mplex_dropped) {
				delnet_real(ifo);
				i--;
			}
			continue;
		}
		if (ifo->fd > maxfd)
			maxfd = ifo->fd;

		int need_read, need_write;
		switch (ifo->state.poll) {
		case POLL_NORMAL:
			if (ifo->sendq.start != ifo->sendq.end)
				writable(ifo);
			need_read = 1;
			need_write = (ifo->sendq.start != ifo->sendq.end);
			break;
		case POLL_FORCE_ROK:
			need_read = 1;
			need_write = 0;
			break;
		case POLL_FORCE_WOK:
			need_read = 0;
			need_write = 1;
			break;
		case POLL_HANG:
		default:
			need_read = 0;
			need_write = 0;
		}
		if (need_read)
			FD_SET(ifo->fd, &rok);
		if (need_write)
			FD_SET(ifo->fd, &wok);
		FD_SET(ifo->fd, &xok);
		if (io_stop == 2)
			break;
	}
	int ready = select(maxfd + 1, &rok, &wok, &xok, &timeout);
	time_t now = time(NULL);
	if (now != last_ts && io_stop != 2) {
		qprintf(&sockets->net[0].sendq, "T %d\n", now);
		last_ts = now;
	}
	if (ready <= 0)
		return;
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->fd < 0)
			continue;
		if (FD_ISSET(ifo->fd, &xok)) {
			esock(ifo, "Exception on socket");
			continue;
		}
		if (FD_ISSET(ifo->fd, &wok)) {
			writable(ifo);
			if (ifo->fd < 0)
				continue;
		}
		if (FD_ISSET(ifo->fd, &rok)) {
			readable(ifo);
		}
		if (io_stop == 2)
			return;
	}
	if (ready > 1 || !FD_ISSET(sockets->net[0].fd, &rok))
		q_puts(&sockets->net[0].sendq, "Q\n", 0);
}

static void sig2child(int sig) {
	kill(worker_pid, sig);
}

static void init() {
	struct sigaction sig = {
		.sa_handler = SIG_IGN,
	};
	sigaction(SIGPIPE, &sig, NULL);
	sigaction(SIGCHLD, &sig, NULL);

	sig.sa_handler = sig2child;
	sigaction(SIGHUP, &sig, NULL);
	sigaction(SIGUSR1, &sig, NULL);
	sigaction(SIGUSR2, &sig, NULL);

	close(0);
	close(1);
	close(2);

	sockets = malloc(sizeof(struct iostate) + 16 * sizeof(struct sockifo));
	sockets->size = 16;
	sockets->count = 1;
	sockets->net[0].state.type = TYPE_MPLEX;

	init_worker();
	q_puts(&sockets->net[0].sendq, "BOOT 12\n", 0);
	writable(&sockets->net[0]);

#if SSL_ENABLED
	ssl_gblinit();
#endif
}

int main(int argc, char** argv) {
	if (argc > 1)
		conffile = argv[1];
	else
		conffile = "janus.conf";

	init();

	while (1)
		mplex();
}
