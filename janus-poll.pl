#!/usr/bin/perl -w
# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
use strict;
BEGIN { push @INC, '.' }
use Janus;
use IO::Socket::SSL;
use POSIX 'setsid';
require 'syscall.ph';

our($VERSION) = '$Rev$' =~ /(\d+)/;

my $args = @ARGV && $ARGV[0] =~ /^-/ ? shift : '';
unless ($args =~ /d/) {
	my $log = 'log/'.time;
	umask 022;
	open STDIN, '/dev/null' or die $!;
	open STDOUT, '>', $log or die $!;
	open STDERR, '>&', \*STDOUT or die $!;
	my $pid = fork;
	die $! unless defined $pid;
	exit if $pid;
	setsid;
}

$| = 1;

&Janus::load($_) or die for qw(Interface Ban Actions);
&Janus::load('Conffile', shift || 'janus.conf') or die;

sub readable {
	my $l = shift;
	my ($sock, $recvq, $sendq) = @$l;
	my $len = $sock->sysread($recvq, 8192, length $recvq);
	if ($len) {
		while ($recvq =~ /\n/) {
			my $line;
			($line, $recvq) = split /[\r\n]+/, $recvq, 2;
			&Janus::in_socket($$l[3], $line);
		}
		$$l[1] = $recvq;
		$$l[4] = 1 if $$l[4]; #reset SSL error counter
	} else {
		my $net = $$l[3];
		if ($sock->isa('IO::Socket::SSL')) {
			print "SSL read error @".$net->id().": ".$sock->errstr()."\n";
			if ($sock->errstr() eq SSL_WANT_READ) {
				# we were trying to read, and want another read: act just like reading
				# half of a line, i.e. return and wait for the next incoming blob
				return unless $$l[4]++ > 10; 
				# However, if we have had more than 10 errors, assume something else is wrong
				# and bail out.
				print "Bailing out!\n";
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				# since are waiting for a write, we do NOT want to come back when reads
				# are available, at least not until we have unblocked a write.
				@$l[4,5] = (0,1);
				return;
			}
		} else {
			print 'Delink '.$net->id()." from failed read: $!\n";
		}
		&Janus::delink($net, 'Socket read failure ('.$!.')');
	}
}

sub writable {
	my $l = shift;
	my ($sock, $recvq, $sendq, $net) = @$l;
	my $len = $sock->syswrite($sendq);
	if (defined $len) {
		$$l[2] = substr $sendq, $len;
		# schedule a wakeup to write the rest if we were not able to write everything in the sendq
		$$l[5] = 1 if $len < length $sendq;
	} else {
		if ($sock->isa('IO::Socket::SSL')) {
			print "SSL write error @".$net->id().": ".$sock->errstr()."\n";
			if ($sock->errstr() eq SSL_WANT_READ) {
				@$l[4,5] = (1,0);
				return;
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				@$l[4,5] = (0,1);
				return;
			}
		} else {
			print "Delink from failed write: $!\n";
		}
		&Janus::delink($net, 'Socket write failure ('.$!.')');
	}
}

while (%Janus::netqueues) {
	my @keys = keys %Janus::netqueues;
	my @query = values %Janus::netqueues;
	my $selector = join '', map {
		my $v = ( $_->[4] ? 1 : 0 ) | ( $_->[5] ? 4 : 0);
		pack 'ISx2', fileno($_->[0]), $v;
	} @query;
	syscall &SYS_poll, $selector, scalar(@query), 1000;
	my @res = unpack '(a8)'.scalar(@query), $selector; 

	&Janus::timer();

	for (0..$#query) {
		my $l = $query[$_];
		my($q,$r) = unpack 'x4SS', $res[$_];
		if ($r & 0x38) {
			# POLLERR | POLLHUP | POLLNVAL
			delete $Janus::netqueues{$keys[$_]};
		} elsif (defined $$l[3]) {
			@$l[4,5] = (1,0) if $$l[5];
			readable $l if $r & 1;
			my ($sendq, $net) = @$l[2,3];
			$sendq .= $net->dump_sendq();
			$$l[2] = $sendq;
			writable $l if $sendq && ($q & 4) == ($r & 4);
		} else {
			# listening socket
			if ($r & 1) {
				# accept a new connection
				my($sock,$peer) = $l->[0]->accept();
				&Janus::in_newsock($sock, $peer) if $sock;
			}
		}
	}
}
print "All networks disconnected. Goodbye!\n";
