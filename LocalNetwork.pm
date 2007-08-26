# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package LocalNetwork;
BEGIN {
	&Janus::load('Network');
	&Janus::load('Channel');
}
use Persist 'Network';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @cparms :Persist(cparms); # currently active parameters
my @lreq   :Persist(lreq);
my @synced :Persist(synced) :Get(is_synced);
my @ponged :Persist(ponged);
our %chans;

sub _init {
	my $net = shift;
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
	unless (exists $chans{lc $name}) {
		return undef unless $new;
		my $chan = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
		print "Creating channel $name - luid=$$chan\n";
		$chans[$$net]{lc $name} = $chan;
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

sub _modeargs {
	my $net = shift;
	my $mode = shift;
	my @modes;
	my @args;
	local $_;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		my $txt = $net->cmode2txt($_) || 'UNK';
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			push @args, $net->nick(shift);
		} elsif ($type eq 'l') {
			push @args, shift;
		} elsif ($type eq 'v') {
			push @args, shift;
		} elsif ($type eq 's') {
			push @args, shift if $pm eq '+';
		} elsif ($type ne 'r') {
			warn "Unknown mode '$_' ($txt)";
			next;
		}
		push @modes, $pm.$txt;
	}
	(\@modes, \@args);
}

sub _mode_interp {
	my($net, $mods, $args) = @_;
	my $pm = '';
	my $mode;
	my @argin = @$args;
	my @args;
	for my $mtxt (@$mods) {
		my($ipm,$txt) = ($mtxt =~ /^([-+])(.*)/) or warn $mtxt;
		my $itm = ($txt =~ /^[nlv]/ || $mtxt =~ /^\+s/) ? shift @argin : undef;
		if (defined $net->txt2cmode($txt)) {
			push @args, ref $itm ? $itm->str($net) : $itm if defined $itm;
			$mode .= $ipm if $ipm ne $pm;
			$mode .= $net->txt2cmode($txt);
			$pm = $ipm;
		} else {
			# TODO investigate alternate tristate modes
		}
	}
	$mode, @args;
}

sub add_req {
	my($net, $lchan, $onet, $ochan) = @_;
	$lreq[$$net]{$lchan}{$onet->id()} = $ochan;
}

sub is_req {
	my($net, $lchan, $onet) = @_;
	$lreq[$$net]{$lchan}{$onet->id()};
}

sub del_req {
	my($net, $lchan, $onet) = @_;
	delete $lreq[$$net]{$lchan}{$onet->id()};
}

################################################################################
# Nick actions
################################################################################

sub mynick {
	my($net, $name) = @_;
	my $nick = $Janus::nicks{lc $name};
	unless ($nick) {
		print "Nick '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet()->id() ne $net->id()) {
		print "Nick '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $Janus::nicks{lc $name} if $Janus::nicks{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $old = delete $Janus::nicks{lc $name};
	unless ($old) {
		$Janus::nicks{lc $name} = $new;
		return 1;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	$Janus::nicks{lc $name} = $new if $tsctl > 0;
	$Janus::nicks{lc $name} = $old if $tsctl < 0;
	
	my @rv = ($tsctl > 0);
	if ($tsctl >= 0) {
		if ($old->homenet()->id() eq $net->id()) {
			warn "Nick collision on home network!";
		} else {
			push @rv, +{
				type => 'QUIT',
				dst => $new,
				killer => $net,
			};
		}
	}
	@rv;
}

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	$_[2];
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
}

sub all_nicks {
	my $net = shift;
	values %Janus::nicks;
}

###############################################################################
# General actions
###############################################################################

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $Janus::nicks{lc $item} if exists $Janus::nicks{lc $item};
	return $chans{lc $item} if exists $chans{lc $item};
	return $net if $item =~ /\./;
	return undef;
}

&Janus::hook_add(
 	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
		undef;
	},
);

1;
