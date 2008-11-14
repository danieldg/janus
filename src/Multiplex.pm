# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Multiplex;
use strict;
use warnings;
use integer;

our $ipv6;
BEGIN {
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
}

use Fcntl;
use constant {
	FD => 0,
	SOCK => 1,
	STATE => 2,
	NETID => 3,
	RECVQ => 4,
	SENDQ => 5,
	TRY_R => 6,
	TRY_W => 7,
	EINFO => 8,
	IPV6 => $ipv6,
	STATE_LISTEN => 1,
	STATE_DEAD => 2,
	STATE_ACCEPT => 4,
};

our @queues;
# netid => [ fd, IO::Socket, netid, recvq, sendq, try_recv, try_send ]

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
	if ($l->[STATE] & STATE_LISTEN) {
		$l->[STATE] |= STATE_ACCEPT;
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
		$$l[STATE] |= STATE_DEAD;
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
		$$l[STATE] |= STATE_DEAD;
	}
}

sub writable {
	my $l = $_[0];
	@$l[TRY_R,TRY_W] = (1,0);
	&_syswrite;
}

sub run_sendq {
	my $l = $_[0];
	return if $$l[TRY_W] || !$$l[SENDQ];
	# no point in trying to write if we are already waiting for writes to unblock
	&_syswrite;
}

sub run {
	my $cmd = shift;
	my $offset = 0;
	LINE: while (<$cmd>) {
		chomp;
		if (/^W (\d+)/) {
			my($r,$w,$time) = ('','',$1);
			for my $q (@queues) {
				next unless $q;
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
				unless ($q) {
					$offset++;
					next;
				}
				if ($q->[RECVQ] =~ s/^([^\r\n]*)[\r\n]+//) {
					print $cmd "$q->[NETID] $1\n";
					next LINE;
				}
				if ($q->[STATE] & STATE_DEAD) {
					print $cmd "DELINK $q->[NETID] $q->[EINFO]\n";
					$offset++;
					next LINE;
				} elsif ($q->[STATE] & STATE_ACCEPT) {
					my $lsock = $q->[SOCK];
					$q->[STATE] &= ~STATE_ACCEPT;
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
							$queues[$netid] = [ $fd, $sock, 0, $netid, '', '', 1, 0, '' ];
						} elsif (/^PEND (\d+)/) {
							$queues[$1] = [ $fd, $sock, 0, $1, '', '', 1, 0, '' ];
						}
						next LINE;
					}
				}
				$offset++;
			}
			print $cmd "L\n";
		} elsif (/^(\d+) (.*)/) {
			$queues[$1][SENDQ] .= "$2\n";
		} elsif (/^INITL (\S*) (\S+)/) {
			my($addr,$port) = ($1,$2);
			my $inet = IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
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
				my $q = [ $fd, $sock, STATE_LISTEN, $1, '', undef, 1, 0, '' ];
				$queues[$1] = $q;
			} else {
				print $cmd "ERR $!\n";
			}
		} elsif (/^INITC (\S+) (\d+) (\S*) (\S*) (\S*)/) {
			my($iaddr, $port, $bind, $sslkey, $sslcert) = ($1,$2,$3,$4,$5);
			my $addr = IPV6 ?
					sockaddr_in6($port, inet_pton(AF_INET6, $iaddr)) :
					sockaddr_in($port, inet_aton($iaddr));
			my $inet = IPV6 ? 'IO::Socket::INET6' : 'IO::Socket::INET';
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
			if (defined $fd) {
				print $cmd "OK\n";
				$_ = <$cmd>;
				chomp;
				/^ID (\d+)/ or die "Bad input line: $_";
				my $q = [ $fd, $sock, 0, $1, '', '', 0, 1, '' ];
				$queues[$1] = $q;
			} else {
				print $cmd "ERR $!\n";
			}
		} elsif (/^DELNET (\d+)/) {
			delete $queues[$1];
		} elsif (/^REBOOT (\S+)/) {
			my $save = $1;
			close $cmd;
			$cmd = &main::start_child();
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
