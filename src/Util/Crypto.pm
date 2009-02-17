# Copyright (C) 2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::Crypto;
use strict;
use warnings;
use integer;

sub salt {
	my $len = $_[0];
	$Janus::sha1->add(join '!', rand(), $Janus::time, $Janus::global, @_);
	substr $Janus::sha1->b64digest, 0, $len;
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

sub hmac_inspircd11_style {
	my($h, $p, $m) = @_;
	$p =~ s/(.)/chr(0x36 ^ ord $1)/eg;
	$p .= $m;
	$p =~ s/\x00.*//s;
	$h->add($p);
	my $v = $h->hexdigest;
	$p = $_[1];
	$p =~ s/(.)/chr(0x5C ^ ord $1)/eg;
	$p .= $v;
	$p =~ s/\x00.*//;
	$h->add($p);
	$h->hexdigest;
}

sub hmac_inspircd12_style {
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
	hmac($Janus::sha1, $salt, $pass)->b64digest;
}

1;
