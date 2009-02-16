# Copyright (C) 2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::Crypto;
use strict;
use warnings;
use integer;

sub salt {
	my $len = $_[0];
	my $h = $Janus::new_sha1->();
	$h->add(join '!', rand(), $Janus::time, $h, @_);
	substr $h->b64digest, 0, $len;
}

sub hmac {
	my($h, $p, $m) = @_;
	$p =~ s/(.)/chr(0x36 ^ ord $1)/eg;
	$h->add($p)->add($m);
	my $v = $h->digest;
	$p =~ s/(.)/chr(0x6A ^ ord $1)/eg; # HMAC spec says 5c = 6a^36
	$h->add($p)->add($v);
	$h;
}

sub hmac_ihex {
	my($h, $p, $m) = @_;
	$p =~ s/(.)/chr(0x36 ^ ord $1)/eg;
	$h->add($p)->add($m);
	my $v = $h->hexdigest;
	$p =~ s/(.)/chr(0x6A ^ ord $1)/eg; # HMAC spec says 5c = 6a^36
	$h->add($p)->add($v);
	$h->hexdigest;
}

sub hmacsha1 {
	my($pass, $salt) = @_;
	hmac($Janus::new_sha1->(), $salt, $pass)->b64digest;
}

1;
