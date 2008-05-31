# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Connection;
use strict;
use warnings;
use integer;
our $ipv6;
BEGIN {
	$ipv6 = $Conffile::netconf{set}{ipv6} ? 1 : 0 unless defined $ipv6;
	require IO::Socket::SSL;
	if ($ipv6) {
		require IO::Socket::INET6;
		require Socket6;
		IO::Socket::INET6->import();
		IO::Socket::SSL->import('inet6');
		Socket6->import();
	} else {
		require IO::Socket::INET;
		require Socket;
		IO::Socket::INET->import();
		IO::Socket::SSL->import();
		Socket->import();
	}
	our $XS;
	die "Connection cannot be reloaded in C mode" if $XS;
}
use Debug;
use Scalar::Util qw(tainted);
use Fcntl;
use constant {
	FD => 0,
	SOCK => 1,
	NET => 2,
	RECVQ => 3,
	SENDQ => 4,
	TRY_R => 5,
	TRY_W => 6,
	PINGT => 7,
	IPV6 => $ipv6,
};

our @queues;
# net number => [ fd, IO::Socket, net, recvq, sendq, try_recv, try_send, ping ]
our $lping;
$lping ||= 100;

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

sub init_listen {
	my($addr,$port) = @_;
	my $inet = IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
	my $sock = $inet->new(
		Listen => 5,
		Proto => 'tcp',
		($addr ? (LocalAddr => $addr) : ()),
		LocakPort => $port,
		Blocking => 0,
	);
	if ($sock) {
		fcntl $sock, F_SETFL, O_NONBLOCK;
		setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
	}
	$sock;
}

sub init_conn {
	my($addr, $port, $bind, $ssl) = @_;
	my $addr = IPV6 ?
			sockaddr_in6($port, inet_pton(AF_INET6, $addr)) :
			sockaddr_in($port, inet_aton($addr));
	my $inet = IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
	my $sock = $inet->new(
		Proto => 'tcp',
		Blocking => 0,
		($bind ? (LocalAddr => $bind) : ()),
	);
	fcntl $sock, F_SETFL, O_NONBLOCK;
	connect $sock, $addr;

	if ($ssl) {
		IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
		$sock->connect_SSL();
	}
	$sock;
}

sub peer_to_addr {
	my $peer = shift;
	if (IPV6) {
		my($port,$addr) = unpack_sockaddr_in6 $peer;
		inet_ntop(AF_INET6, $addr);
	} else {
		my($port,$addr) = unpack_sockaddr_in $peer;
		inet_ntoa $addr;
	}
}

sub readable {
	my $l = shift;
	my $net = $$l[NET] or return;
	if (ref $net eq 'Listener') {
		# this is a listening socket; accept a new connection
		my $lsock = $$l[SOCK];
		my($sock,$peer) = $lsock->accept();
		my $fd = $sock ? fileno $sock : undef;
		return unless defined $fd;
		my $addr = peer_to_addr($peer);
		$net = $net->init_pending($sock, $addr);
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
		delink($net, 'Socket read failure ('.$!.')');
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
		delink($net, 'Socket write failure ('.$!.')');
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
	my($timeout, $minpong) = @_;
	my @all = @queues;
	for my $q (@all) {
		my($net,$last) = @$q[NET,PINGT];
		next if ref $net eq 'Listener';
		if ($last < $timeout) {
			delink($net, 'Ping Timeout');
		} elsif ($last < $minpong) {
			$net->send(+{ type => 'PING' });
		}
	}
}

sub delink {
	my($net,$msg) = @_;
	return unless $net;
	if ($net->isa('Pending')) {
		my $id = $net->id();
		delete $Janus::nets{$id};
		&Connection::reassign($net, undef);
	} elsif ($net->isa('Server::InterJanus')) {
		&Janus::insert_full(+{
			type => 'JNETSPLIT',
			net => $net,
			msg => $msg,
		});
	} else {
		&Janus::insert_full(+{
			type => 'NETSPLIT',
			net => $net,
			msg => $msg,
		});
	}
}


sub timestep {
	my($r,$w) = ('','');
	for my $q (@queues) {
		vec($r,$q->[FD],1) = 1 if $q->[TRY_R];
		vec($w,$q->[FD],1) = 1 if $q->[TRY_W];
	}

	my $time = &Janus::next_event($lping+30);

	my $fd = select $r, $w, undef, $time - time;

	&Janus::timer(time);

	if ($fd) {
		for my $q (@queues) {
			writable $q if vec($w,$q->[FD],1);
			readable $q if vec($r,$q->[FD],1);
		}
	}

	# Send out pings to servers that need it, once every 30 seconds
	if ($lping + 30 <= $Janus::time) {
		# time out if it was 60 seconds since the PREVIOUS ping was sent
		# (this will be around 90 seconds ago)
		# send a ping if no traffic was received for 25 seconds
		# (this is so we don't bother pinging active networks)
		pingall($lping - 60, $Janus::time - 25);
		$lping = $Janus::time;
	}

	run_sendq $_ for @queues;

	scalar @queues;
}

&Janus::hook_add(
	NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};

		my $q = reassign $net, undef;
		return if $net->jlink();

		warn "Queue for network $$net was already removed" unless $q;
	}, JNETSPLIT => check => sub {
		my $act = shift;
		my $net = $act->{net};

		my $q = reassign $net, undef;
		warn "Queue for network $$net was already removed" unless $q;

		my $eq = $Janus::ijnets{$net->id()};
		return 1 if $eq && $eq ne $net;
		undef;
	}
);

1;
