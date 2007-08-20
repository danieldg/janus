# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package RemoteNetwork;
BEGIN { &Janus::load('Network') }
use Persist 'Network';
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

sub all_nicks { 
	my $net = shift;
	grep { $_->is_on($net) } values %Janus::gnicks;
}

sub all_chans {
	my $net = shift;
	grep { $_->is_on($net) } values %Janus::gchans;
}

1;
