# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Util::Ban;
use Persist;
use strict;
use warnings;

our(@to,@match,@host,@setter,@reason,@expire,@setat);
Persist::register_vars(qw(to match host setter reason expire setat));
Persist::autoinit(qw(to match host setter reason expire setat));
Persist::autoget(qw(to match setter reason expire setat));
our(@mask);
Persist::register_vars('Nick::mask' => \@mask);

our @all;
sub save_all {
	[ map Persist::freeze($_), @all ]
}

Janus::save_vars(all => \&save_all);

# "to host" => [ bans ]
our(%nh_hit, @nh_miss, $nh_ok) = ();
Janus::static(qw(nh_hit nh_miss nh_ok));

sub _init {
	my $ban = shift;
	my $mt = ''.$match[$$ban];
	if ($mt =~ /^\(\?-xism:.*\)$/) {
		1 while $mt =~ s/^\(\?-xism:(.*)\)$/$1/;
		$match[$$ban] = qr/$mt/;
	}
}

sub mask {
	my $n = shift;
	return $mask[$$n] if $mask[$$n];
	my $nick = $n->homenick;
	my $ident = $n->info('ident');
	my $host = $n->info('host');
	my $name = $n->info('name');
	my $from = $n->homenet->name;
	my $retxt = "$nick\!$ident\@$host\n$from\t$name";
	return ($mask[$$n] = $retxt);
}

sub matches {
	my($b,$n,$t) = @_;
	return 0 if $to[$$b] && $to[$$b] ne $t;
	my $mask = mask $n;
	return 0 unless $mask =~ /^$match[$$b]$/;
	return 0 if $expire[$$b] && $expire[$$b] < $Janus::time;
	return 1;
}

sub add {
	my $ban = $_[0];
	my $h = $host[$$ban];
	my $t = $to[$$ban];
	if (!$h || !$t) {
		push @nh_miss, $ban;
	} elsif ($nh_hit{$t.' '.$h}) {
		my $v = $nh_hit{$t.' '.$h};
		$nh_hit{$t.' '.$h} = [ $ban, ('ARRAY' eq ref $v ? @$v : $v) ];
	} else {
		$nh_hit{$t.' '.$h} = $ban;
	}
	push @all, $ban;
}

sub remove {
	my $ban = shift;
	$expire[$$ban] = 1;
}

sub gen_nh {
	return if $nh_ok && $nh_ok > $Janus::time;
	$nh_ok = $Janus::time + 3600;
	my @old = @all;
	@nh_miss = ();
	%nh_hit = ();
	@all = ();
	for my $ban (@old) {
		my $e = $expire[$$ban];
		next if $e && $e < $Janus::time;
		add $ban;
	}
}

sub find {
	my($nick,$to) = @_;
	my $mask = mask $nick;
	my $host = $nick->info('host');
	gen_nh;
	my $hit = $nh_hit{$to.' '.$host};
	if ($hit) {
		for my $ban ('ARRAY' eq ref $hit ? @$hit : $hit) {
			next unless $mask =~ /^$match[$$ban]$/;
			next unless $ban->matches($nick, $to);
			return $ban;
		}
	}
	for my $ban (@nh_miss) {
		next unless $mask =~ /^$match[$$ban]$/;
		next unless $ban->matches($nick, $to);
		return $ban;
	}
	return undef;
}

sub scan {
	my($ban,$net) = @_;
	my @kills;
	for my $nick ($net->all_nicks) {
		next if $nick->has_mode('oper');
		next unless $ban->matches($nick,$to[$$ban]);
		push @kills, {
			type => 'KILL',
			dst => $nick,
			net => $net,
			msg => 'Banned by '.$setter[$$ban],
		};
	}
	Event::append(@kills);
}

Event::hook_add(
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink() || $net == $Interface::network;
		return undef if $nick->has_mode('oper');

		my $ban = find($nick, $net->name);
		return undef unless $ban;

		if ($act->{for}) {
			Event::append({
				type => 'MODE',
				src => $net,
				dst => $act->{for},
				dirs => [ '+' ],
				mode => [ 'ban' ],
				args => [ $nick->vhostmask ],
			});
		}
		Event::append(+{
			type => 'KILL',
			dst => $nick,
			net => $net,
			msg => 'Banned by '.$setter[$$ban],
		});
		1;
	},
);

1;
