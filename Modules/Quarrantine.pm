# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modules::Quarrantine;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @home :PersistAs(Channel, homenet);

&Janus::command_add({
	cmd => 'claim',
	help => 'Claim network ownership of a channel',
	code => sub {
		my $nick = shift;
		my($cname, $nname) = $_[0] =~ /(#\S*)(?: (\S+))?/;
		my $net = defined $nname ? $Janus::nets{$nname} : $nick->homenet();
		my $chan = $nick->homenet()->chan($cname) or return;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $oldhome = $home[$$chan];
		if ($oldhome && $Janus::nets{$oldhome} && $nick->homenet()->id() ne $oldhome && 
				$chan->is_on($Janus::nets{$oldhome})) {
			&Janus::jmsg($nick, "Someone from the $oldhome network must run this command");
			return;
		}
		my $owner = $net ? $net->id() : undef;
		$home[$$chan] = $owner;
		$owner ||= 'unset';
		&Janus::jmsg($nick, "The owner of $cname is now $owner");
	},
});

sub acl_ok {
	my $act = shift;
	my $src = $act->{src} or return 1;
	my $chan = $act->{dst};
	my $home = $home[$$chan] or return 1;
	my $snet = $src->isa('Network') ? $src : $src->homenet();
	return 1 if $snet->id() eq $home;
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
		return if $act->{nojlink}; # this is a slight hack, prevents reverting kills
		return if $snet->jlink();
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
