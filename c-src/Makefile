CFLAGS = -g -Wall -O2 -std=c99 -D_XOPEN_SOURCE=600 -DSSL_GNUTLS=1
LDLIBS = -lgnutls
multiplex: multiplex.o queue.o ssl-gnutls.o

clean:
	$(RM) multiplex *.o
