# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Bridge;
use strict;
use warnings;
use Modes;

if ($Janus::lmode) {
	die "Wrong link mode" unless $Janus::lmode eq 'Bridge';
} else {
	$Janus::lmode = 'Bridge';
}

&Event::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		for my $net (values %Janus::nets) {
			next if $nick->homenet() eq $net;
			next if $nick->is_on($net);
			&Event::append({
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			});
		}
	}, KILL => parse => sub {
		my $kact = shift;
		my $nick = $kact->{dst};
		my $knet = $kact->{net};
		my $hnet = $nick->homenet();
		if ($$nick == 1) {
			$knet->send({
				type => 'CONNECT',
				dst => $Interface::janus,
				net => $knet,
			});
			return 1;
		}
		$hnet->send({
			type => 'KILL',
			src => $kact->{src},
			dst => $nick,
			net => $hnet,
			msg => $kact->{msg},
		});
		&Event::append({
			type => 'QUIT',
			dst => $nick,
			killer => $kact->{src},
			msg => $kact->{msg},
			except => $hnet,
		});
		1;
	}, XLINE => parse => sub {
		my $act = shift;
		$act->{sendto} = $Janus::global;
		0;
	}, NETLINK => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		my @conns;

		for my $nick (values %Janus::gnicks) {
			warn if $nick->is_on($net);
			push @conns, {
				type => 'CONNECT',
				dst => $nick,
				net => $net,
			};
		}
		&Event::insert_full(@conns);

		# hide the channel burst from janus's event hooks
		# TODO this may not be correct now that CHANBURST exists
		for my $chan (values %Janus::chans) {
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
				in_link => 1,
			}) if defined $chan->topic();
		}
	},
);

1;
