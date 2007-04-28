#!/usr/bin/perl -w
use strict;
BEGIN { push @INC, '.' }
use Janus;
use Channel;
use Nick;
use Network;
use Interface;
use Ban;
use IO::Socket::SSL;

$| = 1;

Janus->modload(shift || 'janus.conf');
Channel->modload();
Nick->modload();
Network->modload();
Ban->modload();
Interface->modload('janus2');

Janus::rehash();
my $read = $Janus::read;
my $write = IO::Select->new();

while ($read->count()) {
	my($r,$w,$e) = IO::Select->select($read, $write, undef, undef);
	for my $l (@$r) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		unless (defined $net) {
			# this is a listening socket; accept a new connection
			# TODO
			next;
		}
		my $len = $sock->sysread($recvq, 8192, length $recvq);
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
			if ($sock->isa('IO::Socket::SSL')) {
				print "SSL error: ".$sock->errstr()."\n";
				if ($sock->errstr() eq SSL_WANT_READ || $sock->errstr() eq SSL_WANT_WRITE) {
					$write->add($l);
					next;
				}
			}
			$read->remove($l);
			&Janus::delink($net);
			$$l[3] = undef;
		}
	}

	for my $l ($read->handles()) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		next unless defined $net;
		$sendq .= $net->dump_sendq();
		$$l[2] = $sendq;
		$write->add($l) if $sendq;
	}
	
	# rather than using @$w and going around again to write, poll the write status
	# of all handles to find ones that are writable
	for my $l ($write->can_write(0)) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		my $len = $sock->syswrite($sendq);
		if (defined $len) {
			$$l[2] = $sendq = substr $sendq, $len;
			$write->remove($l) unless $sendq;
		} else {
			$read->remove($l);
			$write->remove($l);
			&Janus::delink($net);
			$$l[3] = undef;
		}
	}
}
print "All networks disconnected. Goodbye!\n";
