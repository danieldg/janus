# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Vanish;
use Persist;
use strict;
use warnings;

my @regex  :Persist(regex);
my @expr   :Persist(expr)   :Arg(expr)   :Get(expr);
my @setter :Persist(setter) :Arg(setter) :Get(setter);
my @expire :Persist(expire) :Arg(expire) :Get(expire);
my @reason :Persist(reason) :Arg(reason) :Get(reason);

my @bans   :PersistAs(Network,bans);

sub find {
	my($net, $iexpr) = @_;
	for my $ban (@{$bans[$$net]}) {
		$expr[$$ban] eq $iexpr and return $ban;
	}
	undef;
}

sub _init {
	my($ban,$args) = @_;
	my $net = $args->{net};
	push @{$bans[$$net]}, $ban;

	local $_ = $ban->expr();
	unless (s/^~//) { # all expressions starting with a ~ are raw perl regexes
		s/(\W)/\\$1/g;
		s/_/[ _]/g;  # _ matches space or _
		s/\\\?/./g;  # ? matches one char
		s/\\\*/.*/g; # * matches any chars
	}
	$regex[$$ban] = qr/^$_$/i; # compile the regex now for faster matching later
}

sub banlist {
	my $net = shift;
	my $list = $bans[$$net];
	return () unless $list;
	my @good;
	for my $ban (@$list) {
		my $exp = $expire[$$ban];
		unless ($exp && $exp < $Janus::time) {
			push @good, $ban;
		}
	}
	$bans[$$net] = \@good;
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
		my $tail = '%'.$nick->homenet()->name().':'.$nick->info('name');
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
	cmd => 'vanish',
	help => "\002DANGEROUS\002 manages Janus vanish bans",
	details => [
		'Vanish bans are matched against nick!ident@host%netid:name on any remote joins',
		'Expressions are either a string with * and ? being wildcards, or ~ followed by',
		'any perl regex which matches the entire string',
		'Expiration can be of the form 1y1w3d4h5m6s, or just # of seconds, or 0 for a permanent ban',
		"This \002will\002 cause apparent desyncs and one-sided conversations.",
		" \002vanish list\002                      List all active janus bans on your network",
		" \002vanish add\002 expr length reason    Add a ban (applied to new users only)",
		" \002vanish del\002 [expr|index]          Remove a ban by expression or index in the ban list",
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my($cmd, @arg) = split /\s+/, shift;
		return &Janus::jmsg($nick, "use 'help vanish' to see the syntax") unless $cmd;
		my $net = $nick->homenet();
		my @list = banlist($net);
		if ($cmd =~ /^l/i) {
			my $c = 0;
			for my $ban (@list) {
				my $expire = $ban->expire() ? 
					'expires in '.($ban->expire() - $Janus::time).'s ('.gmtime($ban->expire()) .')' :
					'does not expire';
				$c++;
				&Janus::jmsg($nick, $c.' '.$ban->expr().' - set by '.$ban->setter().", $expire - ".$ban->reason());
			}
			&Janus::jmsg($nick, 'No bans defined') unless @list;
		} elsif ($cmd =~ /^a/i) {
			unless ($arg[2]) {
				&Janus::jmsg($nick, 'Use: ban add $expr $duration $reason');
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
			my $ban = Modules::Vanish->new(
				net => $net,
				expr => $arg[0],
				expire => $t,
				reason => $reason,
				setter => $nick->homenick(),
			);
			&Janus::jmsg($nick, 'Ban added');
		} elsif ($cmd =~ /^d/i) {
			for (@arg) {
				my $ban = /^\d+$/ ? $list[$_ - 1] : find($net,$_);
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
		return undef if $net->jlink();

		for my $ban (banlist($net)) {
			next unless $ban->match($nick);

			return 1;
		}
		undef;
	}, MSG => check => sub {
		my $act = shift;
		my $src = $act->{src} or return undef;
		my $dst = $act->{dst} or return undef;
		if ($src->isa('Nick') && $dst->isa('Channel')) {
			return undef if $act->{sendto};
			my @to = $dst->sendto($act);
			$act->{sendto} = [ grep { $src->is_on($_) } @to ];
		}
		undef;
	},
);

1;
