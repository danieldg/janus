# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package LocalNetwork;
use Network;
use Channel;
use Persist 'Network';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @cparms :Persist(cparms); # currently active parameters
my @synced :Persist(synced) :Get(is_synced);
my @ponged :Persist(ponged);
my @chans  :Persist(chans);

sub _init {
	my $net = shift;
	$chans[$$net] = {};
}

sub param {
	my $net = shift;
	$Conffile::netconf{$net->name()}{$_[0]};
}

sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub pong {
	my $net = shift;
	$ponged[$$net] = time;
}

sub pongcheck {
	my $p = shift;
	my $net = $p->{net};
	if ($net && !isweak($p->{net})) {
		warn "Reference is strong! Weakening";
		weaken($p->{net});
		$net = $p->{net}; #possibly skip
	}
	unless ($net) {
		delete $p->{repeat};
		&Conffile::connect_net(undef, $p->{netid});
		return;
	}
	unless ($Janus::gnets{$net->gid()} eq $net) {
		delete $p->{repeat};
		warn "Network $net not deallocated quickly enough!";
		return;
	}
	my $last = $ponged[$$net];
	if ($last + 90 <= time) {
		print "PING TIMEOUT!\n";
		&Janus::delink($net, 'Ping timeout');
		&Conffile::connect_net(undef, $p->{netid});
		delete $p->{net};
		delete $p->{repeat};
	} elsif ($last + 29 <= time) {
		$net->send(+{
			type => 'PING',
		});
	}
}

sub intro {
	my $net = shift;
	$cparms[$$net] = { %{$Conffile::netconf{$net->name()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
	$ponged[$$net] = time;
	my $pinger = {
		repeat => 30,
		net => $net,
		netid => $net->name(),
		code => \&pongcheck,
	};
	weaken($pinger->{net});
	&Janus::schedule($pinger);
}

################################################################################
# Channel actions
################################################################################

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $chans[$$net]{lc $name}) {
		return undef unless $new;
		my $chan = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
		$chans[$$net]{lc $name} = $chan;
	}
	$chans[$$net]{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	warn "replacing nonexistant channel" unless exists $chans[$$net]{lc $name};
	if (defined $new) {
		$chans[$$net]{lc $name} = $new;
	} else {
		delete $chans[$$net]{lc $name};
	}
}

sub all_chans {
	my $net = shift;
	values %{$chans[$$net]};
}

&Janus::hook_add(
 	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
		undef;
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa('LocalNetwork');
		if (%{$chans[$$net]}) {
			my @clean;
			warn "channels remain after a netsplit, delinking...";
			for my $cn (keys %{$chans[$$net]}) {
				my $chan = $chans[$$net]{$cn};
				unless ($chan->is_on($net)) {
					print "Channel $cn=$$chan not on network $$net as it claims\n";
					delete $chans[$$net]{$cn};
					next;
				}
				push @clean, +{
					type => 'DELINK',
					dst => $chan,
					net => $net,
					nojlink => 1,
					reason => 'netsplit',
				};
			}
			&Janus::insert_full(@clean);
			for my $chan ($net->all_chans()) {
				$chan->unhook_destroyed();
			}
			warn "channels still remain after double delinks: ".join ',', keys %{$chans[$$net]} if %{$chans[$$net]};
			$chans[$$net] = undef;
		}
	},
);

1;
