# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Connection;
use strict;
use warnings;
use integer;

use IO::Select;
use IO::Socket::SSL;
use Scalar::Util qw(tainted);
our($VERSION) = '$Rev$' =~ /(\d+)/;

our %queues;

my $tblank = ``;
print "WARNING: not running in taint mode\n" unless tainted($tblank);

sub add {
	my($sock, $net) = @_;
	my $q = [ $sock, $tblank, '', $net, 0, 1 ];
	if ($net->isa('Listener')) {
		@$q[1,2,4,5] = ($tblank, undef, 1, 0);
	}
	$queues{$$net} = $q;
}

sub reassign {
	my($old, $new) = @_;
	my $q = delete $queues{$$old};
	return unless $new;
	return warn unless $q;
	$q->[3] = $new;
	$queues{$$new} = $q;
}

sub readable {
	my $l = shift;
	my $net = $$l[3] or return;
	if ($net->isa('Listener')) {
		# this is a listening socket; accept a new connection
		my $lsock = $$l[0];
		my($sock,$peer) = $lsock->accept();
		return unless $sock;
		$net = $net->init_pending($sock, $peer);
		return unless $net;
		$queues{$$net} = [ $sock, $tblank, '', $net, 1, 0 ];
		return;
	}

	my ($sock, $recvq) = @$l;
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
		my $net = $$l[3] or return;
		if ($sock->isa('IO::Socket::SSL')) {
			print "SSL read error @#$$net: ".$sock->errstr()."\n";
			if ($sock->errstr() eq SSL_WANT_READ) {
				# we were trying to read, and want another read: act just like reading
				# half of a line, i.e. return and wait for the next incoming blob
				return unless $$l[4]++ > 30;
				# However, if we have had more than 30 errors, assume something else is wrong
				# and bail out.
				print "Bailing out!\n";
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				# since are waiting for a write, we do NOT want to come back when reads
				# are available, at least not until we have unblocked a write.
				@$l[4,5] = (0,1);
				return;
			}
		} else {
			print "Delink #$$net from failed read: $!\n";
		}
		&Janus::delink($net, 'Socket read failure ('.$!.')');
	}
}

sub _syswrite {
	my $l = shift;
	my ($sock, $recvq, $sendq, $net) = @$l;
	my $len = $sock->syswrite($sendq);
	if (defined $len) {
		$$l[2] = substr $sendq, $len;
		# schedule a wakeup to write the rest if we were not able to write everything in the sendq
		$$l[5] = 1 if $len < length $sendq;
	} else {
		if ($sock->isa('IO::Socket::SSL')) {
			print "SSL write error @#$$net: ".$sock->errstr()."\n";
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

sub writable {
	my $l = $_[0];
	@$l[4,5] = (1,0);
	&_syswrite;
}

sub run_sendq {
	my $l = $_[0];
	my ($sendq, $net) = @$l[2,3];
	return unless defined $net;
	eval {
		$sendq .= $net->dump_sendq();
		1;
	} or &Janus::err_jmsg(undef, "dump_sendq on #$$net died: $@");
	$$l[2] = $sendq;
	return if $$l[5] || !$sendq;
	# no point in trying to write if we are already waiting for writes to unblock
	&_syswrite;
}

sub timestep {
	my($r,$w,$e) = IO::Select->select(
			IO::Select->new(grep { $_->[4] } values %queues),
			IO::Select->new(grep { $_->[5] } values %queues),
			undef, 1
		);
	writable $_ for @$w;
	readable $_ for @$r;

	&Janus::timer();

	run_sendq $_ for values %queues;

	%queues ? 1 : 0;
}

sub _cleanup {
	my $act = shift;
	my $net = $act->{net};
	my $q = delete $queues{$$net};
	return if $net->jlink();
	return warn "Queue for network $$net was already removed" unless $q;
	$q->[0] = $q->[3] = undef; # fail-fast on remaining references
}

&Janus::hook_add(
	NETSPLIT => act => \&_cleanup,
	JNETSPLIT => act => \&_cleanup,
	TERMINATE => cleanup => sub {
		print "Queues remain at termination: ".join(' ', keys %queues)."\n" if %queues;
		%queues = ();
	},
);

1;
