# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Ban;
use Persist;
use strict;
use warnings;

my %bans;

&Janus::save_vars(bans => \%bans);

sub banlist {
	my $net = shift;
	my $list = $bans{$net->name()};
	return () unless $list;
	my @good;
	for my $ban (@$list) {
		my $exp = $ban->{expire};
		unless ($exp && $exp < $Janus::time) {
			push @good, $ban;
		}
	}
	$bans{$net->name()} = \@good;
	@good;
}

sub re {
	my($x,$i) = @_;
	$x =~ s/(\W)/\\$1/g;
	$x =~ s/\\\*/.*/g;
	$x =~ s/\\\?/./g;
	$i =~ /^$x$/;
}

sub match {
	my($ban,$nick) = @_;
	my($n,$i,$h,$t) = $ban->{expr} =~ /(.*)\!(.*)\@(.*)\%(.*)/ or return 0;
	return 0 unless re($n, $nick->homenick());
	return 0 unless re($i, $nick->info('ident'));
	return 0 unless re($t, $nick->homenet()->name());
	for (qw/host vhost ip/) {
		my $hm = $nick->info($_) or next;
		return 1 if re($h,$hm);
	}
	return 0;
}

my %timespec = (
	m => 60,
	k => 1000,
	h => 3600,
	d => 86400,
	w => 604800,
	y => 365*86400,
);

&Janus::command_add({
	cmd => 'ban',
	help => 'Manages Janus bans (bans remote users)',
	details => [
		'Bans are matched against nick!ident@host%netid on any remote joins to a shared channel',
		'Syntax is the same as a standard IRC ban',
		'Expiration can be of the form 1y1w3d4h5m6s, or just # of seconds, or 0 for a permanent ban',
		" \002ban list\002                      List all active janus bans on your network",
		" \002ban add\002 expr length reason    Add a ban (applied to new users only)",
		" \002ban kadd\002 expr length reason   Add a ban, and kill all users matching it",
		" \002ban del\002 [expr|index]          Remove a ban by expression or index in the ban list",
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my($cmd, @arg) = split /\s+/, shift;
		return &Janus::jmsg($nick, "use 'help ban' to see the syntax") unless $cmd;
		my $net = $nick->homenet();
		my @list = banlist($net);
		if ($cmd =~ /^l/i) {
			my $c = 0;
			for my $ban (@list) {
				my $expire = $ban->{expire} ? 
					'expires in '.($ban->{expire} - $Janus::time).'s ('.gmtime($ban->{expire}) .')' :
					'does not expire';
				$c++;
				&Janus::jmsg($nick, $c.' '.$ban->{expr}.' - set by '.$ban->{setter}.", $expire - ".$ban->{reason});
			}
			&Janus::jmsg($nick, 'No bans defined') unless @list;
		} elsif ($cmd =~ /^k?a/i) {
			unless ($arg[2]) {
				&Janus::jmsg($nick, 'Use: ban add expression duration reason');
				return;
			}
			local $_ = $arg[1];
			my $t;
			my $reason = join ' ', @arg[2..$#arg];
			if ($_) {
				$t = $Janus::time;
				$t += $1*($timespec{lc $2} || 1) while s/^(\d+)(\D?)//;
				if ($_) {
					&Janus::jmsg($nick, 'Invalid characters in ban length');
					return;
				}
			} else { 
				$t = 0;
			}
			my $ban = {
				expr => $arg[0],
				expire => $t,
				reason => $reason,
				setter => $nick->homenick(),
			};
			push @{$bans{$net->name()}}, $ban;
			if ($cmd =~ /^a/i) {
				&Janus::jmsg($nick, 'Ban added');
			} else {
				my $c = 0;
				for my $n ($net->all_nicks()) {
					next if $n->homenet() eq $net;
					next unless match($ban,$n);
					&Janus::append(+{
						type => 'KILL',
						dst => $n,
						net => $net,
						msg => 'Banned by '.$net->netname().": $reason",
					});
					$c++;
				}
				&Janus::jmsg($nick, "Ban added, $c nick(s) killed");
			}
		} elsif ($cmd =~ /^d/i) {
			for (@arg) {
				my $ban = /^\d+$/ ? $list[$_ - 1] : find($net,$_);
				if ($ban) {
					&Janus::jmsg($nick, 'Ban '.$ban->{expr}.' removed');
					$ban->{expire} = 1;
				} else {
					&Janus::jmsg($nick, "Could not find ban $_ - use ban list to see a list of all bans");
				}
			}
		}
	}
});
&Janus::hook_add(
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink();
		return undef if $nick->has_mode('oper');

		for my $ban (banlist($net)) {
			next unless match($ban,$nick);

			&Janus::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => "Banned by ".$net->netname().": $ban->{reason}",
			});
			return 1;
		}
		undef;
	},
);

1;
