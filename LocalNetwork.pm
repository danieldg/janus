# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package LocalNetwork;
use Network;
use Channel;
use Persist 'Network';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @cparms :Persist(cparms); # currently active parameters
my @ponged :Persist(ponged);
our %chans;

sub _init {
	my $net = shift;
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
	unless (exists $chans{lc $name}) {
		return undef unless $new;
		my $chan = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
		$chans{lc $name} = $chan;
	}
	$chans{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	warn "replacing nonexistant channel" unless exists $chans{lc $name};
	if (defined $new) {
		$chans{lc $name} = $new;
	} else {
		delete $chans{lc $name};
	}
}

sub all_chans {
	values %chans;
}

1;
