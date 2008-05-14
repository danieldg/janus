# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Services;
use strict;
use warnings;
use Persist;

use constant {
	CACHED => 1,
	NO_MSG => 2,
	NO_KILL_UNTAG => 4,
	NO_KILL_ALL => 8,
	JOIN_ALL => 16,
};

our @cache;
&Persist::register_vars('Nick::cache' => \@cache);

sub svs_type {
	my $n = shift;
	my $r = $cache[$$n] || 0;
	return $r if $r;

	my $net = $n->homenet();
	my $srv = $n->info('home_server');
	if ($net->jlink() || !$srv) {
		return ($cache[$$n] = CACHED);
	}
	
	# Is this nick on a services server?
	my $svs_srv = $net->param('services_servers');
	if ($svs_srv) {
		my @srvs = split /,/, $svs_srv;
		unless (grep $_ eq $srv, @srvs) {
			return ($cache[$$n] = CACHED);
		}
	} else {
		unless ($srv =~ /^(stats|services?|defender)\..*\./) {
			return ($cache[$$n] = CACHED);
		}
	}

	my $nick = lc $n->homenick();

	$r = $net->param('service_'.$nick);

	return ($cache[$$n] = $r) if defined $r; # TODO make this symbolic rather than numeric

	$r = CACHED | NO_MSG | NO_KILL_UNTAG;
	
	my $share = $net->param('services_shared') || '';

	if (grep $_ eq $nick, split /,/, $share) {
		$r = CACHED | JOIN_ALL | NO_KILL_UNTAG;
	}
	$r |= NO_KILL_ALL if $nick eq 'nickserv';

	$cache[$$n] = $r;
}

&Janus::hook_add(
	MSG => check => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return 1 if $act->{msgtype} eq '439' || $act->{msgtype} eq '931';
		return undef unless $src->isa('Nick') && $dst->isa('Nick');
		return 1 if svs_type($src) & NO_MSG;
		return 1 if svs_type($dst) & NO_MSG;
		undef;
	}, KILL => check => sub {
		my $act = shift;
		my($src,$nick,$net) = @$act{qw(src dst net)};
		return undef unless $src && $src->isa('Nick');
		my $type = svs_type $src;
		if ($type & NO_KILL_ALL) {
			# bounce all
		} elsif ($type & NO_KILL_UNTAG) {
			return undef unless $nick->homenick() eq $nick->str($net);
		} else {
			return undef;
		}
		&Janus::append(+{
			type => 'RECONNECT',
			src => $src,
			dst => $nick,
			net => $net,
			killed => 1,
		});
		1;
	}, NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		return unless svs_type($nick) & JOIN_ALL;
		for my $net (values %Janus::nets) {
			next if $nick->is_on($net);
			&Janus::append({
				type => 'CONNECT',
				dst => $nick,
				net => $net,
				tag => 1,
			});
		}
	}, NETLINK => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		my @out;
		for my $nick (values %Janus::gnicks) {
			next unless svs_type($nick) & JOIN_ALL;
			next if $nick->is_on($net);
			push @out, {
				type => 'CONNECT',
				dst => $nick,
				net => $net,
				tag => 1,
			};
		}
		&Janus::insert_full(@out) if @out;
	}, CHATOPS => check => sub {
		my $act = shift;
		if ($act->{src} == $Interface::janus) {
			return 1 if $Conffile::netconf{set}{silent};
		}
		undef;
	},
);

1;
