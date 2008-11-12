# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modules::Ban;
use Persist;
use strict;
use warnings;

our @bans;
&Janus::save_vars(bans => \@bans);

# ban => {
#	to     comma-split netnames, ban is on connect to the network
#	from   comma-split netnames, ban is on those from the network
#	nick   iRE for nick
#	ident  iRE for ident
#	host   iRE for host
#	name   iRE for name
#	setter realhostmask of setter
#	reason reason
#	perlre anchored match against "nick!ident@host:name"
#   expire timestamp of expiration, 0 for perm
# }
# iRE := HOSTMASK_CHARS | "*" | "?"

sub ire {
	my($x,$i) = @_;
	return 1 unless defined $x;
	return 0 unless defined $i;
	$x =~ s/(\W)/\\$1/g;
	$x =~ s/\\\*/.*/g;
	$x =~ s/\\\?/./g;
	$i =~ /^$x$/;
}

sub find {
	my($new, $netto) = @_;
	my $to = $netto->name;
	my $from = $new->homenet->name;
	$to = qr/(^|,)$to(,|$)/;
	$from = qr/(^|,)$from(,|$)/;
	my $nick = $new->homenick;
	my $ident = $new->info('ident');
	my $host = $new->info('host');
	my $ip = $new->info('ip');
	my $name = $new->info('name');
	my $retxt = "$nick\!$ident\@$host\:$name";
	@bans = grep { my $e = $_->{expire}; !$e || $e > $Janus::time } @bans;
	for my $b (@bans) {
		next if $b->{to} && $b->{to} !~ /$to/;
		next if $b->{from} && $b->{from} !~ /$from/;
		next if $b->{perlre} && $retxt !~ /^$b->{perlre}$/;
		next unless ire($b->{nick}, $nick);
		next unless ire($b->{ident}, $ident);
		next unless ire($b->{host}, $host) || ire($b->{host}, $ip);
		next unless ire($b->{name}, $name);
		# it matches
		return $b;
	}
	undef;
}

my %timespec = (
	m => 60,
	k => 1000,
	h => 3600,
	d => 86400,
	w => 604800,
	y => 365*86400,
);

&Event::command_add({
	cmd => 'ban',
	help => 'Manages Janus bans (bans remote users)',
	section => 'Network',
	details => [
		'Bans are matched on connects to shared channels, and generate autokicks.',
		" \002ban list\002               List all active janus bans",
		" \002ban add\002 expr           Add a ban (applied to new users only)",
		" \002ban del\002 index          Remove a ban by index in the ban list",
		'expr consists of one or more of the following:',
		' (nick|ident|host|name) item    Matches using standard IRC ban syntax',
		' (to|from) (network|*)          Matches the source or destination network',
		' for 2w4d12h5m2s                Time the ban is applied (0=perm, default=1 week)',
		' /perl regex/                   Regex with implicit ^$, matched against nick!ident@host:name',
		' reason "reason here"           Reason the ban was added',
		'a nick must match all of the conditions on the ban to be banned.',
	],
	acl => 'ban',
	aclchk => 'globalban',
	code => sub {
		my($src,$dst,$cmd,@args) = @_;
		$cmd = lc $cmd;
		return &Janus::jmsg($src, "use 'help ban' to see the syntax") unless $cmd;
		my $net = $src->homenet;
		my $gbl_ok = &Account::acl_check($src, 'globalban');
		if ($cmd eq 'list') {
			my $c = 0;
			@bans = grep { my $e = $_->{expire}; !$e || $e > $Janus::time } @bans;
			my @tbl = [ '', qw(expr setter to reason expire) ];
			for my $ban (@bans) {
				my @row = ++$c;
				my @expr;
				if ($ban->{perlre}) {
					my $b = ''.$ban->{perlre};
					1 while $b =~ s/^\(\?-xism:(.*)\)$/$1/;
					push @expr, "/$b/";
					$ban->{perlre} = qr($b);
				}
				for (qw/nick ident host name from/) {
					next unless exists $ban->{$_};
					push @expr, "$_=$ban->{$_}";
				}
				push @row, join ' ', @expr;
				for (qw/setter to reason/) {
					push @row, ($ban->{$_} || '*');
				}
				if ($ban->{expire}) {
					push @row, ($ban->{expire} - $Janus::time).'s ('.gmtime($ban->{expire}).')';
				} else {
					push @row, 'Does not expire';
				}
				push @tbl, \@row;
			}
			&Interface::msgtable($dst, \@tbl) if @bans;
			&Janus::jmsg($dst, 'No bans defined') unless @bans;
		} elsif ($cmd eq 'add') {
			my %ban = (
				setter => $src->realhostmask,
				to => $net->name,
			);
			local $_ = join ' ', @args;
			while (length) {
				if (s#^(nick|ident|host|name|to|from|for|reason)\s+((?:"(?:[^\\"]|\\.)*"|\S+))\s*##i) {
					my $k = lc $1;
					my $v = $2;
					$v =~ s/^"(.*)"$/$1/ and $v =~ s/\\(.)/$1/g;
					$ban{$k} = $v;
					delete $ban{$k} if $v eq '*';
					return &Janus::jmsg($dst, 'You cannot specify "to"') if
						$k eq 'to' && $v ne $net->name && !$gbl_ok;
				} elsif (s#^/((?:[^\\/]|\\.)*)/\s*##) {
					eval {
						$ban{perlre} = qr($1);
						1;
					} or do {
						&Janus::jmsg($dst, "Could not parse: $@");
						return;
					};
				} else {
					return &Janus::jmsg($dst, 'Invalid syntax for ban');
				}
			}
			if ($ban{for}) {
				$_ = delete $ban{for};
				my $t = $Janus::time;
				$t += $1*($timespec{lc $2} || 1) while s/^(\d+)(\D?)//;
				$ban{expire} = $t;
				if ($_) {
					&Janus::jmsg($dst, 'Invalid characters in ban length');
					return;
				}
			} elsif (defined delete $ban{for}) {
				$ban{expire} = 0;
			} else {
				$ban{expire} = $Janus::time + 604800;
			}
			my $itms = 0;
			exists $ban{$_} and $itms++ for qw(nick ident host name perlre);
			return &Janus::jmsg($dst, 'Ban too wide') unless $itms;
			push @bans, \%ban;
			&Janus::jmsg($dst, 'Ban added');
			# TODO kadd
		} elsif ($cmd eq 'del') {
			for (@args) {
				my $ban = /^\d+$/ && $bans[$_ - 1];
				if ($ban) {
					if ($gbl_ok || $ban->{to} eq $net->name) {
						&Janus::jmsg($dst, "Ban $_ removed");
						$ban->{expire} = 1;
					} else {
						&Janus::jmsg($dst, "You cannot remove ban $_")
					}
				} else {
					&Janus::jmsg($dst, "Could not find ban $_ - use ban list to see a list of all bans");
				}
			}
		} else {
			&Janus::jmsg($dst, 'Invalid syntax. See "help ban" for the syntax');
		}
	}
});

&Event::hook_add(
	CONNECT => check => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $net = $act->{net};
		return undef if $net->jlink() || $net == $Interface::network;
		return undef if $nick->has_mode('oper');

		my $ban = find($nick, $net);
		if ($ban) {
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
			$ban->{setter} =~ /^(.*?)!/;
			my $msg = 'Banned from all janus channels by '.$1;
			if ($ban->{to}) {
				$msg = "Banned from ".$net->netname.' by '.$1;
			}
			&Event::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => $msg,
			});
			return 1;
		}
		undef;
	},
);

1;
