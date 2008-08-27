# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Claim;
use strict;
use warnings;
use Persist;

our %claim;
&Janus::save_vars(claim => \%claim);

&Janus::command_add({
	cmd => 'claim',
	help => 'Claim network ownership of a channel',
	details => [
		"\002CLAIM\002 #channel            Lists claims on the channel",
		"\002CLAIM\002 #channel net,net    Sets the claiming networks of the channel",
		"\002CLAIM\002 #channel -          Removes all claim from the channel",
		"This command claims network ownership for a channel. Unless the list is empty, only",
		"networks on the list can have services or opers act on the channel.",
	],
	acl => 1,
	code => sub {
		my($src,$dst, $cname, $claims) = @_;
		my $nhome = $src->homenet;
		my $chan = $nhome->chan($cname) or return;
		my $chnet = $chan->homenet;
		my $chnn = $chnet->name;
		my $chname = $chan->str($chnet);
		if ($claims) {
			if ($chnet != $nhome) {
				&Janus::jmsg($dst, 'Manipulating claims must be done by the home network');
				return;
			}
			if ($claims =~ s/^-//) {
				delete $claim{$chnn}{$chname};
				&Janus::jmsg($dst, 'Deleted');
			} else {
				my %n;
				$n{$_}++ for split /,/, $claims;
				$n{$chnn}++;
				$claim{$chnn}{$chname} = join ',', sort keys %n;
				&Janus::jmsg($dst, 'Set to '.$claim{$chnn}{$chname});
			}
		} else {
			my $nets = $claim{$chnn}{$chname};
			if ($nets) {
				&Janus::jmsg($dst, "Channel $cname is claimed by: $nets");
			} else {
				&Janus::jmsg($dst, "Channel $cname is not claimed");
			}
		}
	},
});

sub acl_ok {
	my $act = shift;
	my $src = $act->{src} or return 1;
	my $chan = $act->{dst};
	my $hnet = $chan->homenet;
	my $claim = $claim{$hnet->name}{$chan->str($hnet)} or return 1;
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

&Janus::hook_add(
	MODE => check => sub {
		my $act = shift;
		return undef if acl_ok($act);
		my %nact = %$act;
		my $src = delete $nact{src};
		delete $nact{IJ_RAW};
		my $net = delete $nact{except} or return undef;
		my $chan = $act->{dst};
		if ($src->isa('Nick')) {
			&Log::info('Bouncing mode change by '.$src->netnick.' on '.$chan->str($src->homenet));
		} else {
			&Log::info('Bouncing mode change by '.$src->name.' on '.$chan->str($src));
		}
		my($m,$a,$d) = @nact{qw/mode args dirs/};
		for my $i (0 .. $#$d) {
			my $t = $Modes::mtype{$m->[$i]};
			my $val = $t eq 'n' ? $chan->has_nmode($m->[$i], $a->[$i]) : $chan->get_mode($m->[$i]);
			$d->[$i] = $val ? '+' : '-';
			if ($t eq 'r') {
				$a->[$i] = $val || 3;
			} elsif ($t eq 'v') {
				$a->[$i] = $val if $val;
			} elsif ($t eq 'l') {
				$val ||= [];
				my $e = scalar grep { $a->[$i] eq $_ } @$val;
				$d->[$i] = $e ? '+' : '-';
			}
		}
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
		&Log::info('Bouncing kick by '.$src->netnick.' on '.$chan->str($src->homenet));

		&Janus::append({
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
			&Log::info('Bouncing mode change by '.$src->netnick.' on '.$chan->str($src->homenet));
		} else {
			&Log::info('Bouncing mode change by '.$src->name.' on '.$chan->str($src));
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
