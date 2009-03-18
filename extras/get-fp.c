/*
 * Copyright (C) 2009 Daniel De Graaf
 * Released under the GNU Affero General Public License v3
 */
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <gnutls/gnutls.h>
#include <unistd.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <sys/socket.h>

const char hex[16] = "0123456789abcdef";

int main(int argc, char** argv) {
	if (argc < 3) {
		printf("Use: %s host port\n", argv[0]);
		return 0;
	}
	gnutls_global_init();
	gnutls_certificate_credentials_t xcred;
	int rv = gnutls_certificate_allocate_credentials(&xcred);
	if (rv < 0) goto out_err;
	struct addrinfo hints = {
		.ai_family = AF_UNSPEC,
		.ai_socktype = SOCK_STREAM,
		.ai_flags = AI_ADDRCONFIG,
	};
	struct addrinfo* ainfo = NULL;
	int gai_err = getaddrinfo(argv[1], argv[2], &hints, &ainfo);
	if (gai_err) {
		printf("Error connecting: %s", gai_strerror(gai_err));
		return 1;
	}
	int fd = socket(ainfo->ai_family, ainfo->ai_socktype, ainfo->ai_protocol);
	connect(fd, ainfo->ai_addr, ainfo->ai_addrlen);
	gnutls_session_t ssl;
	rv = gnutls_init(&ssl, GNUTLS_CLIENT);
	if (rv < 0) goto out_err;
	rv = gnutls_set_default_priority(ssl);
	if (rv < 0) goto out_err;
	rv = gnutls_credentials_set(ssl, GNUTLS_CRD_CERTIFICATE, xcred);
	if (rv < 0) goto out_err;
	gnutls_transport_set_ptr(ssl, (gnutls_transport_ptr_t)(long)fd);

	rv = gnutls_handshake(ssl);
	if (rv < 0) goto out_err;

	unsigned int i;
	uint8_t result[41];
	size_t resultsiz = 20;
	const gnutls_datum_t* cert = gnutls_certificate_get_peers(ssl, &i);
	if (i < 1) {
		printf("No certificate to fingerprint\n");
		return;
	}
	rv = gnutls_fingerprint(GNUTLS_DIG_SHA1, cert, result + 20, &resultsiz);
	if (rv < 0)
		goto out_err;
	for(i=0; i < 20; i++) {
		uint8_t v = result[20+i];
		result[2*i  ] = hex[v / 16];
		result[2*i+1] = hex[v % 16];
	}
	result[40] = 0;
	printf("Fingerprint for %s port %s is %s\n", argv[1], argv[2], result);
	return 0;
out_err:
	printf("GnuTLS error: %s\n", gnutls_strerror(rv));
	return 1;
}
