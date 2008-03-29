# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Conffile;
use IO::Handle;
use strict;
use warnings;
use integer;
use Listener;
use Connection;
use RemoteJanus;
use Link;

our $conffile;
our %netconf;
our %inet;
# these values are replaced in modload by IPv4 or IPv6 code
# for creating IO::Socket objects. The dynamic choice can only
# happen once as it defines some symbols in this package

sub read_conf {
	my $nick = shift;

	local $_;
	my %newconf;
	my $current;
	$conffile ||= 'janus.conf';
	open my $conf, '<', $conffile;
	$conf->untaint(); 
		# the configurator is assumed to have at least half a brain :)
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*// or do {
			&Debug::usrerr("Line $. of config file could not be parsed");
			next;
		};
		my $type = $1;

		if ($type eq 'link') {
			if (defined $current) {
				&Janus::err_jmsg($nick, "Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^(\S+)/ or do {
				&Janus::err_jmsg($nick, "Error in line $. of config file: expected network ID");
				return;
			};

			$current = { id => $1 };
			$newconf{$1} = $current;
		} elsif ($type eq 'listen') {
			if (defined $current) {
				&Janus::err_jmsg($nick, "Missing closing brace at line $. of config file, aborting");
				return;
			}
			/^((?:\S+:)?\d+)( |$)/ or do {
				&Janus::err_jmsg($nick, "Error in line $. of config file: expected port or IP:port");
				return;
			};
			$current = { addr => $1 };
			$newconf{'LISTEN:'.$1} = $current;
		} elsif ($type eq 'set' || $type eq 'modules') {
			if (defined $current) {
				&Janus::err_jmsg($nick, "Missing closing brace at line $. of config file, aborting");
				return;
			}
			$current = {};
			$newconf{$type} = $current;
		} elsif ($type eq '}') {
			unless (defined $current) {
				&Janus::err_jmsg($nick, "Extra closing brace at line $. of config file");
				return;
			}
			$current = undef;
		} elsif ($type eq '{') {
		} else {
			unless (defined $current) {
				&Janus::err_jmsg($nick, "Error in line $. of config file: not in a network definition");
				return;
			}
			$current->{$type} = $_;
		}
	}
	close $conf;
	if ($newconf{set}{name}) {
		if ($RemoteJanus::self) {
			&Janus::err_jmsg($nick, "You must restart the server to change the name")
				if $RemoteJanus::self->id() ne $newconf{set}{name};
			$newconf{set}{name} = $RemoteJanus::self->id();
		}
	} else {
		&Janus::err_jmsg($nick, "Server name not set! You need set block with a 'name' entry");
		return;
	}
	%netconf = %newconf;
	if ($newconf{modules}) {
		for my $mod (keys %{$newconf{modules}}) {
			unless (&Janus::load($mod)) {
				&Janus::err_jmsg($nick, "Could not load module $mod: $@");
			}
		}
	}
}

sub connect_net {
	my($nick,$id) = @_;
	my $nconf = $netconf{$id};
	return if !$nconf || exists $Janus::nets{$id} || exists $Janus::ijnets{$id};
	if ($id =~ /^LISTEN:/) {
		return if $Listener::open{$id};
		&Debug::info("Listening on $nconf->{addr}");
		my $sock = $inet{listn}->($nconf);
		if ($sock) {
			my $list = Listener->new(id => $id, conf => $nconf);
			&Connection::add($sock, $list);
		} else {
			&Janus::err_jmsg($nick, "Could not listen on port $nconf->{addr}: $!");
		}
	} elsif ($nconf->{autoconnect}) {
		&Debug::info("Autoconnecting $id");
		my $type = 'Server::'.$nconf->{type};
		unless (&Janus::load($type)) {
			&Janus::err_jmsg($nick, "Error creating $type network $id: $@");
		} else {
			my $net = &Persist::new($type, id => $id);
			# this is equivalent to $type->new(id => \$id) but without using eval

			&Debug::info("Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}");

			my $sock = $inet{conn}->($nconf);

			$net->intro($nconf);

			if ($net->isa('Network')) {
				&Janus::append({
					type => 'NETLINK',
					net => $net,
				});
			} 
			# otherwise it's interjanus, which we let report its own events

			# we start out waiting on writes because that's what connect(2) says for EINPROGRESS connects
			&Connection::add($sock, $net);
		}
	}
}

sub rehash {
	my $nick = shift;
	read_conf $nick;
	my %toclose = %Listener::open;
	delete $toclose{$_} for keys %netconf;
	for my $net (values %toclose) {
		$net->close();
		&Connection::reassign($net, undef);
	}
	connect_net $nick,$_ for keys %netconf;

	&Janus::jmsg($nick,'Rehashed');
}

