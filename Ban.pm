# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Ban;
use Persist;
use Object::InsideOut;
use strict;
use warnings;

__PERSIST__
persist %netbans;
persist @regex  :Field              :Get(regex);
persist @expr   :Field :Arg(expr)   :Get(expr);
persist @net    :Field :Arg(net)    :Get(net);
persist @setter :Field :Arg(setter) :Get(setter);
persist @expire :Field :Arg(expire) :Get(expire);
persist @reason :Field :Arg(reason) :Get(reason);

__CODE__

sub add {
	my $ban = Ban->new(@_);
	push @{$netbans{$ban->net()->id()}}, $ban;
	$ban;
}

sub find {
	my($net, $iexpr) = @_;
	for my $ban (@{$netbans{$net->id()}}) {
		$expr[$$ban] eq $iexpr and return $ban;
	}
	undef;
}

sub _init :Init {
	my $ban = shift;
	local $_ = $ban->expr();
	unless (s/^~//) { # all expressions starting with a ~ are raw perl regexes
		s/(\W)/\\$1/g;
		s/\\\?/./g;  # ? matches one char...
		s/\\\*/.*/g; # * matches any chars...
	}
	$regex[$$ban] = qr/^$_$/i; # compile the regex now for faster matching later
}

sub banlist {
	my $net = shift;
	my @list = @{$netbans{$net->id()} || []};
	my @good;
	for my $ban (@list) {
		my $exp = $expire[$$ban];
		unless ($exp && $exp < time) {
			push @good, $ban;
		}
	}
	$netbans{$net->id()} = \@good;
	@good;
}

sub delete {
	my $ban = shift;
	$expire[$$ban] = 1;
}

sub match {
	my($ban, $nick) = @_;
	my $mask = ref $nick ? 
		$nick->homenick().'!'.$nick->info('ident').'@'.$nick->info('host').'%'.$nick->homenet()->id().':'.$nick->info('name') :
		$nick;
	$mask =~ /$regex[$$ban]/;
}

&Janus::command_add({
	cmd => 'ban',
	help => [
		'Bans are matched against nick!ident@host%netid:name on any remote joins to a shared channel',
		' ban list - list all active janus bans',
		' ban add $expr $expire $reason - add a ban',
		' ban kadd $expr $expire $reason - add a ban, and kill all users matching it',
		' ban del $expr|$index - remove a ban by expression or index in the ban list',
	], code => sub {
		my $nick = shift;
		my($cmd, @arg) = split /\s+/, shift;
		return &Janus::jmsg("You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		my $net = $nick->homenet();
		my @list = banlist($net);
		if ($cmd =~ /^l/i) {
			my $c = 0;
			for my $ban (@list) {
				my $expire = $ban->expire() ? 'expires on '.gmtime($ban->expire()) : 'does not expire';
				$c++;
				&Janus::jmsg($nick, $c.' '.$ban->expr().' - set by '.$ban->setter().", $expire - ".$ban->reason());
			}
			&Janus::jmsg($nick, 'No bans defined') unless @list;
		} elsif ($cmd =~ /^k?a/i) {
			unless ($arg[1]) {
				&Janus::jmsg($nick, 'Use: ban add $expr $duration $reason');
				return;
			}
			my $reason = join ' ', @arg[2..$#arg];
			my $ban = &Ban::add(
				net => $net,
				expr => $arg[0],
				expire => $arg[1] ? $arg[1] + time : 0,
				reason => $reason,
				setter => $nick->homenick(),
			);
			if ($cmd =~ /^a/i) {
				&Janus::jmsg($nick, 'Ban added');
			} else {
				my $c = 0;
				for my $n ($net->all_nicks()) {
					next if $n->homenet()->id() eq $net->id();
					next unless $ban->match($n);
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
				my $ban = /^\d+$/ ? $list[$_ - 1] : &Ban::find($net,$_);
				if ($ban) {
					&Janus::jmsg($nick, 'Ban '.$ban->expr().' removed');
					$ban->delete();
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
		return undef if $net->jlink() || $act->{reconnect};

		my $mask = $nick->homenick().'!'.$nick->info('ident').'@'.$nick->info('host').'%'.$nick->homenet()->id().':'.$nick->info('name');
		for my $ban (banlist($net)) {
			next unless $ban->match($mask);
			Janus::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => "Banned by ".$net->netname().": $reason[$$ban]",
			});
			return 1;
		}
		undef;
	}, BANLINE => check => sub {
		my $act = shift;
		my $net = $act->{dst};
		return 1 unless $net->param('translate_bans');
		return undef;
	}, BANLINE => act => sub {
		my $act = shift;
		my $net = $act->{dst};
		my $nick = $act->{nick} || '*';
		my $ident = $act->{ident} || '*';
		my $host = $act->{host} || '*';
		my $expr = "$nick!$ident\@$host\%*";
		return if $expr eq '*!*@*%*';
		if ($act->{action} eq '+') {
			&Ban::add(
				net => $net,
				expr => $expr,
				reason => $act->{reason},
				expire => ($act->{expire} || 0),
				setter => $act->{setter},
			);
		} else {
			my $ban = find($expr);
			return unless $ban;
			$ban->delete();
		}
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		delete $netbans{$net->id()};
	},
);

1;
