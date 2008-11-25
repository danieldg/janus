# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Multiplex;
use strict;
use warnings;
use integer;

our($HAS_IPV6,$HAS_DNS);
BEGIN {
	require IO::Socket::SSL;
	$HAS_IPV6 = eval {
		require IO::Socket::INET6;
		require Socket6;
		1;
	};
	$HAS_DNS = eval {
		require Net::DNS;
		1;
	};
	if ($HAS_IPV6) {
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
}

use Fcntl;
use constant {
	FD => 0,
	SOCK => 1,
	STATE => 2,
	NETID => 3,
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
# netid => [ fd, IO::Socket, state, netid, try_r, try_w, ... ]

sub peer_to_addr {
	my $peer = shift;
	if ($HAS_IPV6) {
		my($port,$addr) = unpack_sockaddr_in6 $peer;
		inet_ntop(AF_INET6, $addr);
	} else {
		my($port,$addr) = unpack_sockaddr_in $peer;
		inet_ntoa $addr;
	}
}

sub do_connect {
	my($baddr, $port, $bind, $sslkey, $sslcert) = @_;
	if ($HAS_IPV6 && length $baddr == 4) {
		$baddr = pack 'x10Sa4', -1, $baddr;
	}
	my $inet = $HAS_IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
	my $addr = $HAS_IPV6 ? sockaddr_in6($port, $baddr) : sockaddr_in($port, $baddr);
	my $sock = $inet->new(
		Proto => 'tcp',
		Blocking => 0,
		($bind ? (LocalAddr => $bind) : ()),
	);
	my $fd;
	if ($sock) {
		fcntl $sock, F_SETFL, O_NONBLOCK;
		connect $sock, $addr;
		$fd = fileno $sock;

		if ($sslcert) {
			IO::Socket::SSL->start_SSL($sock,
				SSL_startHandshake => 0,
				SSL_use_cert => 1,
				SSL_key_file => $sslkey,
				SSL_cert_file => $sslcert,
			);
			if ($sock->isa('IO::Socket::SSL')) {
				$sock->connect_SSL();
			} else {
				$fd = undef;
			}
		} elsif ($sslkey) {
			IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
			$sock->connect_SSL();
		}
	}
	return ($sock,$fd);
}

sub readable {
	my $l = shift;
	if ($l->[STATE] & STATE_LISTEN) {
		$l->[STATE] |= STATE_ACCEPT;
		return;
	}
	if ($l->[STATE] & STATE_DNS) {
		my($sock,$id,$sendq,$res,$iaddr,@info) = @$l[SOCK,NETID,SENDQ,DNS_INFO..$#$l];
		my $pkt = $res->bgread($sock);
		close $sock;
		my @answer = $pkt ? $pkt->answer() : undef;
		if (!$pkt || !@answer) {
			if ($HAS_IPV6 && !($l->[STATE] & STATE_DNS_V6)) {
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
		my($csock, $fd) = do_connect($baddr, @info);
		if (defined $fd) {
			@$l = ($fd, $csock, STATE_NORMAL, $id, 0, 1, '', $sendq, '');
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

sub run {
	my $cmd = shift;
	my $cmdfd = fileno $cmd;
	my $offset = 0;
	LINE: while (<$cmd>) {
		chomp;
		if (/^W (\d+)/) {
			my($r,$w,$time) = ('','',$1);
			vec($r,$cmdfd,1) = 1;
			for my $i (0..$#queues) {
				my $q = $queues[$i] or next;
				if ($q->[STATE] & STATE_DROPPED) {
					$q->[TRY_R] = $q->[TRY_W] = 0;
					if ($q->[STATE] & STATE_IOERR || !$q->[SENDQ]) {
						delete $queues[$i];
					}
				}
				run_sendq $q;
				vec($r,$q->[FD],1) = 1 if $q->[TRY_R];
				vec($w,$q->[FD],1) = 1 if $q->[TRY_W];
			}
			
			my $fd = select $r, $w, undef, $time - time;

			$offset = 0;
			print $cmd "DONE\n";

			for my $q (@queues) {
				next unless $q;
				writable $q if vec($w,$q->[FD],1);
				readable $q if vec($r,$q->[FD],1);
			}
		} elsif ($_ eq 'N') {
			while ($offset <= $#queues) {
				my $q = $queues[$offset];
				if (!$q || $q->[STATE] & STATE_DROPPED) {
					$offset++;
					next;
				}
				if ($q->[STATE] & STATE_NORMAL && $q->[RECVQ] =~ s/^([^\r\n]*)[\r\n]+//) {
					print $cmd "$q->[NETID] $1\n";
					next LINE;
				}
				if ($q->[STATE] & STATE_IOERR) {
					print $cmd "DELINK $q->[NETID] $q->[EINFO]\n";
					$offset++;
					next LINE;
				} elsif ($q->[STATE] & STATE_ACCEPT) {
					my $lsock = $q->[SOCK];
					my($sock,$peer) = $lsock->accept();
					my $fd = $sock ? fileno $sock : undef;
					if ($fd) {
						my $addr = peer_to_addr($peer);
						print $cmd "PEND $q->[NETID] $addr\n";
						$_ = <$cmd>;
						chomp;
						if (/^PEND-SSL (\d+) (\S+) (\S+)/) {
							my($netid,$key,$cert) = ($1,$2,$3);
							IO::Socket::SSL->start_SSL($sock, 
								SSL_server => 1, 
								SSL_startHandshake => 0,
								SSL_key_file => $key,
								SSL_cert_file => $cert,
							);
							if ($sock->isa('IO::Socket::SSL')) {
								$sock->accept_SSL();
							} else {
								die 'cannot initiate SSL accept';
							}
							$queues[$netid] = [ $fd, $sock, STATE_NORMAL, $netid, 1, 0, '', '', '' ];
						} elsif (/^PEND (\d+)/) {
							$queues[$1] = [ $fd, $sock, STATE_NORMAL, $1, 1, 0, '', '', '' ];
						}
						next LINE;
					} else {
						$q->[STATE] &= ~STATE_ACCEPT;
					}
				}
				$offset++;
			}
			print $cmd "L\n";
		} elsif (/^(\d+) (.*)/) {
			$queues[$1][SENDQ] .= "$2\n";
		} elsif (/^INITL (\S*) (\S+)/) {
			my($addr,$port) = ($1,$2);
			my $inet = $HAS_IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
			my $sock = $inet->new(
				Listen => 5,
				Proto => 'tcp',
				($addr ? (LocalAddr => $addr) : ()),
				LocalPort => $port,
				Blocking => 0,
			);
			my $fd;
			if ($sock) {
				fcntl $sock, F_SETFL, O_NONBLOCK;
				setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
				$fd = fileno $sock;
			}
			if (defined $fd) {
				print $cmd "OK\n";
				$_ = <$cmd>;
				chomp;
				/^ID (\d+)/ or die "Bad input line: $_";
				my $q = [ $fd, $sock, STATE_LISTEN, $1, 1, 0 ];
				$queues[$1] = $q;
			} else {
				print $cmd "ERR $!\n";
			}
		} elsif (/^INITC (\d+) (\S+) (\d+) (\S*) (\S*) (\S*)/) {
			my($id, $iaddr, @info) = ($1,$2,$3,$4,$5,$6);
			my $baddr = $HAS_IPV6 && $iaddr =~ /:/ ? inet_pton(AF_INET6, $iaddr) : inet_aton($iaddr);
			if (defined $baddr) {
				my($sock, $fd) = do_connect($baddr, @info);
				$queues[$id] = [ $fd, $sock, STATE_NORMAL, $id, 0, 1, '', '', '' ];
			} elsif ($HAS_DNS) {
				my $res = Net::DNS::Resolver->new;
				my $sock = $res->bgsend($iaddr,'A');
				my $fd = fileno $sock;
				$queues[$id] = [ $fd, $sock, STATE_DNS, $id, 1, 0, '', '', $res, $iaddr, @info ];
			} else {
				$queues[$id] = [ 0, undef, STATE_DNS | STATE_IOERR, $id, 0, 0, 'Net::DNS not found' ];
			}
		} elsif (/^DELNET (\d+)/) {
			$queues[$1][STATE] |= STATE_DROPPED;
			$queues[$1][TRY_R] = 0;
		} elsif (/^REBOOT (\S+)/) {
			my $save = $1;
			close $cmd;
			$cmd = &main::start_child();
			$cmdfd = fileno $cmd;
			print $cmd "RESTORE $save\n";
		} elsif (/^EVAL (.+)/) {
			my $ev = $1;
			my $rv = eval $ev;
			$rv =~ s/\n//g;
			print $cmd "R $rv\n";
		} elsif ($_ eq '') {
		} else {
			die "bad line $_";
		}
	}
}

1;
