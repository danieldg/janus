# Copyright (C) 2007-2009 Daniel De Graaf
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

Event::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		for my $net (values %Janus::nets) {
			next if $nick->homenet() eq $net;
			next if $nick->is_on($net);
			Event::append({
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
		return 0 if $$nick == 1;
		$hnet->send({
			type => 'KILL',
			src => $kact->{src},
			dst => $nick,
			net => $hnet,
			msg => $kact->{msg},
		});
		Event::append({
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
		Event::insert_full(@conns);
		@conns = ();

		for my $chan (values %Janus::chans) {
			push @conns, {
				type => 'CHANALLSYNC',
				chan => $chan,
			};
		}
		$net->send(@conns);
	},
);

1;
