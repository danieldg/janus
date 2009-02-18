# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Ban;
use strict;
use warnings;
use Util::Ban;

my %timespec = (
	m => 60,
	k => 1000,
	h => 3600,
	d => 86400,
	w => 604800,
	y => 365*86400,
);

Event::command_add({
	cmd => 'ban',
	help => 'Manages Janus bans (bans remote users)',
	section => 'Network',
	details => [
		'Bans are matched on connects to shared channels, and generate autokicks.',
		" \002ban list\002               List all active janus bans",
		" \002ban add\002 expr           Add a ban and applies it to current users",
		" \002ban nadd\002 expr          Add a ban (applied to new users only)",
		" \002ban del\002 index          Remove a ban by index in the ban list",
		'expr consists of one or more of the following:',
		'  (nick|ident|host|name|from) ? Matches the given item',
		'  /perl regex/                  Regex with implicit ^$, matched against nick!ident@host',
		'  x/perl regex/                 same, but against '."nick\!ident\@host\002\n\002src\002\t\002gecos",
		'  to (network|*)                Network(s) on which this ban is applied',
		'  for 2w4d12h5m2s               Time the ban is applied (0=perm, default=1 week)',
		'  reason "reason here"          Reason the ban was added',
		'Examples:',
		'  ban add host spam.botz.com for 3w reason "annoying bots"',
		'  ban add nick *|XP|* name "IP *" for 0 from evilnet reason "botnets not welcome"',
		'  ban add x/.*\|XP\|.*\nevilnet\tIP .*/ for 0 reason "same as above"',
		'  ban add /([a-z]{4}[0-9]{2})!\1@.*/ reason bot-nick',
	],
	acl => 'ban',
	aclchk => 'globalban',
	api => '=src =replyto $ @',
	code => sub {
		my($src,$dst,$cmd,@args) = @_;
		$cmd = lc $cmd;
		my $net = $src->homenet;
		my $gbl_ok = Account::acl_check($src, 'globalban');
		if ($cmd eq 'list') {
			my $c = 0;
			my @tbl = [ '', qw(expr setter to reason expire) ];
			@Util::Ban::all = grep { !$_->expire || $_->expire > $Janus::time } @Util::Ban::all;
			for my $ban (@Util::Ban::all) {
				my @row = ++$c;
				my $b = ''.$ban->match;
				1 while $b =~ s/^\(\?[-xism]+:(.*)\)$/$1/;
				my $x = $b =~ s/\\n\.\*\\t\.\*$// ? '' : 'x';
				push @row, "$x/$b/", map { $_ || '*' } $ban->setter, $ban->to, $ban->reason;
				if ($ban->expire) {
					push @row, ($ban->expire - $Janus::time).'s ('.gmtime($ban->expire).')';
				} else {
					push @row, 'Permanent, set at '.gmtime($ban->setat);
				}
				push @tbl, \@row;
			}
			Interface::msgtable($dst, \@tbl) if @tbl > 1;
			Janus::jmsg($dst, 'No bans defined') if @tbl == 1;
		} elsif ($cmd eq 'add' || $cmd eq 'nadd') {
			my %ban = (
				setter => $src->netnick,
				setat => $Janus::time,
				to => $net->name,
				'for' => Setting::get(ban_time => $Interface::network),
				nick => '*',
				ident => '*',
				host => '*',
				name => '*',
				from => '*',
			);
			local $_ = join ' ', @args;
			while (length) {
				if (s#^(nick|ident|host|name|to|from|for|reason)\s+((?:"(?:[^\\"]|\\.)*"|\S+))\s*##i) {
					my $k = lc $1;
					my $v = $2;
					$v =~ s/^"(.*)"$/$1/ and $v =~ s/\\(.)/$1/g;
					$ban{$k} = $v;
					delete $ban{$k} if $v eq '*';
					return Janus::jmsg($dst, 'You cannot specify "to"') if
						$k eq 'to' && $v ne $net->name && !$gbl_ok;
				} elsif (s#^(x?)/((?:[^\\/]|\\.)*)/\s*##) {
					eval {
						$ban{match} = $1 ? qr($2)s : qr($2\n.*\t.*)s;
						1;
					} or do {
						Janus::jmsg($dst, "Could not parse: $@");
						return;
					};
				} else {
					return Janus::jmsg($dst, 'Invalid syntax for ban');
				}
			}
			if ($ban{for}) {
				$_ = $ban{for};
				my $t = $Janus::time;
				$t += $1*($timespec{lc $2} || 1) while s/^(\d+)(\D?)//;
				$ban{expire} = $t;
				if ($_) {
					Janus::jmsg($dst, 'Invalid characters in ban length');
					return;
				}
			} else {
				$ban{expire} = 0;
			}
			if (!$ban{match}) {
				$ban{hre} = $ban{host};
				for (qw(nick ident hre from name)) {
					$ban{$_} =~ s/(\W)/\\$1/g;
					$ban{$_} =~ s/\\\*/.*/g;
					$ban{$_} =~ s/\\\?/./g;
				}
				$ban{match} = qr($ban{nick}\!$ban{ident}\@$ban{hre}\n$ban{from}\t$ban{name});
			}
			return Janus::jmsg($dst, 'Ban too wide') if "\!\@\n\t" =~ /^$ban{match}$/;
			delete $ban{to} if $ban{to} eq '*';
			delete $ban{host} if $ban{host} =~ /[*?]/;
			my $ban = Util::Ban->new(%ban);
			$ban->add();
			$ban->scan($net) if $cmd eq 'add';
			Janus::jmsg($dst, 'Ban added');
		} elsif ($cmd eq 'del') {
			my(@yes,@no);
			for (@args) {
				my $ban = /^\d+$/ && $Util::Ban::all[$_ - 1];
				if ($ban && ($gbl_ok || $ban->to eq $net->name)) {
					push @yes, $_;
					$ban->remove;
				} else {
					push @no, $_;
				}
			}
			Janus::jmsg($dst, "Removed @yes") if @yes;
			Janus::jmsg($dst, "Could not remove @no") if @no;
		} else {
			Janus::jmsg($dst, 'Invalid syntax. See "help ban" for the syntax');
		}
	}
});

Event::setting_add({
	name => 'ban_time',
	type => 'Interface',
	help => 'Default length of janus ban',
	default => '1w',
});

1;
