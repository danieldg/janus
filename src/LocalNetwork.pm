# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package LocalNetwork;
use Network;
use Channel;
use Persist 'Network';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our(@cparms); # currently active network parameters
&Persist::register_vars(qw(cparms));
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

sub intro {
	my $net = shift;
	$cparms[$$net] = { %{$Conffile::netconf{$net->name()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
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
