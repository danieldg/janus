CFLAGS = -g -Wall -O2 -std=c99 -D_XOPEN_SOURCE=600
LDLIBS = -lgnutls
multiplex: multiplex.o queue.o ssl.o

clean:
	$(RM) multiplex *.o
