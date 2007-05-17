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

# Core modules: these must be loaded for any functionality
Janus->modload(shift || 'janus.conf');
Nick->modload();
Channel->modload();
Network->modload();

# Extra modules: These add functionality, but janus should function without them
# Eventually, some may be able to be loaded and unloaded without needing to restart janus
Interface->modload('janus2');
Ban->modload();

&Janus::rehash();
my $read = $Janus::read;
my $write = IO::Select->new();

while ($read->count()) {
	my($r,$w,$e) = IO::Select->select($read, $write, undef, 1);
	for my $l (@$r) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		unless (defined $net) {
			# this is a listening socket; accept a new connection
			# TODO
			next;
		}
		my $len = $sock->sysread($recvq, 8192, length $recvq);
		while ($recvq =~ /\n/) {
			my $line;
			($line, $recvq) = split /[\r\n]+/, $recvq, 2;
			&Janus::in_socket($net, $line);
		}
		$$l[1] = $recvq;
		if (!$len) {
			if ($sock->isa('IO::Socket::SSL') && $sock->connected()) {
				print "SSL error: ".$sock->errstr()."\n";
				if ($sock->errstr() eq SSL_WANT_READ || $sock->errstr() eq SSL_WANT_WRITE) {
					$write->add($l);
					next;
				}
			} else {
				print "Delink from failed read\n";
			}
			$read->remove($l);
			$write->remove($l);
			&Janus::delink($net);
			$$l[3] = undef;
		}
	}

	&Janus::timer();

	for my $l ($read->handles()) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		next unless defined $net;
		$sendq .= $net->dump_sendq();
		$$l[2] = $sendq;
		$write->add($l) if $sendq;
	}
	
	# rather than using @$w and going around again to write, check all writable handles
	# since all are nonblocking, we just end up going around again if one is waiting
	for my $l ($write->handles()) {
		my ($sock, $recvq, $sendq, $net) = @$l;
		my $len = $sock->syswrite($sendq);
		if (defined $len) {
			$$l[2] = $sendq = substr $sendq, $len;
			$write->remove($l) unless $sendq;
		} else {
			if ($sock->isa('IO::Socket::SSL')) {
				print "SSL write error: ".$sock->errstr()."\n";
				if ($sock->errstr() eq SSL_WANT_READ || $sock->errstr() eq SSL_WANT_WRITE) {
					next;
				}
			}
			print "Delink from failed write\n";
			$read->remove($l);
			$write->remove($l);
			&Janus::delink($net);
			$$l[3] = undef;
		}
	}
}
print "All networks disconnected. Goodbye!\n";
