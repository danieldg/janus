# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Connection;
use strict;
use warnings;
use integer;
# NOTE: this file cannot depend on the rest of the Janus framework
# as it is used in the I/O loop of multiplex.pl

BEGIN {
	die 'Cannot load Connection when Multiplex is loaded' if $Multiplex::master_api;
	*HAS_SSL = eval {
		require IO::Socket::SSL;
		1;
	} ? sub { 1 } : sub { 0 };
	*HAS_IPV6 = eval {
		require Socket6;
		require IO::Socket::INET6;
		1;
	} ? sub { 1 } : sub { 0 };
	*HAS_DNS = eval {
		require Net::DNS;
		1;
	} ? sub { 1 } : sub { 0 };
	our $PRIMARY = 1;
}
BEGIN {
	if (HAS_IPV6) {
		IO::Socket::SSL->import('inet6') if HAS_SSL;
		Socket6->import();
	} else {
		IO::Socket::SSL->import() if HAS_SSL;
	}
	unless (HAS_SSL) {
		*SSL_WANT_READ = sub { '' };
		*SSL_WANT_WRITE = sub { '' };
	}
}

use Socket;
use Fcntl;
use constant {
	FD => 0,
	SOCK => 1,
	STATE => 2,
	NET => 3,
	TRY_R => 4,
	TRY_W => 5,
	EINFO => 6,
	SENDQ => 7,
	RECVQ => 8,
	DNS_INFO => 8,

	STATE_LISTEN => 0x1, # this is a listening socket
	STATE_NORMAL => 0x2, # this is an IRC s2s socket
	STATE_DNS    => 0x4, # this is a DNS lookup socket
	STATE_TYPE_M => 0x7, # socket type mask

	STATE_IOERR   => 0x8,   # this is a disconnected socket
	STATE_DROPPED => 0x10,  # socket has been removed

	STATE_ACCEPT  => 0x20,  # socket can accept() new connection
	STATE_DNS_V6  => 0x40,  # IPv6 lookup has been tried
};

our @queues;
# netid => [ fd, IO::Socket, state, net, try_r, try_w, ... ]
our($mpsock,$mpoffset);
our $tblank = ``;

sub mpsend {
	return unless $mpsock;
	print $mpsock join(' ',@_), "\n";
}

sub peer_to_addr {
	my $peer = shift;
	if (28 == length $peer) {
		my($port,$addr) = unpack_sockaddr_in6 $peer;
		inet_ntop(AF_INET6, $addr);
	} else {
		my($port,$addr) = unpack_sockaddr_in $peer;
		inet_ntoa $addr;
	}
}

sub do_ip_connect {
	my($baddr, $port, $bind, $sslkey, $sslcert) = @_;
	my($af, $addr, $sock);
	if (length $baddr == 4) {
		$af = AF_INET;
		$addr = sockaddr_in($port, $baddr);
		if ($bind) {
			$bind = inet_aton($bind);
		}
	} else {
		$af = AF_INET6;
		$addr = sockaddr_in6($port, $baddr);
		if ($bind) {
			$bind = inet_pton(AF_INET6, $baddr);
		}
	}
	socket $sock, $af, SOCK_STREAM, 0;
	return () unless $sock;
	my $fd = fileno $sock;
	fcntl $sock, F_SETFL, O_NONBLOCK;
	if ($bind) {
		bind $sock, $bind;
	}
	connect $sock, $addr;

	if (HAS_SSL && $sslcert) {
		IO::Socket::SSL->start_SSL($sock,
			SSL_startHandshake => 0,
			SSL_use_cert => 1,
			SSL_key_file => $sslkey,
			SSL_cert_file => $sslcert,
		);
		return () unless $sock->isa('IO::Socket::SSL');
		$sock->connect_SSL();
	} elsif (HAS_SSL && $sslkey) {
		IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
		$sock->connect_SSL();
	}
	return ($sock,$fd);
}

