/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include "mplex.h"
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
// #include <gcrypt.h>
static gnutls_dh_params_t dh_params;
static char errbuf[200];

void ssl_gblinit() {
//	gcry_control(GCRYCTL_ENABLE_QUICK_RANDOM, 0);
	gnutls_global_init();
	gnutls_dh_params_init(&dh_params);
	gnutls_dh_params_generate2(dh_params, 1024);
}

static void do_eagain(struct sockifo* ifo, int strict) {
	if (gnutls_record_get_direction(ifo->ssl)) {
		ifo->state.poll = POLL_FORCE_WOK;
	} else {
		ifo->state.poll = strict ? POLL_FORCE_ROK : POLL_NORMAL;
	}
}

void ssl_free(struct sockifo* ifo) {
	gnutls_deinit(ifo->ssl);
	gnutls_certificate_free_credentials(ifo->xcred);
	if (ifo->fingerprint)
		free(ifo->fingerprint);
}

static void ssl_vfy_ca(struct sockifo* ifo) {
	unsigned int status = 0;
	if (gnutls_certificate_verify_peers2(ifo->ssl, &status)) {
		esock(ifo, "Error in peer verification");
	} else if (status & GNUTLS_CERT_INVALID) {
		esock(ifo, "Certificate Invalid");
	} else if (status & GNUTLS_CERT_SIGNER_NOT_FOUND) {
		esock(ifo, "Certificate Signer not found");
	} else if (status) {
		esock(ifo, "Other certificate verification error");
	}
}

const char hex[16] = "0123456789abcdef";

static void ssl_vfy_fp(struct sockifo* ifo) {
	unsigned int i;
	uint8_t result[41];
	size_t resultsiz = 20;
	if (!ifo->fingerprint) {
		esock(ifo, "No fingerprint given");
		return;
	}
	const gnutls_datum_t* cert = gnutls_certificate_get_peers(ifo->ssl, &i);
	if (i < 1) {
		esock(ifo, "No certificate given to fingerprint");
		return;
	}
	int rv = gnutls_fingerprint(GNUTLS_DIG_SHA1, cert, result + 20, &resultsiz);
	if (rv) {
		esock(ifo, gnutls_strerror(rv));
		return;
	}
	for(i=0; i < 20; i++) {
		uint8_t v = result[20+i];
		result[2*i  ] = hex[v / 16];
		result[2*i+1] = hex[v % 16];
	}
	result[40] = 0;
	char* fp = ifo->fingerprint - 1;
	while (fp) {
		if (!memcmp(result, fp + 1, 40)) {
			free(ifo->fingerprint);
			ifo->fingerprint = NULL;
			return;
		}
		fp = strchr(fp + 1, ',');
	}
	snprintf(errbuf, sizeof(errbuf), "SSL fingerprint error: got %s expected %s", result, ifo->fingerprint);
	esock(ifo, errbuf);
}

static void ssl_handshake(struct sockifo* ifo) {
	int rv = gnutls_handshake(ifo->ssl);
	if (rv == GNUTLS_E_SUCCESS) {
		ifo->state.poll = POLL_NORMAL;
		ifo->state.ssl = SSL_ACTIVE;
		if (ifo->state.ssl_verify_type == VERIFY_CA) {
			ssl_vfy_ca(ifo);
		} else if (ifo->state.ssl_verify_type == VERIFY_FP) {
			ssl_vfy_fp(ifo);
		}
	} else if (rv == GNUTLS_E_AGAIN || rv == GNUTLS_E_INTERRUPTED) {
		do_eagain(ifo, 1);
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
		do_eagain(ifo, 1);
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
		if (!access(ca, R_OK)) {
			ifo->state.ssl_verify_type = VERIFY_CA;
			rv = gnutls_certificate_set_x509_trust_file(ifo->xcred, ca, GNUTLS_X509_FMT_PEM);
			if (rv < 0) goto out_err_cred;
		} else {
			ifo->state.ssl_verify_type = VERIFY_FP;
			ifo->fingerprint = strdup(ca);
		}
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
	if (ifo->fingerprint)
		free(ifo->fingerprint);
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

	int slack = q_bound(&ifo->recvq, MIN_QUEUE);
	while (slack > 1024) {
		int n = gnutls_record_recv(ifo->ssl, ifo->recvq.data + ifo->recvq.end, slack);
		if (n > 0) {
			ifo->recvq.end += n;
			slack = ifo->recvq.size - ifo->recvq.end;
		} else if (n == GNUTLS_E_AGAIN || n == GNUTLS_E_INTERRUPTED) {
			do_eagain(ifo, 0);
			return;
		} else {
			esock(ifo, n == 0 ? "Client closed connection" : gnutls_strerror(n));
			return;
		}
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
				do_eagain(ifo, 0);
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
		do_eagain(ifo, 0);
	} else {
		esock(ifo, n == 0 ? "Client closed connection" : gnutls_strerror(n));
	}
}

void ssl_drop(struct sockifo* ifo) {
	ifo->state.ssl = SSL_BYE;
	ssl_bye(ifo);
}
