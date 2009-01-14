# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Xline;
use Persist;
use strict;
use warnings;

our(@glines, @zlines, @qlines);
&Persist::register_vars(
	'Network::glines' => \@glines,
	'Network::zlines' => \@zlines,
	'Network::qlines' => \@qlines,
);

our %enabled;
&Janus::save_vars(enabled => \%enabled);

sub ire {
	my($x,$i) = @_;
	return 1 unless defined $x;
	return 0 unless defined $i;
	$x =~ s/(\W)/\\$1/g;
	$x =~ s/\\\*/.*/g;
	$x =~ s/\\\?/./g;
	$i =~ /^$x$/;
}

# act.XLINE => {
#	dst       'Network'
#	ltype     G Z Q
#	mask      '$'
#	setter    '?$'
#	expire    = 0 for permanent, = 1 for unset, = time else
#	settime   '?$',  # only valid if setting
#	reason    '?$',  # only valid if setting
# },
#
# glines[$$net][$i] => [ mask, expire, settime, setter, reason ]

sub delline {
	my($list, $mask) = @_;
	local $_;
	@$list = grep { $_->[0] ne $mask } @$list;
}

sub addline {
	my($list,$act) = @_;
	my $exp = $act->{expire};
	delline($list, $act->{mask});
	return if $exp && $exp < $Janus::time;
	push @$list, [ $act->{mask}, $exp, $act->{settime}, $act->{setter}, $act->{reason} ];
}

sub findline {
	my($list,$item) = @_;
	@$list = grep { $_->[1] == 0 || $_->[1] > $Janus::time } @$list;
	for (@$list) {
		return $_ if ire($_->[0], $item);
	}
}

sub countline {
	my $list = shift;
	return 0 unless $list;
	@$list = grep { $_->[1] == 0 || $_->[1] > $Janus::time } @$list;
	scalar @$list;
}

&Event::command_add({
	cmd => 'xline',
	help => 'Enables or disables bans according to G/Z-lines',
	section => 'Network',
	details => [
		'Enables or disables bans according to G/Z-lines',
		'These bans are enforced for your network only, and are only listable',
		"via your server's tracking of glines",
		"Syntax: \002XLINE\002 [on|off]",
		'With no argument, displays the current state',
	],
	acl => 'xline',
	code => sub {
		my($src,$dst,$state) = @_;
		my $net = $src->homenet;
		return &Janus::jmsg($dst, "Local command only") if $net->jlink;
		$state = lc ($state || '');
		$enabled{$net->name} = 1 if $state eq 'on';
		$enabled{$net->name} = 0 if $state eq 'off';
		&Janus::jmsg($dst, $enabled{$net->name} ? 'Enabled' : 'Disabled');
	},
});

&Event::hook_add(
	XLINE => act => sub {
		my $act = shift;
		my $net = $act->{dst};
		my $t = uc $act->{ltype};
		$glines[$$net] ||= [];
		$zlines[$$net] ||= [];
		$qlines[$$net] ||= [];
		addline($glines[$$net], $act) if $t eq 'G';
		addline($zlines[$$net], $act) if $t eq 'Z';
		addline($qlines[$$net], $act) if $t eq 'Q';
	},
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef unless $net->isa('LocalNetwork');
		return undef if $$nick == 1;

		if (findline($qlines[$$net], $nick->homenick)) {
			$act->{tag} = 1;
		}

		return undef unless $enabled{$net->name};
		return undef if $nick->has_mode('oper');

		my $line;
		$line ||= findline($glines[$$net], $nick->info('ident').'@'.$nick->info('host'));
		$line ||= findline($zlines[$$net], $nick->info('ip'));

		if ($line) {
			if ($act->{for}) {
				&Event::append({
					type => 'MODE',
					src => $net,
					dst => $act->{for},
					dirs => [ '+' ],
					mode => [ 'ban' ],
					args => [ $nick->vhostmask ],
				});
			}
			$line->[3] =~ /^([^!]*)/;
			my $msg = 'Banned from '.$net->netname.' by '.$1;
			&Event::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => $msg,
			});
			return 1;
		}
		undef;
	}, NICK => 'act:-1' => sub {
		my $act = shift;
		my $n = $act->{dst};
		my $nick = $act->{nick};
		my $ftag = $act->{tag} || {};
		$act->{tag} = $ftag;
		for my $net ($n->netlist) {
			next if $net->jlink;
			next unless findline($qlines[$$net], $nick);
			next if $net == $n->homenet;
			$ftag->{$$net} = 1;
		}
	},
	INFO => 'Network:2' => sub {
		my($dst, $n, $asker) = @_;
		return undef unless $n->isa('LocalNetwork');
		my $enabled = $enabled{$n->name} ? 'enabled' : 'disabled';
		my $g = countline($glines[$$n]);
		my $z = countline($zlines[$$n]);
		my $q = countline($qlines[$$n]);
		&Janus::jmsg($dst, "\002X-lines\002: checks $enabled, recorded $g glines, $z zlines, $q qlines");
	},
);

1;
