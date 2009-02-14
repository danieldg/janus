# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Qline;
use Persist;
use strict;
use warnings;

our(@qlines);
&Persist::register_vars('Network::qlines' => \@qlines);

&Event::hook_add(
	XLINE => act => sub {
		my $act = shift;
		my $net = $act->{dst};
		my $t = uc $act->{ltype};
		if ($t eq 'Q') {
			my $m = $act->{mask};
			return if $m =~ /\*/;
			$qlines[$$net]{$m} = [ $m, $act->{expire} ];
		}
	},
	NICK => 'act:-1' => sub {
		my $act = shift;
		my $n = $act->{dst};
		my $nick = $act->{nick};
		my $ftag = $act->{tag} || {};
		$act->{tag} = $ftag;
		for my $net ($n->netlist) {
			next if $net->jlink || $net == $n->homenet;
			my $line = $qlines[$$net]{$nick} or next;
			if ($line->[1] && $line->[1] < $Janus::time) {
				delete $qlines[$$net]{$nick};
			} else {
				$ftag->{$$net} = 1;
			}
		}
	},
);

1;
