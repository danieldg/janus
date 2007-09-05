#!/usr/bin/perl -w
# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
use strict;
BEGIN { push @INC, '.' }
use Janus;
use IO::Select;
use IO::Socket::SSL;
use POSIX 'setsid';

our $VERSION = '(S)v'.join '', '$Rev$' =~ /(\d+)/;

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
$SIG{PIPE} = 'IGNORE';

&Janus::load('Conffile', shift || 'janus.conf') or die;
&Janus::load($_) or die for qw(Interface Actions Commands::Core);

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

eval { 
  while (%Janus::netqueues) {
	my($r,$w,$e) = IO::Select->select(
			IO::Select->new(grep { $_->[4] } values %Janus::netqueues),
			IO::Select->new(grep { $_->[5] } values %Janus::netqueues),
			undef, 1
		);
	for my $l (@$w) {
		# We were waiting to be able to write, and are now able.
		# Reset they try_ flags to their normal state:
		# waking up when we are able to read, but not when we are able to write
		@$l[4,5] = (1,0);
		writable $l;
	}
	for my $l (@$r) {
		if (defined $$l[3]) {
			# normal network
			readable $l;
		} else {
			# this is a listening socket; accept a new connection
			my $lsock = $$l[0];
			my($sock,$peer) = $lsock->accept();
			if ($sock) {
				&Janus::in_newsock($sock, $peer);
			}
		}
	}

	&Janus::timer();

	for my $l (values %Janus::netqueues) {
		my ($sendq, $net) = @$l[2,3];
		next unless defined $net;
		$sendq .= $net->dump_sendq();
		$$l[2] = $sendq;

		writable $l if $sendq && !$$l[5];
		# no point in trying to write if we are already waiting for writes to unblock
	}
  }
  1;
} || do {
	print "Aborting, error=$@\n";
	for my $net (values %Janus::nets) {
		$net = $net->jlink() if $net->jlink();
		&Janus::delink($net, 'aborting');
	}
	%Janus::netqueues = ();
};

&Janus::delink($Janus::interface->homenet(), 'Goodbye!');
$Janus::interface = undef;
print "All networks disconnected. Goodbye!\n";
&Persist::list_all_refs();
