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
my @lreq   :Persist(lreq) :Get(all_reqs);
my @synced :Persist(synced) :Get(is_synced);
my @ponged :Persist(ponged);
my @chans  :Persist(chans);

sub _init {
	my $net = shift;
	$chans[$$net] = {};
}

sub param {
	my $net = shift;
	$Conffile::netconf{$net->id()}{$_[0]};
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
	unless ($net && defined $net->id()) {
		delete $p->{repeat};
		&Conffile::connect_net(undef, $p->{netid});
		return;
	}
	unless ($Janus::nets{$net->id()} eq $net) {
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
	$cparms[$$net] = { %{$Conffile::netconf{$net->id()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
	$ponged[$$net] = time;
	my $pinger = {
		repeat => 30,
		net => $net,
		netid => $net->id(),
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
		print "Creating channel $name - luid=$$chan\n";
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

sub add_req {
	my($net, $lchan, $onet, $ochan) = @_;
	$lreq[$$net]{$lchan}{ref $onet ? $onet->id() : $onet} = $ochan;
}

sub is_req {
	my($net, $lchan, $onet) = @_;
	$lreq[$$net]{$lchan}{$onet->id()};
}

sub del_req {
	my($net, $lchan, $onet) = @_;
	delete $lreq[$$net]{$lchan}{$onet->id()};
}

&Janus::hook_add(
 	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
		undef;
	}, NETLINK => act => sub {
		my $act = shift;
		my $rnet = $act->{net};
		return unless $rnet->isa('RemoteNetwork');
		my $id = $rnet->id();
		for my $net (values %Janus::nets) {
			next unless $net->isa('LocalNetwork');
			for my $ch (keys %{$lreq[$$net]}) {
				my $req = $lreq[$$net]{$ch}{$id} or next;
				&Janus::append(+{
					type => 'LINKREQ',
					net => $net,
					dst => $rnet,
					slink => $ch,
					dlink => $req,
					linkfile => 1,
				});
			}
		}
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa('LocalNetwork');
		my $tid = $net->id();
		if (%{$chans[$$net]}) {
			my @clean;
			warn "channels remain after a netsplit, delinking...";
			for my $chan ($net->all_chans()) {
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
