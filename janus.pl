#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Janus;
use Channel;
use Nick;
use Network;
use Interface;
use Ban;

$| = 1;

Janus->modload(shift || 'janus.conf');
Channel->modload();
Nick->modload();
Network->modload();
Ban->modload();
Interface->modload('janus2');

Janus::rehash();
my $read = $Janus::read;

while ($read->count()) {
	my @r = $read->can_read();
	for my $l (@r) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		unless (defined $net) {
			# this is a listening socket; accept a new connection
			# TODO
			next;
		}
		my $len = sysread $sock, $recvq, 8192, length $recvq;
		while ($recvq =~ /[\r\n]/) {
			my $line;
			($line, $recvq) = split /[\r\n]+/, $recvq, 2;
			my @parsed = $net->parse($line);
			if ($net->isa('Network')) {
				Janus::in_local($net, @parsed);
			} else {
				Janus::in_janus($net, @parsed);
			}
		}
		$$l[1] = $recvq;
		if (!$len) {
			$read->remove($l);
			Janus::delink($net);
		}
	}

	for my $l ($read->handles()) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		next unless defined $net;
		$sendq .= $net->dump_sendq();
		# TODO nonblocking send
		while ($sendq) {
			my $crop = syswrite $sock, $sendq;
			warn unless $crop;
			$sendq = substr $sendq, $crop;
		}
		$$l[2] = $sendq;
	}
}
