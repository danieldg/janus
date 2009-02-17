/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include "mplex.h"
#include <unistd.h>
// #include <gcrypt.h>
static gnutls_dh_params_t dh_params;

void ssl_gblinit() {
//	gcry_control(GCRYCTL_ENABLE_QUICK_RANDOM, 0);
	gnutls_global_init();
	gnutls_dh_params_init(&dh_params);
	gnutls_dh_params_generate2(dh_params, 1024);
}

static void do_eagain(struct sockifo* ifo) {
	if (gnutls_record_get_direction(ifo->ssl)) {
		ifo->state.poll = POLL_FORCE_WOK;
	} else {
		ifo->state.poll = POLL_FORCE_ROK;
	}
}

void ssl_free(struct sockifo* ifo) {
	gnutls_deinit(ifo->ssl);
	gnutls_certificate_free_credentials(ifo->xcred);
}

static void ssl_handshake(struct sockifo* ifo) {
	int rv = gnutls_handshake(ifo->ssl);
	if (rv == GNUTLS_E_SUCCESS) {
		ifo->state.poll = POLL_NORMAL;
		ifo->state.ssl = SSL_ACTIVE;
		// TODO verify remote cert against CA
	} else if (rv == GNUTLS_E_AGAIN || rv == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		esock(ifo, gnutls_strerror(rv));
	}
}

static void ssl_bye(struct sockifo* ifo) {
	int rv = gnutls_bye(ifo->ssl, GNUTLS_SHUT_RDWR);
	if (rv == GNUTLS_E_SUCCESS) {
		close(ifo->fd);
		ifo->fd = -1;
	} else if (rv == GNUTLS_E_AGAIN || rv == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		esock(ifo, gnutls_strerror(rv));
	}
}

void ssl_init(struct sockifo* ifo, const char* key, const char* cert, const char* ca, int server) {
	int rv;
	rv = gnutls_certificate_allocate_credentials(&ifo->xcred);
	if (rv < 0) goto out_err;
	if (cert && *cert) {
		rv = gnutls_certificate_set_x509_key_file(ifo->xcred, cert, key, GNUTLS_X509_FMT_PEM);
		if (rv < 0) goto out_err_cred;
	}
	if (ca && *ca) {
		rv = gnutls_certificate_set_x509_trust_file(ifo->xcred, ca, GNUTLS_X509_FMT_PEM);
		if (rv < 0) goto out_err_cred;
	}
	gnutls_certificate_set_dh_params(ifo->xcred, dh_params);
	rv = gnutls_init(&ifo->ssl, server ? GNUTLS_SERVER : GNUTLS_CLIENT);
	if (rv < 0) goto out_err_cred;
	rv = gnutls_set_default_priority(ifo->ssl);
	if (rv < 0) goto out_err_all;
	rv = gnutls_credentials_set(ifo->ssl, GNUTLS_CRD_CERTIFICATE, ifo->xcred);
	if (rv < 0) goto out_err_all;

	if (server) {
		gnutls_dh_set_prime_bits(ifo->ssl, 1024);
		gnutls_certificate_server_set_request(ifo->ssl, GNUTLS_CERT_REQUEST);
	}

	gnutls_transport_set_ptr(ifo->ssl, (gnutls_transport_ptr_t)(long) ifo->fd);

	ifo->state.ssl = SSL_HSHK;
	if (!ifo->state.connpend)
		ssl_handshake(ifo);
	return;

out_err_all:
	gnutls_deinit(ifo->ssl);
out_err_cred:
	gnutls_certificate_free_credentials(ifo->xcred);
out_err:
	esock(ifo, gnutls_strerror(rv));
}

void ssl_readable(struct sockifo* ifo) {
	if (ifo->state.ssl == SSL_HSHK)
		ssl_handshake(ifo);
	if (ifo->state.ssl == SSL_BYE)
		ssl_bye(ifo);
	if (ifo->state.ssl != SSL_ACTIVE)
		return;

	ifo->state.poll = POLL_NORMAL;

	int slack = q_bound(&ifo->recvq, MIN_QUEUE, IDEAL_QUEUE);
	int n = gnutls_record_recv(ifo->ssl, ifo->recvq.data + ifo->recvq.end, slack);
	if (n > 0) {
		ifo->recvq.end += n;
	} else if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		esock(ifo, n == 0 ? "Client closed connection" : gnutls_strerror(n));
	}
}

void ssl_writable(struct sockifo* ifo) {
	if (ifo->state.ssl == SSL_HSHK)
		ssl_handshake(ifo);
	if (ifo->state.ssl == SSL_BYE)
		ssl_bye(ifo);
	if (ifo->state.ssl != SSL_ACTIVE)
		return;

	int size = ifo->sendq.end - ifo->sendq.start;
	if (!size) {
		if (ifo->state.poll == POLL_FORCE_WOK) {
			int n = gnutls_record_send(ifo->ssl, NULL, 0);
			if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
				do_eagain(ifo);
			} else if (n < 0) {
				esock(ifo, gnutls_strerror(n));
			} else {
				ifo->state.poll = POLL_NORMAL;
			}
		}
		return;
	}
	int n = gnutls_record_send(ifo->ssl, ifo->sendq.data + ifo->sendq.start, size);
	if (n > 0) {
		ifo->sendq.start += n;
		if (size > n)
			ifo->state.poll = POLL_FORCE_WOK;
		else
			ifo->state.poll = POLL_NORMAL;
	} else if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo);
	} else {
		esock(ifo, n == 0 ? "Client closed connection" : gnutls_strerror(n));
	}
}

void ssl_drop(struct sockifo* ifo) {
	ifo->state.ssl = SSL_BYE;
	ssl_bye(ifo);
}
