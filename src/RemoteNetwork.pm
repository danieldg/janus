# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package RemoteNetwork;
use Network;
use Persist 'Network';
use strict;
use warnings;
use Carp;

sub all_nicks { 
	my $net = shift;
	grep { $_->is_on($net) } values %Janus::gnicks;
}

sub all_chans {
	my $net = shift;
	my %cbyid;
	$_->is_on($net) and $cbyid{$$_} = $_ for values %Janus::gchans;
	values %cbyid;
}

sub chan {
	my($net, $cname) = @_;
	my $kn = $net->gid() . lc $cname;
	my $c = $Janus::gchans{$kn};
	if (!$c && $_[2]) {
		croak "Cannot create remote channel";
	}
	$c;
}

sub send {
	my $net = shift;
	my $ij = $net->jlink();
	$ij->send(@_);
}

1;