sub init_connection {
	my($net, $iaddr, @info) = @_;
	my $baddr = HAS_IPV6 && $iaddr =~ /:/ ? inet_pton(AF_INET6, $iaddr) : inet_aton($iaddr);
	my $netid = ref $net ? $$net : $net;
	if (defined $baddr) {
		my($sock, $fd) = do_ip_connect($baddr, @info);
		$queues[$netid] = [ $fd, $sock, STATE_NORMAL, $net, 0, 1, '', '', '' ];
	} elsif (HAS_DNS) {
		my $res = Net::DNS::Resolver->new;
		my $sock = $res->bgsend($iaddr,'A');
		my $fd = fileno $sock;
		$queues[$netid] = [ $fd, $sock, STATE_DNS, $net, 1, 0, '', '', $res, $iaddr, @info ];
	} else {
		$queues[$netid] = [ 0, undef, STATE_DNS | STATE_IOERR, $net, 0, 0, 'Net::DNS not found' ];
	}
}

sub init_listen {
	my($net,$addr,$port) = @_;
	my($af,$sock);
	if (HAS_IPV6 && (!$addr || $addr =~ /:/)) {
		$af = AF_INET6;
		my $baddr = inet_pton(AF_INET6, $addr || '::');
		$addr = sockaddr_in6($port, $baddr);
	} else {
		$af = AF_INET;
		my $baddr = inet_aton($addr || '0.0.0.0');
		$addr = sockaddr_in($port, $baddr);
	}
	socket $sock, $af, SOCK_STREAM, 0;
	return 0 unless $sock;
	my $fd = fileno $sock;
	fcntl $sock, F_SETFL, O_NONBLOCK;
	setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
	bind $sock, $addr or return 0;
	listen $sock, 5 or return 0;
	my $q = [ $fd, $sock, STATE_LISTEN, $net, 1, 0 ];
	$queues[ref $net ? $$net : $net] = $q;
	return 1;
}

sub drop_socket {
	my $net = shift;
	$net = $$net if ref $net;
	$queues[$net][STATE] |= STATE_DROPPED;
	$queues[$net][TRY_R] = 0;
}

