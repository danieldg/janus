# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Ban;
use Persist;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

our %netbans; # TODO consider saving these
my @regex  :Persist(regex);
my @expr   :Persist(expr)   :Arg(expr)   :Get(expr);
my @net    :Persist(net)    :Arg(net)    :Get(net);
my @setter :Persist(setter) :Arg(setter) :Get(setter);
my @expire :Persist(expire) :Arg(expire) :Get(expire);
my @reason :Persist(reason) :Arg(reason) :Get(reason);

sub add {
	my $ban = Commands::Ban->new(@_);
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

sub _init {
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
	my $list = $netbans{$net->id()};
	return () unless $list;
	my @good;
	for my $ban (@$list) {
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
	my($ban,@v) = @_;
	if (@v == 1 && ref $v[0]) {
		my $nick = shift @v;
		my $head = $nick->homenick().'!'.$nick->info('ident').'@';
		my $tail = '%'.$nick->homenet()->id().':'.$nick->info('name');
		push @v, $head . $nick->info('host') . $tail;
		push @v, $head . $nick->info('vhost') . $tail;
		push @v, $head . $nick->info('ip') . $tail;
	}
	for my $mask (@v) {
		return 1 if $mask =~ /$regex[$$ban]/;
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
		'Bans are matched against nick!ident@host%netid:name on any remote joins to a shared channel',
		'Expiration can be of the form 1y1w3d4h5m6s, or just # of seconds, or 0 for a permanent ban',
		" \002ban list\002                      List all active janus bans on your network",
		" \002ban add\002 expr length reason    Add a ban (applied to new users only)",
		" \002ban kadd\002 expr length reason   Add a ban, and kill all users matching it",
		" \002ban del\002 [expr|index]          Remove a ban by expression or index in the ban list",
	], code => sub {
		my $nick = shift;
		my($cmd, @arg) = split /\s+/, shift;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		return &Janus::jmsg($nick, "use 'help ban' to see the syntax") unless $cmd;
		my $net = $nick->homenet();
		my @list = banlist($net);
		if ($cmd =~ /^l/i) {
			my $c = 0;
			for my $ban (@list) {
				my $expire = $ban->expire() ? 
					'expires in '.($ban->expire() - time).'s ('.gmtime($ban->expire()) .')' :
					'does not expire';
				$c++;
				&Janus::jmsg($nick, $c.' '.$ban->expr().' - set by '.$ban->setter().", $expire - ".$ban->reason());
			}
			&Janus::jmsg($nick, 'No bans defined') unless @list;
		} elsif ($cmd =~ /^k?a/i) {
			unless ($arg[2]) {
				&Janus::jmsg($nick, 'Use: ban add $expr $duration $reason');
				return;
			}
			local $_ = $arg[1];
			my $t;
			my $reason = join ' ', @arg[2..$#arg];
			if ($_) {
				$t = time;
				$t += $1*($timespec{lc $2} || 1) while s/^(\d+)(\D*)//;
			} else { 
				$t = 0;
			}
			my $ban = &Commands::Ban::add(
				net => $net,
				expr => $arg[0],
				expire => $t,
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
				my $ban = /^\d+$/ ? $list[$_ - 1] : &Commands::Ban::find($net,$_);
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

		for my $ban (banlist($net)) {
			next unless $ban->match($nick);

			&Janus::append(+{
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
			&Commands::Ban::add(
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
