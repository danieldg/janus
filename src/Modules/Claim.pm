# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Claim;
use strict;
use warnings;
use Persist;

our %claim;
Janus::save_vars(claim => \%claim);

for my $n (sort keys %claim) {
	if ($n !~ /#/ && ref $claim{$n}) {
		for my $c (keys %{$claim{$n}}) {
			$claim{$n.lc $c} = $claim{$n}{$c};
		}
		delete $claim{$n};
	}
}

Event::command_add({
	cmd => 'claim',
	help => 'Claim network ownership of a channel',
	section => 'Channel',
	details => [
		"\002CLAIM\002 #channel            Lists claims on the channel",
		"\002CLAIM\002 #channel net,net    Sets the claiming networks of the channel",
		"\002CLAIM\002 #channel -          Removes all claim from the channel",
		"This command claims network ownership for a channel. Unless the list is empty, only",
		"networks on the list can have services or opers act on the channel.",
	],
	api => '=src =replyto localchan ?$',
	code => sub {
		my($src, $dst, $chan, $claims) = @_;
		my $nhome = $src->homenet;
		my $chome = $chan->homenet;
		if ($claims) {
			return unless Account::chan_access_chk($src, $chan, 'create', $dst);
			if ($claims =~ s/^-//) {
				delete $claim{$chan->netname};
				Janus::jmsg($dst, 'Deleted');
			} else {
				my %n;
				$n{$_}++ for split /,/, $claims;
				$n{$chome->name}++;
				$claim{$chan->netname} = join ',', sort keys %n;
				Janus::jmsg($dst, 'Set to '.$claim{$chan->netname});
			}
		} else {
			my $nets = $claim{$chan->netname};
			if ($nets) {
				Janus::jmsg($dst, "Channel is claimed by: $nets");
			} else {
				Janus::jmsg($dst, "Channel is not claimed");
			}
		}
	},
});

sub acl_ok {
	my $act = shift;
	my $src = $act->{src} or return 1;
	my $chan = $act->{dst};
	my $hnet = $chan->homenet;
	my $claim = $claim{$chan->netname} or return 1;
	my $snet = $src->isa('Network') ? $src : $src->homenet;
	$snet->name() eq $_ and return 1 for split /,/, $claim;
	if ($src->isa('Nick')) {
		return 1 if $$src == 1;
		# this is not a true operoverride check, just makes sure acting users
		# have >= halfop. This is really good enough, if you have halfop you
		# have a trust relationship with chanops, and they can remove it when
		# it is abused.
		for (qw/owner admin op halfop/) {
			return 1 if $chan->has_nmode($_, $src);
		}
	}
	0;
}

Event::hook_add(
	INFO => 'Channel:1' => sub {
		my($dst, $chan, $asker) = @_;
		my $hnet = $chan->homenet;
		my $claim = $claim{$chan->netname} or return;
		Janus::jmsg($dst, "\002Claim:\002 $claim");
	},
	MODE => check => sub {
		my $act = shift;
		return undef if acl_ok($act);
		my $src = $act->{src};
		my $chan = $act->{dst};
		my $net = $act->{except} or return undef;
		if ($src->isa('Nick')) {
			Log::info('Bouncing mode change by '.$src->netnick.' on '.$chan->str($src->homenet));
		} else {
			Log::info('Bouncing mode change by '.$src->name.' on '.$chan->str($src));
		}
		my($m,$a,$d) = Modes::revert($chan, $act->{mode}, $act->{args}, $act->{dirs});
		my %nact = (
			type => 'MODE',
			src => $Interface::janus,
			dst => $chan,
			mode => $m,
			args => $a,
			dirs => $d,
		);
		$net->send(\%nact);
		1;
	}, KICK => act => sub {
		my $act = shift;
		return undef if acl_ok($act);
		return undef if $act->{nojlink}; # this is a slight hack, prevents reverting kills
		my $net = $act->{except};
		my $chan = $act->{dst};
		my $src = $act->{src};
		return unless $src->isa('Nick');
		Log::info('Bouncing kick by '.$src->netnick.' on '.$chan->str($src->homenet));

		Event::append({
			type => 'KICK',
			src => $Interface::janus,
			dst => $chan,
			kickee => $src,
			msg => 'This channel is claimed. You should not kick people in it.',
		});
	}, TOPIC => check => sub {
		my $act = shift;
		return undef if acl_ok($act);
		my $net = $act->{except};
		my $chan = $act->{dst};
		my $src = $act->{src};
		return undef unless $chan->get_mode('topic'); # allow if not +t
		if ($src->isa('Nick')) {
			Log::info('Bouncing topic change by '.$src->netnick.' on '.$chan->str($src->homenet));
		} else {
			Log::info('Bouncing topic change by '.$src->name.' on '.$chan->str($src));
		}
		$net->send(+{
			type => 'TOPIC',
			dst => $chan,
			topic => $chan->topic(),
			topicts => $chan->topicts(),
			topicset => $chan->topicset(),
		});
		1;
	},
);

1;
