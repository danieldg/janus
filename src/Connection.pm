# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Connection;
use strict;
use warnings;
use integer;
use Debug;
use IO::Socket::SSL;
use Scalar::Util qw(tainted);
use constant {
	FD => 0,
	SOCK => 1,
	NET => 2,
	RECVQ => 3,
	SENDQ => 4,
	TRY_R => 5,
	TRY_W => 6,
	PINGT => 7,
};

our @queues;
# net number => [ fd, IO::Socket, net, recvq, sendq, try_recv, try_send, ping ]
our $lping;
$lping ||= 100;
our $timeres;
$timeres ||= 1;

our $tblank;
unless (defined $tblank) {
	$tblank = ``;
	print "WARNING: not running in taint mode\n" unless tainted($tblank);
}

sub add {
	my($sock, $net) = @_;
	my $fn = fileno $sock;
	warn "Cannot find fileno for $sock" unless defined $fn;
	my $q = [ $fn, $sock, $net, $tblank, '', 0, 1, $Janus::time ];
	if ($net->isa('Listener')) {
		@$q[RECVQ,SENDQ,TRY_R,TRY_W] = ($tblank, undef, 1, 0);
		warn "Subclassing Listener is a dumb idea" unless ref $net eq 'Listener';
	}
	push @queues, $q;
}

sub reassign {
	my($old, $new) = @_;
	my $q;
	for (0..$#queues) {
		next unless $queues[$_][NET] == $old;
		$q = $queues[$_];
		splice @queues, $_, 1;
		last;
	}
	return $q unless $new;
	return warn unless $q;
	$$q[NET] = $new;
	push @queues, $q;
}

sub readable {
	my $l = shift;
	my $net = $$l[NET] or return;
	if (ref $net eq 'Listener') {
		# this is a listening socket; accept a new connection
		my $lsock = $$l[SOCK];
		my($sock,$peer) = $lsock->accept();
		my $fd = fileno $sock;
		return unless $sock && defined $fd;
		$net = $net->init_pending($sock, $peer);
		return unless $net;
		push @queues, [ $fd, $sock, $net, $tblank, '', 1, 0, $Janus::time ];
		return;
	}

	my ($sock, $recvq) = @$l[SOCK,RECVQ];
	my $len = $sock->sysread($recvq, 8192, length $recvq);
	if ($len) {
		while ($recvq =~ /\n/) {
			my $line;
			($line, $recvq) = split /[\r\n]+/, $recvq, 2;
			&Janus::in_socket($$l[NET], $line);
		}
		$$l[RECVQ] = $recvq;
		$$l[TRY_R] = 1 if $$l[TRY_R]; #reset SSL error counter
		$$l[PINGT] = $Janus::time;
	} else {
		my $net = $$l[NET] or return;
		if ($sock->isa('IO::Socket::SSL')) {
			&Debug::warn_in($net, "SSL read error: ".$sock->errstr());
			if ($sock->errstr() eq SSL_WANT_READ) {
				# we were trying to read, and want another read: act just like reading
				# half of a line, i.e. return and wait for the next incoming blob
				return unless $$l[TRY_R]++ > 30;
				# However, if we have had more than 30 errors, assume something else is wrong
				# and bail out.
				&Debug::info("Bailing out!");
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				# since are waiting for a write, we do NOT want to come back when reads
				# are available, at least not until we have unblocked a write.
				@$l[TRY_R, TRY_W] = (0,1);
				return;
			}
		} else {
			&Debug::err_in($net, "Delink from failed read: $!");
		}
		&Janus::delink($net, 'Socket read failure ('.$!.')');
	}
}

sub _syswrite {
	my $l = shift;
	my ($sock, $sendq, $net) = @$l[SOCK, SENDQ, NET];
	my $len = $sock->syswrite($sendq);
	if (defined $len) {
		$$l[SENDQ] = substr $sendq, $len;
		# schedule a wakeup to write the rest if we were not able to write everything in the sendq
		$$l[TRY_W] = 1 if $len < length $sendq;
	} else {
		if ($sock->isa('IO::Socket::SSL')) {
			&Debug::warn_in($net, "SSL write error: ".$sock->errstr());
			if ($sock->errstr() eq SSL_WANT_READ) {
				@$l[TRY_R,TRY_W] = (1,0);
				return;
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				@$l[TRY_R,TRY_W] = (0,1);
				return;
			}
		} else {
			&Debug::err_in($net, "Delink from failed write: $!");
		}
		&Janus::delink($net, 'Socket write failure ('.$!.')');
	}
}

sub writable {
	my $l = $_[0];
	@$l[TRY_R,TRY_W] = (1,0);
	&_syswrite;
}

sub run_sendq {
	my $l = $_[0];
	my ($sendq, $net) = @$l[SENDQ,NET];
	return unless defined $net;
	eval {
		$sendq .= $net->dump_sendq();
		1;
	} or &Debug::err_in($net, "dump_sendq died: $@");
	$$l[SENDQ] = $sendq;
	return if $$l[TRY_W] || !$sendq;
	# no point in trying to write if we are already waiting for writes to unblock
	&_syswrite;
}

sub pingall {
	my($minpong,$timeout) = @_;
	my @all = @queues;
	for my $q (@all) {
		my($net,$last) = @$q[NET,PINGT];
		next if ref $net eq 'Listener';
		if ($last < $timeout) {
			&Janus::delink($net, 'Ping Timeout');
		} elsif ($last < $minpong) {
			$net->send(+{ type => 'PING' });
		} else {
			# otherwise, the net is quite nicely active
		}
	}
}

sub timestep {
	my($r,$w) = ('','');
	for my $q (@queues) {
		vec($r,$q->[FD],1) = 1 if $q->[TRY_R];
		vec($w,$q->[FD],1) = 1 if $q->[TRY_W];
	}

	my $fd = select $r, $w, undef, $timeres;

	$timeres = &Janus::timer();

	if ($fd) {
		for my $q (@queues) {
			writable $q if vec($w,$q->[FD],1);
			readable $q if vec($r,$q->[FD],1);
		}
	}

	if ($lping + 30 < $Janus::time) {
		pingall($lping + 5, $Janus::time - 80);
		$lping = $Janus::time;
	}

	run_sendq $_ for @queues;

	scalar @queues;
}

sub _cleanup {
	my $act = shift;
	my $net = $act->{net};

	my $q = reassign $net, undef;
	return if $net->jlink();

	warn "Queue for network $$net was already removed" unless $q;
}

&Janus::hook_add(
	NETSPLIT => act => \&_cleanup,
	JNETSPLIT => act => \&_cleanup,
);

1;
