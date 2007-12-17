# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Conffile;
use IO::Handle;
use strict;
use warnings;
use Listener;
use Connection;
use Links;

our $VERSION;
my $reload = $VERSION;
($VERSION) = '$Rev$' =~ /(\d+)/;
$VERSION = 1 unless $VERSION; # make sure reloads act as such

our $conffile;
$conffile = $_[0] unless $reload;

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
	open my $conf, '<', $conffile;
	$conf->untaint(); 
		# the configurator is assumed to have at least half a brain :)
	while (<$conf>) {
		chomp;
		s/\s*$//;
		next if /^\s*(#|$)/;
		s/^\s*(\S+)\s*// or do {
			print "Error in line $. of config file\n";
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
			$newconf{janus} = $current if $type eq 'set';
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
		if ($Janus::name) {
			&Janus::err_jmsg($nick, "You must restart the server to change the name")
				if $Janus::name ne $newconf{set}{name};
			$newconf{set}{name} = $Janus::name;
		} else {
			$Janus::name = $newconf{set}{name};
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
	print "Connecting $id\n";
	if ($id =~ /^LISTEN:/) {
		# FIXME this is not the best way to find it, plus we can never stop listening
		for my $pl (values %Connection::queues) {
			my $n = $pl->[3] or next;
			next unless $n->isa('Listener');
			return if $n->id() eq $id;
		}
		print "Listening on $nconf->{addr}\n";
		my $sock = $inet{listn}->($nconf);
		if ($sock) {
			my $list = Listener->new(id => $id, conf => $nconf);
			&Connection::add($sock, $list);
		} else {
			&Janus::err_jmsg($nick, "Could not listen on port $nconf->{addr}: $!");
		}
	} elsif ($nconf->{autoconnect}) {
		my $type = 'Server::'.$nconf->{type};
		unless (&Janus::load($type)) {
			&Janus::err_jmsg($nick, "Error creating $type network $id: $@");
		} else {
			my $net = &Persist::new($type, id => $id);
			# this is equivalent to $type->new(id => \$id) but without using eval

			print "Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}\n";

			my $sock = $inet{conn}->($nconf);

			$net->intro($nconf);

			if ($net->isa('Network')) {
				&Janus::insert_full({
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
	connect_net $nick,$_ for keys %netconf;
	&Janus::jmsg($nick,'Rehashed');
}

&Janus::hook_add(
	REHASH => act => sub {
		my $act = shift;
		&Conffile::rehash($act->{src});
	},
	'INIT' => check => sub {
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
	},
);

1;
