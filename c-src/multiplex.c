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
static time_t now;
static struct iostate* sockets;
static pid_t worker_pid;

#define die(x, ...) do { \
	fprintf(stderr, x "\n", ##__VA_ARGS__); \
	exit(1); \
} while (0)

static void init_worker() {
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) {
		die("socketpair: %s", strerror(errno));
	}
	worker_pid = fork();
	if (worker_pid < 0) {
		die("fork: %s", strerror(errno));
	}
	if (worker_pid == 0) {
		close(sv[0]);
		dup2(sv[1], 0);
		if (sv[1])
			close(sv[1]);
		dup2(2, 1);
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

static void reboot(struct line line) {
	line.data++; line.len--;
	close(sockets->net[0].fd);
	init_worker();
	q_puts(&sockets->net[0].sendq, "RESTORE");
	q_putl(&sockets->net[0].sendq, line, 1);
}

void esock(struct sockifo* ifo, const char* msg) {
	if (ifo->fd == -1)
		return;
	close(ifo->fd);
	ifo->fd = -1;
	if (ifo->state.mplex_dropped)
		return;
	if (ifo->state.type == TYPE_MPLEX)
		die("Multiplex socket closed: %s", msg);
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

static void addnet(struct line line) {
	struct {
		const char* type;
		int netid;
		const char* addr;
		const char* port;
		const char* bindto;
		int freeze;
	} __attribute__((__packed__)) args;
	sscan(line, "sisssi", &args);
	char type = args.type[1];
	if (type != 'L' && type != 'C')
		die("Protocol violation: no type %c in addnet", type);

	if (!args.addr || !*args.addr) {
		if (type == 'C')
			die("Protocol violation: no address to connect to");
		args.addr = "::";
	}
	if (!args.netid)
		die("Protocol violation: no netid in addnet");
	if (!*args.port)
		die("Protocol violation: no port in addnet");

	struct sockifo* ifo = alloc_ifo();
	ifo->fd = -1;
	ifo->netid = args.netid;

	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
		.ai_flags = (type == 'C' ? AI_ADDRCONFIG : AI_PASSIVE | AI_ADDRCONFIG),
	};
	struct addrinfo* ainfo = NULL;
	int gai_err = getaddrinfo(args.addr, args.port, &hints, &ainfo);
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
		ifo->state.frozen = args.freeze;
		if (*args.bindto) {
			if (ainfo->ai_family == AF_INET6) {
				struct sockaddr_in6 bsa = {
					.sin6_family = AF_INET6,
					.sin6_port = 0,
				};
				inet_pton(AF_INET6, args.bindto, &bsa.sin6_addr);
				if (bind(fd, (struct sockaddr*)&bsa, sizeof(bsa)))
					goto out_err;
			} else {
				struct sockaddr_in bsa = {
					.sin_family = AF_INET,
					.sin_port = 0,
				};
				inet_pton(AF_INET, args.bindto, &bsa.sin_addr);
				if (bind(fd, (struct sockaddr*)&bsa, sizeof(bsa)))
					goto out_err;
			}
		}
		connect(fd, ainfo->ai_addr, ainfo->ai_addrlen);
		ifo->state.connpend = 1;
		ifo->state.poll = POLL_FORCE_WOK;
		ifo->death_time = now + TIMEOUT;
	} else {
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
	esock(ifo, strerror(errno));
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

static void delnet(struct line line) {
	struct {
		int netid;
	} __attribute__((__packed__)) args;
	sscan(line, "-i", &args);

	struct sockifo* ifo = find(args.netid);

	if (!ifo)
		die("Cannot find network %d in delnet", args.netid);
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

static void freeze_net(struct line line) {
	struct {
		int netid;
		int freeze;
	} __attribute__((__packed__)) args;
	sscan(line, "-ii", &args);
	struct sockifo* ifo = find(args.netid);
	if (!ifo)
		die("Cannot find network %d in freeze_net", args.netid);
	ifo->state.frozen = args.freeze;
	writable(ifo);
	ifo->state.poll = POLL_HANG;
}

static void start_ssl(struct line line) {
	struct {
		const char* type;
		int netid;
		const char* ssl_key;
		const char* ssl_cert;
		const char* ssl_ca;
	} __attribute__((__packed__)) args;
	sscan(line, "sisss", &args);

	struct sockifo* ifo = find(args.netid);
	if (!ifo)
		die("Cannot find network %d in start_ssl", args.netid);

#if SSL_ENABLED
	ifo->state.frozen = 0;
	if (ifo->state.poll == POLL_HANG)
		ifo->state.poll = POLL_NORMAL;

	int server = (args.type[1] == 'S');
	ssl_init(ifo, args.ssl_key, args.ssl_cert, args.ssl_ca, server);
#else
	esock(ifo, "SSL support not enabled");
#endif
}

static void line_accept(struct line line) {
	struct {
		const char* type;
		int lnetid;
		int nnetid;
		int freeze;
	} __attribute__((__packed__)) args;
	sscan(line, "siii", &args);
	char type = args.type[1];
	if (type != 'A' && type != 'D')
		die("Unknown type %c in line_accept", type);

	struct sockifo* lifo = find(args.lnetid);

	if (!lifo || lifo->state.type != TYPE_LISTEN)
		die("Network %d not found or not a listener", args.lnetid);
	int fd = lifo->ifo_newfd;
	if (fd <= 0)
		die("Network %d does not have an FD ready", args.lnetid);
	lifo->ifo_newfd = -1;
	lifo->state.poll = POLL_FORCE_ROK;
	if (type == 'D') {
		close(fd);
		return;
	}
	if (!args.nnetid)
		die("No new network ID in listen accept");

	int flags = fcntl(fd, F_GETFL);
	flags |= O_NONBLOCK;
	fcntl(fd, F_SETFL, flags);
	fcntl(fd, F_SETFD, FD_CLOEXEC);

	struct sockifo* nifo = alloc_ifo();
	nifo->fd = fd;
	nifo->netid = args.nnetid;
	nifo->state.type = TYPE_NETWORK;
	nifo->state.frozen = args.freeze;
	nifo->state.poll = args.freeze ? POLL_HANG : POLL_NORMAL;
	nifo->death_time = now + TIMEOUT;
}

static void sqfill(struct line line) {
	struct {
		int netid;
		struct line data;
	} __attribute__((__packed__)) args;
	sscan(line, "il", &args);
	struct sockifo* ifo = find(args.netid);
	if (!ifo)
		die("Cannot find network %d in sqfill", args.netid);
	q_putl(&ifo->sendq, args.data, 2);
}

static void mplex_parse(struct line line) {
	switch (*line.data) {
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
		die("Protocol violation: %s", line.data);
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
		char linebuf[100];
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
	if (ifo->state.poll == POLL_FORCE_ROK) {
		ifo->state.poll = POLL_NORMAL;
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
		struct line line = q_getl(&ifo->recvq);
		if (!line.data)
			break;
		if (ifo->state.type == TYPE_NETWORK && !ifo->state.mplex_dropped) {
			qprintf(&sockets->net[0].sendq, "%d ", ifo->netid);
			q_putl(&sockets->net[0].sendq, line, 1);
			ifo->death_time = now + TIMEOUT;
		} else if (ifo->state.type == TYPE_MPLEX) {
			mplex_parse(line);
		}
	}
	// prevent memory DoS by sending infinite text without \n
	if (ifo->recvq.end - ifo->recvq.start > IDEAL_QUEUE) {
		esock(ifo, "Line too long");
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
		q_puts(&sockets->net[0].sendq, "X\n");
	}
	for(i=0; i < sockets->count; i++) {
		struct sockifo* ifo = &sockets->net[i];
		if (ifo->death_time && ifo->death_time < now) {
			esock(ifo, "Ping Timeout");
		}
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
			writable(ifo);
			need_read = 1;
			need_write = (ifo->sendq.start != ifo->sendq.end);
			break;
		case POLL_FORCE_ROK:
			writable(ifo);
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
		if (ifo->fd < 0)
			continue;
		if (need_read)
			FD_SET(ifo->fd, &rok);
		if (need_write)
			FD_SET(ifo->fd, &wok);
		FD_SET(ifo->fd, &xok);
		if (io_stop == 2)
			break;
	}
	int ready = select(maxfd + 1, &rok, &wok, &xok, &timeout);
	time_t new_ts = time(NULL);
	if (now != new_ts && io_stop != 2) {
		now = new_ts;
		qprintf(&sockets->net[0].sendq, "T %d\n", now);
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
		q_puts(&sockets->net[0].sendq, "Q\n");
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

	fclose(stdin);
	fclose(stdout);

	sockets = malloc(sizeof(struct iostate) + 16 * sizeof(struct sockifo));
	sockets->size = 16;
	sockets->count = 1;
	sockets->net[0].state.type = TYPE_MPLEX;

	init_worker();
	q_puts(&sockets->net[0].sendq, "BOOT 12\n");
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
