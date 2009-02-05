all: multiplex

CFLAGS := -g -Wall -O2 -std=c99 -D_XOPEN_SOURCE=600
OFILES := multiplex.o queue.o
ifndef SSL
 SSL := "gnutls"
endif
ifeq ($(SSL),"gnutls")
  CFLAGS += -DSSL_GNUTLS=1 `libgnutls-config --cflags`
  LDLIBS += `libgnutls-config --libs`
  OFILES += ssl-gnutls.o
endif

multiplex: $(OFILES)

clean:
	$(RM) multiplex $(OFILES)
