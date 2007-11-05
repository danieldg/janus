# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Bridge;
use strict;
use warnings;
use Modes;

&Janus::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		for my $net (values %Janus::nets) {
			next if $nick->homenet() eq $net;
			next if $nick->is_on($net);
			&Janus::append({
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			});
		}
	}, RAW => act => sub {
		my $act = shift;
		delete $act->{except};
	}, XLINE => parse => sub {
		my $act = shift;
		$act->{sendto} = [ values %Janus::nets ];
		0;
	}, BURST => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my @conns;
		for my $nick (values %Janus::nicks) {
			next if $nick->is_on($net);
			push @conns, {
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			};
		}
		&Janus::insert_full(@conns);

		# hide the channel burst from janus's event hooks
		for my $chan ($net->all_chans()) {
			for my $nick ($chan->all_nicks()) {
				$net->send({
					type => 'JOIN',
					src => $nick,
					dst => $chan,
					mode => $chan->get_nmode($nick),
				});
			}
			my($modes, $args, $dirs) = &Modes::delta(undef, $chan);
			$net->send({
				type => 'MODE',
				dst => $chan,
				mode => $modes,
				args => $args,
				dirs => $dirs,
			}) if @$modes;
			$net->send({
				type => 'TOPIC',
				dst => $chan,
				topic => $chan->topic(),
				topicts => $chan->topicts(),
				topicset => $chan->topicset(),
				in_burst => 1,
			}) if defined $chan->topic();
		}
	},
);

1;
