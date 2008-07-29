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

&Janus::command_add({
	cmd => 'ban',
	help => 'Manages Janus bans (bans remote users)',
	details => [
		'Bans are matched on connects to shared channels, and generate autokicks.',
		" \002ban list\002               List all active janus bans",
		" \002ban add\002 expr           Add a ban (applied to new users only)",
		" \002ban del\002 index          Remove a ban by index in the ban list",
		'expr consists of one or more of the following:',
		' (nick|ident|host|name) item    Matches using standard IRC ban syntax',
		' (to|from) (network|*)          Matches the source or destination network',
		' for 2w4d12h5m2s                Time the ban is applied (0=perm, default=1 week)',
		' /perl regex/                   Regex matched against nick!ident@host:name',
		' reason "reason here"           Reason the ban was added',
		'a nick must match all of the conditions on the ban to be banned.',
	],
	acl => 1,
	code => sub {
		my $nick = shift;
		my($cmd, $args) = split /\s+/, shift, 2;
		return &Janus::jmsg($nick, "use 'help ban' to see the syntax") unless $cmd;
		my $net = $nick->homenet;
		if ($cmd =~ /^l/i) {
			my $c = 0;
			@bans = grep { my $e = $_->{expire}; !$e || $e > $Janus::time } @bans;
			for my $ban (@bans) {
				my $str = ++$c;
				if ($ban->{perlre}) {
					my $b = ''.$ban->{perlre};
					1 while $b =~ s/^\(\?-xism:(.*)\)$/$1/;
					$str .= " /$b/";
					$ban->{perlre} = qr($b);
				}
				for (qw/nick ident host name setter reason to from/) {
					next unless exists $ban->{$_};
					$str .= " $_=$ban->{$_}";
				}
				$str .= $ban->{expire} ?
					' expires in '.($ban->{expire} - $Janus::time).'s ('.gmtime($ban->{expire}) .')' :
					' does not expire';
				&Janus::jmsg($nick, $str);
			}
			&Janus::jmsg($nick, 'No bans defined') unless @bans;
		} elsif ($cmd =~ /^k?a/i) {
			my %ban = (
				setter => $nick->realhostmask,
				to => $nick->homenet,
			);
			local $_ = $args;
			while (length) {
				if (s#^(nick|ident|host|name|to|from|for|reason)\s+((?:"(?:[^\\"]|\\.)*"|\S+))\s*##i) {
					my $k = lc $1;
					my $v = $2;
					$v =~ s/^"(.*)"$/$1/ and $v =~ s/\\(.)/$1/g;
					$ban{$k} = $v;
					delete $ban{$k} if $v eq '*';
				} elsif (s#^/((?:[^\\/]|\\.)*)/\s*##) {
					$ban{perlre} = qr($1);
				} else {
					return &Janus::jmsg($nick, 'Invalid syntax for ban');
				}
			}
			if ($ban{for}) {
				$_ = delete $ban{for};
				my $t = $Janus::time;
				$t += $1*($timespec{lc $2} || 1) while s/^(\d+)(\D?)//;
				$ban{expire} = $t;
				if ($_) {
					&Janus::jmsg($nick, 'Invalid characters in ban length');
					return;
				}
			} elsif (defined delete $ban{for}) {
				$ban{expire} = 0;
			} else {
				$ban{expire} = $Janus::time + 604800;
			}
			my $itms = 0;
			exists $ban{$_} and $itms++ for qw(nick ident host name perlre);
			return &Janus::jmsg($nick, 'Ban too wide') unless $itms;
			push @bans, \%ban;
			&Janus::jmsg($nick, 'Ban added');
			# TODO kadd
		} elsif ($cmd =~ /^d/i) {
			for (split /\s+/, $args) {
				my $ban = /^\d+$/ && $bans[$_ - 1];
				if ($ban) {
					&Janus::jmsg($nick, "Ban $_ removed");
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

		my $ban = find($nick, $net);
		if ($ban) {
			if ($act->{for}) {
				&Janus::append({
					type => 'MODE',
					src => $net,
					dst => $act->{for},
					dirs => [ '+' ],
					mode => [ 'ban' ],
					args => [ $nick->vhostmask ],
				});
			}
			&Janus::append(+{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => "Banned by ".$net->netname,
			});
			return 1;
		}
		undef;
	},
);

1;
