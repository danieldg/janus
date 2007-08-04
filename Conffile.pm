# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Conffile;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

our $conffile = $_[0];

our %netconf;
our %inet = (
	# these values are replaced in modload by IPv4 or IPv6 code
	# for creating IO::Socket objects. The dynamic choice can only
	# happen once as it defines some symbols in this package
	listn => sub { die },
	conn => sub { die },
);

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
		my $type = lc $1;

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
			/^(\d+)/ or do {
				&Janus::err_jmsg($nick, "Error in line $. of config file: expected port");
				return;
			};
			$current = { port => $1 };
			$newconf{'LISTEN:'.$1} = $current;
		} elsif ($type eq 'set') {
			if (defined $current) {
				&Janus::err_jmsg($nick, "Missing closing brace at line $. of config file, aborting");
				return;
			}
			$current = {};
			$newconf{janus} = $current;
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
	%netconf = %newconf;
}

sub connect_net {
	my($nick,$id) = @_;
	my $nconf = $netconf{$id};
	return if !$nconf || exists $Janus::netqueues{$id};
	if ($id =~ /^LISTEN:/) {
		my $sock = $inet{listn}->($nconf->{port});
		if ($sock) {
			$Janus::netqueues{$id} = [$sock, undef, undef, undef, 1, 0];
		} else {
			&Janus::err_jmsg($nick, "Could not listen on port $nconf->{port}: $!");
		}
	} elsif ($nconf->{autoconnect}) {
		my $type = $nconf->{type};
		my $net = eval "use $type; return ${type}->new(id => \$id)";
		unless ($net) {
			&Janus::err_jmsg($nick, "Error creating $type network $id: $@");
		} else {
			print "Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}\n";

			my $sock = $inet{conn}->($nconf->{linkaddr}, $nconf->{linkport}, $nconf->{linktype} =~ /^ssl/);

			$net->intro($nconf);

			&Janus::link($net) unless $net->isa('InterJanus');

			# we start out waiting on writes because that's what connect(2) says for EINPROGRESS connects
			$Janus::netqueues{$net->id()} = [$sock, '', '', $net, 0, 1];
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
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		open my $links, 'links.'.$net->id().'.conf' or return;
		while (<$links>) {
			my($cname1, $nname, $cname2) = /^\s*(#\S*)\s+(\S+)\s+(#\S*)/ or next;
			my $net2 = $Janus::nets{$nname} or next;
			&Janus::append(+{
				type => 'LINKREQ',
				net => $net,
				dst => $net2,
				slink => $cname1,
				dlink => $cname2,
				sendto => [ $net2 ],
				linkfile => 1,
			});
		}
		close $links;
	},
);

read_conf;
if ($netconf{janus}{ipv6}) {
	eval q[
		use IO::Socket::INET6;
		use IO::Socket::SSL 'inet6';
		use Socket6;
		use Fcntl;
		1;
	] or die "Could not load IPv6 socket code: $@";
	%Conffile::inet = (
		listn => eval q[ sub {
			my $port = shift;
			my $sock = IO::Socket::INET6->new(
				Listen => 5, 
				Proto => 'tcp', 
				LocalPort => $port, 
				Blocking => 0,
			);
			if ($sock) {
				fcntl $sock, F_SETFL, O_NONBLOCK;
				setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
			}
			$sock;
		} ], 
		conn => eval q[ sub {
			my($ip,$port,$ssl) = @_;
			my $addr = sockaddr_in6($port, inet_pton(AF_INET6, $ip));
			my $sock = IO::Socket::INET6->new(Proto => 'tcp', Blocking => 0);
			fcntl $sock, F_SETFL, O_NONBLOCK;
			connect $sock, $addr;

			if ($ssl) {
				IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
				$sock->connect_SSL();
			}
			$sock;
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
			my $port = shift;
			my $sock = IO::Socket::INET->new(
				Listen => 5, 
				Proto => 'tcp', 
				LocalPort => $port, 
				Blocking => 0,
			);
			fcntl $sock, F_SETFL, O_NONBLOCK;
			setsockopt $sock, SOL_SOCKET, SO_REUSEADDR, 1;
			$sock;
		} ], 
		conn => eval q[ sub {
			my($ip,$port,$ssl) = @_;
			my $addr = sockaddr_in($port, inet_aton($ip));
			my $sock = IO::Socket::INET->new(Proto => 'tcp', Blocking => 0);
			fcntl $sock, F_SETFL, O_NONBLOCK;
			connect $sock, $addr;

			if ($ssl) {
				IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
				$sock->connect_SSL();
			}
			$sock;
		} ],
	);
}
connect_net undef,$_ for keys %netconf;

1;
