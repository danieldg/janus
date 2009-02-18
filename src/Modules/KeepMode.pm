# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::KeepMode;
use strict;
use warnings;
use Persist;

our %saved;
Janus::save_vars(saved => \%saved);

Event::hook_add(
	CHANLINK => act => sub {
		my $act = shift;
		return unless $act->{net} == $Interface::network;
		my $chan = $act->{dst};
		return if $chan->homenet->jlink;
		my $modes = $saved{$chan->netname} or return;
		my($m,$a,$d) = Modes::delta(undef, $modes);
		Event::append({
			type => 'MODE',
			src => $Interface::janus,
			dst => $chan,
			mode => $m,
			args => $a,
			dirs => $d,
		});
	},
	MODE => cleanup => sub {
		my $act = shift;
		my $chan = $act->{dst};
		return if $chan->homenet->jlink;
		return unless $chan->is_on($Interface::network);
		$saved{$chan->netname} = $chan->all_modes;
	}
);

1;
