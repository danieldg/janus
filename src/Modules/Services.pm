# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Services;
use strict;
use warnings;
use Persist;

our %bits;
BEGIN { %bits = (
	CACHED        => 0x01,
	NO_MSG        => 0x02,
	JOIN_ALL      => 0x04,
	NO_KILL_ALL   => 0x08,
	KILL_LOOP     => 0x10,
	KILL_ALTNICK  => 0x20,
	KILL_ALTHOST  => 0x40,
); }
use constant \%bits;

# clear the cache on each module load, to force new values
our @cache = ();
our @loop;
&Persist::register_vars('Nick::cache' => \@cache, 'Nick::kloop' => \@loop);

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
		unless ($srv =~ /^(stats|services?|defender)\./) {
			return ($cache[$$n] = CACHED);
		}
	}

	my $nick = lc $n->homenick();

	$r = $net->param('service_'.$nick);
	if (defined $r) {
		my $v = CACHED;
		for (split /,/, $r) {
			$v |= $1 if /(\d+)/;
			$v |= $bits{uc $_} || 0;
		}
		return ($cache[$$n] = $v);
	}

	if ($nick eq 'nickserv') {
		$r = CACHED | NO_MSG | KILL_ALTNICK | NO_KILL_ALL;
	} elsif ($nick eq 'operserv') {
		$r = CACHED | NO_MSG | KILL_ALTHOST | KILL_LOOP;
	} else {
		$r = CACHED | NO_MSG | KILL_LOOP;
	}

	$cache[$$n] = $r;
}

&Event::hook_add(
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
		} elsif ($type & KILL_LOOP) {
			my $loop = $loop[$$nick] || '';
			my %expand;
			$expand{$1} = $2 while $loop =~ s/^(\S+)=(\d+)(,|$)//;
			my $count = ++$expand{$net->name};
			$loop[$$nick] = join ',', map { $_.'='.$expand{$_} } keys %expand;
			return undef if $count < 3;
		} else {
			return undef;
		}
		&Event::append(+{
			type => 'RECONNECT',
			src => $src,
			dst => $nick,
			net => $net,
			killed => 1,
			($type & KILL_ALTHOST ? (althost => 1) : ()),
			($type & KILL_ALTNICK ? (altnick => 1) : ()),
		});
		1;
	}, NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		return unless svs_type($nick) & JOIN_ALL;
		Event::append({
			type => 'NICKINFO',
			dst => $nick,
			item => noquit => value => 1,
		});
		for my $net (values %Janus::nets) {
			next if $nick->is_on($net);
			Event::append({
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
		&Event::insert_full(@out) if @out;
	}, CHATOPS => check => sub {
		my $act = shift;
		if ($act->{src} == $Interface::janus) {
			return 1 if $Conffile::netconf{set}{silent};
		}
		undef;
	},
	INFO => 'Nick:1' => sub {
		my($dst, $n, $asker) = @_;
		my $type = svs_type($n);
		my $v = '';
		for (sort keys %bits) {
			next if $_ eq 'CACHED';
			$v .= ' '.$_ if $bits{$_} & $type;
		}
		&Janus::jmsg($dst, "\002Modules::Services mask\002:$v") if $v;
	},
);

1;
