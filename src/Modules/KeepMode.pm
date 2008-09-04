# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::KeepMode;
use strict;
use warnings;
use Persist;

our %mode;
&Janus::save_vars(mode => \%mode);

&Event::hook_add(
	CHANLINK => act => sub {
		my $act = shift;
		return unless $act->{net} == $Interface::network;
		my $chan = $act->{dst};
		my $hnet = $chan->homenet;
		return if $hnet->jlink;
		my $cname = lc $chan->str($hnet);
		my $mcache = $mode{$hnet->name}{$cname} or return;
		&Event::append({
			type => 'MODE',
			src => $Interface::janus,
			dst => $chan,
			mode => $mcache->[0],
			args => $mcache->[1],
			dirs => $mcache->[2],
		});
	},
	MODE => cleanup => sub {
		my $act = shift;
		my $chan = $act->{dst};
		return unless $chan->is_on($Interface::network);
		my $hnet = $chan->homenet;
		return if $hnet->jlink;
		my $cname = lc $chan->str($hnet);
		$mode{$hnet->name}{$cname} = [ &Modes::dump($chan) ];
	}
);

1;
