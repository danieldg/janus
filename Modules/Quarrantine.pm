# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Quarrantine;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @homes :PersistAs(Channel, homenets);

&Janus::command_add({
	cmd => 'claim',
	help => 'Claim network ownership of a channel',
	details => [
		"Syntax: \002CLAIM\002 #channel net[,net,net...]",
		"Claims network ownership for a channel. Opers and services outside these",
		"networks cannot make mode changes or kicks to this channel.",
		'-',
		"Currently this is not persisted between network restarts.",
		"Restricted to opers because of possible conflict with services.",
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my($cname, $nname) = $_[0] =~ /(#\S*)(?: (\S+))?/;
		$nname ||= $nick->homenet()->name();
		my $chan = $nick->homenet()->chan($cname) or return;
		my $oldhomes = $homes[$$chan];
		if ($oldhomes) {
			my($claimed, $mine) = (0,0);
			for (split /,/, $oldhomes) {
				$claimed++ if $Janus::nets{$_};
				$mine++ if $nick->homenet()->name() eq $_;
			}
			if ($claimed && !$mine) {
				&Janus::jmsg($nick, "Someone from one of the following networks must run this command: $oldhomes");
				return;
			}
		}
		$nname = undef if $nname eq 'none' || $nname eq 'unset' || $nname eq 'janus';
		$homes[$$chan] = $nname;
		$nname ||= 'unset';
		&Janus::jmsg($nick, "The owner of $cname is now $nname");
	},
});

sub acl_ok {
	my $act = shift;
	my $src = $act->{src} or return 1;
	my $chan = $act->{dst};
	my $home = $homes[$$chan] or return 1;
	my $snet = $src->isa('Network') ? $src : $src->homenet();
	$snet->name() eq $_ and return 1 for split /,/, $home;
	if ($src->isa('Nick')) {
		# TODO this is not a true operoverride check, just makes sure
		# acting users have >= halfop
		for (qw/n_owner n_admin n_op n_halfop/) {
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
		delete $nact{src};
		my $net = delete $nact{except};
		map tr/+-/-+/, @{$nact{dirs}};
		if ($net->jlink()) {
			$net->jlink()->ij_send(\%nact);
		} else {
			$net->send(\%nact);
		}
		1;
	}, KICK => check => sub {
		my $act = shift;
		return undef if acl_ok($act);
		my $src = $act->{src};
		my $snet = $src->isa('Network') ? $src : $src->homenet();
		return undef if $act->{nojlink}; # this is a slight hack, prevents reverting kills
		return undef if $snet->jlink();
		my $kicked = $act->{kickee};
		return undef if $kicked->homenet() eq $snet; # I can't stop you kicking your own users
		my $chan = $act->{dst};
		$snet->send(+{
			type => 'JOIN',
			src => $kicked,
			dst => $chan,
			mode => $chan->get_nmode($kicked),
		});
		1;
	}, LINK => cleanup => sub {
		my $act = shift;
		my %owns;
		for my $k (qw/chan1 chan2/) {
			my $ch = $act->{$k};
			next unless $ch;
			my $hs = $homes[$$ch];
			next unless $hs;
			$owns{$_}++ for split /,/, $hs;
		}
		return unless %owns;
		$homes[${$act->{dst}}] = join ',', sort keys %owns;
	},
);

1;
