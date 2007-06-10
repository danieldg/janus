# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Conffile;
use strict;
use warnings;
use InterJanus;
use IO::Select;
use IO::Socket::INET6;
use IO::Socket::SSL 'inet6';
use Socket6;
use Fcntl;
use CAUnreal;
use Unreal;

our $conffile;
our %netconf;

sub rehash {
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

			$current = {};
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
			$current = {};
			$current->{port} = $1;
			$newconf{'LISTEN:'.$1} = $current;
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
	for my $id (keys %netconf) {
		my $nconf = $netconf{$id};
		next if exists $Janus::netqueues{$id};
		if ($id =~ /^LISTEN:/) {
			my $port = $nconf->{port};
			my $sock = IO::Socket::INET6->new(
				Listen => 5, 
				Proto => 'tcp', 
				LocalPort => $port, 
				Blocking => 0,
			);
			fcntl $sock, F_SETFL, O_NONBLOCK;
			$Janus::netqueues{$id} = [$sock, undef, undef, undef, 1, 0];
		} elsif ($nconf->{autoconnect}) {
			my $type = $nconf->{type};
			my $net = eval "use $type; return ${type}->new(id => \$id)";
			unless ($net) {
				&Janus::err_jmsg($nick, "Error creating $type network $id: $@");
			} else {
				print "Setting up nonblocking connection to $nconf->{netname} at $nconf->{linkaddr}:$nconf->{linkport}\n";
	
				my $addr = sockaddr_in6($nconf->{linkport}, inet_pton(AF_INET6, $nconf->{linkaddr}));
				my $sock = IO::Socket::INET6->new(Proto => 'tcp', Blocking => 0);
				fcntl $sock, F_SETFL, O_NONBLOCK;
				connect $sock, $addr;
	
				if ($nconf->{linktype} =~ /^ssl/) {
					IO::Socket::SSL->start_SSL($sock, SSL_startHandshake => 0);
					$sock->connect_SSL();
				}
				$net->intro($nconf);
				&Janus::link($net);
	
				# we start out waiting on writes because that's what connect(2) says for EINPROGRESS connects
				$Janus::netqueues{$id} = [$sock, '', '', $net, 0, 1];
			}
		}
	}
	&Janus::jmsg($nick,'Rehashed');
}

sub modload {
 my($class,$cfile) = @_;
 $conffile = $cfile;
 &Janus::hook_add($class,
	REHASH => act => sub {
		my $act = shift;
		&Conffile::rehash($act->{src});
	}, LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
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
	});
}

1;