sub autoconnect {
	for my $id (keys %netconf) {
		if ($id =~ /^LISTEN/) {
			connect_net undef,$id unless $Listener::open{$id};
		} elsif (!$netconf{$id}{autoconnect} || exists $Janus::nets{$id} || exists $Janus::ijnets{$id}) {
			$netconf{$id}{backoff} = 0;
		} else {
			my $item = 2 * $netconf{$id}{backoff}++;
			my $rt = int sqrt $item;
			if ($item == $rt * ($rt + 1)) {
				&Debug::info("Backoff $item - Connecting");
				connect_net undef,$id;
			} else {
				&Debug::info("Backoff: $item != ".$rt*($rt+1));
			}
		}
	}
}

&Janus::hook_add(
	REHASH => act => sub {
		my $act = shift;
		&Conffile::rehash($act->{src});
	},
	'INIT' => check => sub {
		my $act = shift;
		$conffile = $act->{args}[1];
		read_conf;
		if ($netconf{set}{ipv6}) {
			eval q[
				use IO::Socket::INET6;
				use IO::Socket::SSL 'inet6';
				use Socket6;
				use Fcntl;
				1;
			] or die "Could not load IPv6 socket code: $@";
			%Conffile::inet = (
				type => 'IPv6',
				listn => eval q[ sub {
					my $nconf = shift;
					my $addr = $nconf->{addr};
					$addr = '[::]:'.$addr unless $addr =~ /:/;
					my $sock = IO::Socket::INET6->new(
						Listen => 5, 
						Proto => 'tcp', 
						LocalAddr => $addr,
						Blocking => 0,
					);
					if ($sock) {
						fcntl $sock, F_SETFL, O_NONBLOCK;
						setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
					}
					$sock;
				} ], 
				conn => eval q[ sub {
					my $nconf = shift;
					my $addr = sockaddr_in6($nconf->{linkport}, inet_pton(AF_INET6, $nconf->{linkaddr}));
					my $sock = IO::Socket::INET6->new(
						Proto => 'tcp',
						($nconf->{linkbind} ? (LocalAddr => $nconf->{linkbind}) : ()), 
						Blocking => 0,
					);
					fcntl $sock, F_SETFL, O_NONBLOCK;
					connect $sock, $addr;

					if ($nconf->{linktype} =~ /^ssl/) {
						IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
						$sock->connect_SSL();
					}
					$sock;
				} ],
				addr => eval q[ sub {
					my $str = shift;
					my($port,$addr) = unpack_sockaddr_in6 $str;
					$addr = inet_ntop AF_INET6, $addr;
					return ($addr,$port);
				} ],
			);
		} else {
			eval q[
				use IO::Socket::INET;
				use IO::Socket::SSL;
				use Socket;
				use Fcntl;
				1;
			] or die "Could not load IPv4 socket code: $@";
			%Conffile::inet = (
				type => 'IPv4',
				listn => eval q[ sub {
					my $nconf = shift;
					my $addr = $nconf->{addr};
					$addr = '0.0.0.0:'.$addr unless $addr =~ /:/;
					my $sock = IO::Socket::INET->new(
						Listen => 5, 
						Proto => 'tcp', 
						LocalAddr => $addr,
						Blocking => 0,
					);
					if ($sock) {
						fcntl $sock, F_SETFL, O_NONBLOCK;
						setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
					}
					$sock;
				} ], 
				conn => eval q[ sub {
					my $nconf = shift;
					my $addr = sockaddr_in($nconf->{linkport}, inet_aton($nconf->{linkaddr}));
					my $sock = IO::Socket::INET->new(
						Proto => 'tcp', 
						LocalAddr => ($nconf->{linkbind} || '0.0.0.0'), 
						Blocking => 0,
					);
					fcntl $sock, F_SETFL, O_NONBLOCK;
					connect $sock, $addr;

					if ($nconf->{linktype} =~ /^ssl/) {
						IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
						$sock->connect_SSL();
					}
					$sock;
				} ],
				addr => eval q[ sub {
					my $str = shift;
					my($port,$addr) = unpack_sockaddr_in $str;
					$addr = inet_ntoa $addr;
					return ($addr,$port);
				} ],
			);
		}
		undef;
	},
	RUN => act => sub {
		do $netconf{set}{save};
		connect_net undef,$_ for keys %netconf;
		&Janus::schedule({
			repeat => 30,
			code => sub { &Conffile::autoconnect; }, # to allow reloads
		});
	},
);

1;