sub readable {
	my $l = shift;
	if ($l->[STATE] & STATE_LISTEN) {
		$l->[STATE] |= STATE_ACCEPT;
		return;
	}
	if ($l->[STATE] & STATE_DNS) {
		my($sock,$net,$sendq,$res,$iaddr,@info) = @$l[SOCK,NET,SENDQ,DNS_INFO..$#$l];
		my $pkt = $res->bgread($sock);
		close $sock;
		my @answer = $pkt ? $pkt->answer() : undef;
		if (!$pkt || !@answer) {
			if (HAS_IPV6 && !($l->[STATE] & STATE_DNS_V6)) {
				$l->[STATE] |= STATE_DNS_V6;
				$sock = $res->bgsend($iaddr,'AAAA');
				$l->[FD] = fileno $sock;
				$l->[SOCK] = $sock;
				return;
			}
			my $err = $!;
			$err = $pkt->header->rcode if $pkt;
			$l->[STATE] |= STATE_IOERR;
			$l->[EINFO] = "DNS resolver error: $err";
			return;
		}
		my $baddr = $answer[0]->rdata;
		my($csock, $fd) = do_ip_connect($baddr, @info);
		if (defined $fd) {
			@$l = ($fd, $csock, STATE_NORMAL, $net, 0, 1, '', $sendq, '');
		} else {
			$l->[STATE] |= STATE_IOERR;
			$l->[EINFO] = "Connection error: $!";
		}
		return;
	}

	my ($sock, $recvq) = @$l[SOCK,RECVQ];
	my $len = $sock->sysread($recvq, 8192, length $recvq);
	if ($len) {
		$$l[RECVQ] = $recvq;
		$$l[TRY_R] = 1 if $$l[TRY_R]; #reset SSL error counter
	} else {
		if ($sock->isa('IO::Socket::SSL')) {
			if ($sock->errstr() eq SSL_WANT_READ) {
				# we were trying to read, and want another read: act just like reading
				# half of a line, i.e. return and wait for the next incoming blob
				return unless $$l[TRY_R]++ > 30;
				# However, if we have had more than 30 errors, assume something else is wrong
				# and bail out.
				$$l[EINFO] = "30 read errors in a row, bailing out!";
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				# since are waiting for a write, we do NOT want to come back when reads
				# are available, at least not until we have unblocked a write.
				@$l[TRY_R, TRY_W] = (0,1);
				return;
			} else {
				$$l[EINFO] = "SSL read error: ".$sock->errstr;
			}
		} else {
			$$l[EINFO] = "Delink from failed read: $!";
		}
		$$l[STATE] |= STATE_IOERR;
	}
}

sub _syswrite {
	my $l = shift;
	my ($sock, $sendq) = @$l[SOCK, SENDQ];
	my $len = $sock->syswrite($sendq);
	if (defined $len) {
		$$l[SENDQ] = substr $sendq, $len;
		# schedule a wakeup to write the rest if we were not able to write everything in the sendq
		$$l[TRY_W] = 1 if $len < length $sendq;
	} else {
		if ($sock->isa('IO::Socket::SSL')) {
			if ($sock->errstr() eq SSL_WANT_READ) {
				@$l[TRY_R,TRY_W] = (1,0);
				return;
			} elsif ($sock->errstr() eq SSL_WANT_WRITE) {
				@$l[TRY_R,TRY_W] = (0,1);
				return;
			} else {
				$$l[EINFO] = "SSL write error: ".$sock->errstr;
			}
		} else {
			$$l[EINFO] = "Delink from failed write: $!";
		}
		$$l[STATE] |= STATE_IOERR;
	}
}

sub writable {
	my $l = $_[0];
	@$l[TRY_R,TRY_W] = (1,0);
	&_syswrite;
}

sub run_sendq {
	my $l = $_[0];
	return if $$l[TRY_W] || !$$l[SENDQ] || !($l->[STATE] & STATE_NORMAL);
	# no point in trying to write if we are already waiting for writes to unblock
	&_syswrite;
}

sub iowait {
	my($r,$w,$time) = ('','',$_[0]);
	vec($r,fileno($mpsock),1) = 1 if $mpsock;
	for my $i (0..$#queues) {
		my $q = $queues[$i] or next;
		if (!@$q || $q->[STATE] & STATE_DROPPED) {
			$q->[TRY_R] = $q->[TRY_W] = 0;
			if ($q->[STATE] & STATE_IOERR || !$q->[SENDQ]) {
				my $sock = $q->[SOCK];
				close $sock if $sock;
				delete $queues[$i];
			}
		}
		run_sendq $q;
		vec($r,$q->[FD],1) = 1 if $q->[TRY_R];
		vec($w,$q->[FD],1) = 1 if $q->[TRY_W];
	}
	
	my $fd = select $r, $w, undef, $time - time;

	$mpoffset = 0;
	mpsend('DONE');

	for my $q (@queues) {
		next unless $q;
		writable $q if vec($w,$q->[FD],1);
		readable $q if vec($r,$q->[FD],1);
	}
}

sub do_accept {
	my($q,$hook) = @_;
	my $lsock = $q->[SOCK];
	$q->[STATE] &= ~STATE_ACCEPT;
	my $sock;
	my $peer = accept $sock, $lsock;
	my $fd = $peer ? fileno $sock : undef;
	return unless $fd;
	my $addr = peer_to_addr($peer);
	my($net,$key,$cert) = $hook->($addr);
	return unless $net;
	$q = [ $fd, $sock, STATE_NORMAL, $net, 1, 0, '', '', '' ];
	$queues[ref $net ? $$net : $net] = $q;
	if (HAS_SSL && $key) {
		IO::Socket::SSL->start_SSL($sock, 
			SSL_server => 1, 
			SSL_startHandshake => 0,
			SSL_key_file => $key,
			SSL_cert_file => $cert,
		);
		if ($sock->isa('IO::Socket::SSL')) {
			$sock->accept_SSL();
		} else {
			$q->[STATE] |= STATE_IOERR;
			$q->[EINFO] = 'Cannot initiate SSL accept';
		}
	}
}

sub ts_mplex {
	local $_ = <$mpsock>;
	return 0 unless defined;
	chomp;
	if (/^W (\d+)/) {
		iowait($1);
	} elsif ($_ eq 'N') {
		while ($mpoffset <= $#queues) {
			my $q = $queues[$mpoffset];
			if (!$q || $q->[STATE] & STATE_DROPPED) {
				$mpoffset++;
				next;
			}
			if ($q->[STATE] & STATE_NORMAL && $q->[RECVQ] =~ s/^([^\r\n]*)[\r\n]+//) {
				print $mpsock "$q->[NET] $1\n";
				return 1;
			}
			if ($q->[STATE] & STATE_IOERR) {
				print $mpsock "DELINK $q->[NET] $q->[EINFO]\n";
				$mpoffset++;
				return 1;
			} elsif ($q->[STATE] & STATE_ACCEPT) {
				do_accept($q, sub {
					my $addr = shift;
					print $mpsock "PEND $q->[NET] $addr\n";
					$_ = <$mpsock>;
					chomp;
					if (/^PEND-SSL (\d+) (\S+) (\S+)/) {
						return ($1,$2,$3);
					} elsif (/^PEND (\d+)/) {
						return $1;
					} else {
						return 0;
					}
				});
				return 1;
			}
			$mpoffset++;
		}
		print $mpsock "L\n";
	} elsif (/^(\d+) (.*)/) {
		$queues[$1][SENDQ] .= "$2\n";
	} elsif (/^INITL (\d+) (\S*) (\S+)/) {
		my $ok = init_listen($1,$2,$3);
		print $mpsock $ok ? "OK\n" : "ERR $!\n";
	} elsif (/^INITC (\d+) (\S+) (\d+) (\S*) (\S*) (\S*)/) {
		init_connection($1,$2,$3,$4,$5,$6);
	} elsif (/^DELNET (\d+)/) {
		drop_socket($1);
	} elsif (/^REBOOT (\S+)/) {
		my $save = $1;
		close $mpsock;
		$mpsock = &main::start_child();
		print $mpsock "RESTORE $save\n";
	} elsif (/^EVAL (.+)/) {
		my $ev = $1;
		my $rv = eval $ev;
		$rv =~ s/\n//g;
		print $mpsock "R $rv\n";
	} elsif ($_ eq '') {
	} else {
		die "bad line $_";
	}
	return 1;
}

# This sub is allowed to use Janus API as it is not called from multiplex
sub ts_simple {
	my $next = &Event::next_event($Janus::time + 60);
	iowait($next);
	&Event::timer(time);
	for my $q (@queues) {
		next unless $q;
		my $net = $q->[NET];
		next if $q->[STATE] & STATE_DROPPED;
		while ($q->[STATE] & STATE_NORMAL && $q->[RECVQ] =~ s/^([^\r\n]*)[\r\n]+//) {
			$net->in_socket($tblank . $1);
		}
		if ($q->[STATE] & STATE_IOERR) {
			$net->delink($q->[EINFO]);
		} elsif ($q->[STATE] & STATE_ACCEPT) {
			do_accept($q, sub {
				my $cnet = $net->init_pending($_[0]);
				return 0 unless $cnet;
				my($sslkey, $sslcert) = &Conffile::find_ssl_keys($cnet, $net);
				if ($sslcert) {
					return ($cnet,$sslkey,$sslcert);
				} else {
					return $cnet;
				}
			});
		}
	}

	for my $q (@queues) {
		my $net = $q && $q->[NET] or next;
		eval {
			my $sendq = $net->dump_sendq();
			$queues[$$net][SENDQ] .= $sendq;
			1;
		} or &Log::err_in($net, "dump_sendq died: $@");
	}
}

sub list {
	map { $_ ? $_->[NET] : () } @queues;
}

1;
