# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
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
		"Currently this is reset on a link of a channel, and not persisted between",
		"network restarts. Restricted to opers because of possible conflict with services.",
	],
	code => sub {
		my $nick = shift;
		my($cname, $nname) = $_[0] =~ /(#\S*)(?: (\S+))?/;
		$nname ||= $nick->homenet()->name();
		my $chan = $nick->homenet()->chan($cname) or return;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
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
		$net->send(\%nact);
		1;
	}, KICK => check => sub {
		my $act = shift;
		return undef if acl_ok($act);
		my $src = $act->{src};
		my $snet = $src->isa('Network') ? $src : $src->homenet();
		return undef if $act->{nojlink}; # this is a slight hack, prevents reverting kills
		return undef if $snet->jlink();
		my $kicked = $act->{kickee};
		my $chan = $act->{dst};
		$snet->send(+{
			type => 'JOIN',
			src => $kicked,
			dst => $chan,
			mode => $chan->get_nmode($kicked),
		});
		1;
	},
);

1;
