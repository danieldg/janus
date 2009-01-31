/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include "mplex.h"
#include <stdio.h>

void ssl_gblinit() {
	gnutls_global_init();
}

static void do_eagain(struct sockifo* ifo) {
	if (gnutls_record_get_direction(ifo->ssl)) {
		ifo->state = (ifo->state & ~STATE_F_SSL_RBLK) | STATE_F_SSL_WBLK;
	} else {
		ifo->state = (ifo->state & ~STATE_F_SSL_WBLK) | STATE_F_SSL_RBLK;
	}
}

static void ssl_handshake(struct sockifo* ifo) {
	int rv = gnutls_handshake(ifo->ssl);
	if (rv == GNUTLS_E_SUCCESS) {
		ifo->state |= STATE_F_SSL_OK | STATE_F_SSL_RBLK;
		// TODO verify remote cert against CA
	} else if (rv == GNUTLS_E_AGAIN || rv == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		ifo->state |= STATE_E_SOCK;
		ifo->msg = gnutls_strerror(rv);
	}
}

void ssl_init_client(struct sockifo* ifo, const char* key, const char* cert, const char* ca) {
	ifo->state |= STATE_F_SSL;
	gnutls_certificate_allocate_credentials(&ifo->xcred);
	if (cert && *cert)
		gnutls_certificate_set_x509_key_file(ifo->xcred, cert, key, GNUTLS_X509_FMT_PEM);
	if (ca && *ca)
		gnutls_certificate_set_x509_trust_file(ifo->xcred, ca, GNUTLS_X509_FMT_PEM);
	gnutls_init(&ifo->ssl, GNUTLS_CLIENT);
	gnutls_set_default_priority(ifo->ssl);
	gnutls_credentials_set(ifo->ssl, GNUTLS_CRD_CERTIFICATE, ifo->xcred);

	gnutls_transport_set_ptr(ifo->ssl, (gnutls_transport_ptr_t)(long) ifo->fd);
	// NOTE: no handshake here because the connection is still pending
}

void ssl_close(struct sockifo* ifo) {
	// TODO the SSL protocol would really like to handshake the "bye"
	gnutls_bye(ifo->ssl, GNUTLS_SHUT_RDWR);
	gnutls_certificate_free_credentials(ifo->xcred);
	gnutls_deinit(ifo->ssl);
}

void ssl_readable(struct sockifo* ifo) {
	if (!(ifo->state & STATE_F_SSL_OK))
		ssl_handshake(ifo);
	if (!(ifo->state & STATE_F_SSL_OK))
		return;

	q_bound(&ifo->recvq, MIN_RECVQ, IDEAL_RECVQ, IDEAL_RECVQ);
	int n = gnutls_record_recv(ifo->ssl, ifo->recvq.data + ifo->recvq.end,
		ifo->recvq.size - ifo->recvq.end);
	if (n > 0) {
		ifo->recvq.end += n;
	} else if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		ifo->state |= STATE_E_SOCK;
		if (n == 0)
			ifo->msg = "Client closed connection";
		else
			ifo->msg = gnutls_strerror(n);
	}
}

void ssl_writable(struct sockifo* ifo) {
	if (!(ifo->state & STATE_F_SSL_OK))
		ssl_handshake(ifo);
	if (!(ifo->state & STATE_F_SSL_OK))
		return;

	int size = ifo->sendq.end - ifo->sendq.start;
	if (!size)
		return;
	int n = gnutls_record_send(ifo->ssl, ifo->sendq.data + ifo->sendq.start, size);
	if (n > 0) {
		ifo->sendq.start += n;
		if (size > n)
			ifo->state |= STATE_F_SSL_WBLK;
		else
			ifo->state &= ~STATE_F_SSL_WBLK;
	} else if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		ifo->state |= STATE_E_SOCK;
		if (n == 0)
			ifo->msg = "Client closed connection";
		else
			ifo->msg = gnutls_strerror(n);
	}
}
