# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Modes;
use strict;
use warnings;
use Data::Dumper;
use Modes;

&Janus::command_add({
	cmd => 'showmode',
	help => 'Shows the current intended modes of a channel',
	details => [
		"\002SHOWMODE\002 #channel - shows the intended modes of the channel on your network",
	],
	code => sub {
		my($nick,$args) = @_;
		my $hn = $nick->homenet();
		$args =~ /^(#\S*)/i or return &Janus::jmsg($nick, 'Syntax: SHOWMODE #chan');
		my $cname = $1;
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner or oper to use this command");
			return;
		}
		if ($hn->isa('LocalNetwork')) {
			my @modes = &Modes::to_multi($hn, &Modes::delta(undef, $chan), 0, 400);
			&Janus::jmsg($nick, join ' ', $cname, @$_) for @modes;
		}
		
		my $modeh = $chan->all_modes();
		unless ($modeh && scalar %$modeh) {
			&Janus::jmsg($nick, "No modes set on $cname");
			return;
		}
		my $out = '';
		for my $mk (sort keys %$modeh) {
			my $t = $Modes::mtype{$mk} || '?';
			my $mv = $modeh->{$mk};
			if ($t eq 'r') {
				$out .= ' '.$mk.('+'x($mv - 1));
			} elsif ($t eq 'v') {
				$out .= ' '.$mk.'='.$mv;
			} elsif ($t eq 'l') {
				$out .= join ' ', '', $mk.'={', @$mv, '}';
			} else {
				&Debug::err("bad mode $mk:$mv - $t?\n");
			}
		}
		&Janus::jmsg($nick, $cname.$1) while $out =~ s/(.{300,450}) / /;
		&Janus::jmsg($nick, $cname.$out);
	},
}, {
	cmd => 'showtopic',
	help => 'Shows the current intended topic of a channel',
	details => [
		"\002SHOWTOPIC\002 #channel - shows the intended topic of the channel on your network",
	],
	code => sub {
		my($nick,$args) = @_;
		my $hn = $nick->homenet();
		$args =~ /^(#\S*)/i or return &Janus::jmsg($nick, 'Syntax: SHOWMODE [raw] #chan');
		my $cname = $1;
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		my $top = $chan->topic();
		&Janus::jmsg($nick, $cname . ' ' . $top);
	},
}, {
	cmd => 'setmode',
	help => 'Sets a mode by its long name',
	details => [
		"\002SETMODE\002 #channel +mode1 -mode2 mode3=value",
	],
	code => sub {
		my($nick,$args) = @_;
		my $hn = $nick->homenet();
		$args =~ s/^(#\S*)\s+//i or return &Janus::jmsg($nick, 'Syntax: SETMODE #chan modes');
		my $cname = $1;
		return &Janus::jmsg($nick, 'Local command') unless $hn->isa('LocalNetwork');
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner or oper to use this command");
			return;
		}
		my(@modes,@args,@dirs);
		for (split /\s+/, $args) {
			/^([-+]+)([^=]+)(?:=(.+))?$/ or do {
				&Janus::jmsg($nick, "Invalid mode $_");
				return;
			};
			my($d,$txt,$v) = ($1,$2,$3);
			my $type = $Modes::mtype{$txt} or do {
				&Janus::jmsg($nick, "Unknown mode $txt");
				return;
			};
			if ($type eq 'r') {
				if ($d =~ /-+/) {
					$v = $chan->get_mode($txt);
					$d = '-';
				} else {
					$v = length $d;
					$d = '+';
				}
			} elsif ($type eq 'n') {
				$v = $hn->nick($v) or do {
					&Janus::jmsg($nick, "Cannot find nick");
					return;
				};
			}
			if ($type eq 'v' && $d eq '-') {
				$v = $chan->get_mode($txt);
			}
			if (length $d > 1 || !defined $v) {
				&Janus::jmsg($nick, "Invalid mode $_");
				return;
			}
			unshift @dirs, $d;
			unshift @modes, $txt;
			unshift @args, $v;
		}
		if (@dirs) {
			&Janus::append(+{
				type => 'MODE',
				src => $Interface::janus,
				dst => $chan,
				mode => \@modes,
				args => \@args,
				dirs => \@dirs,
			});
			&Janus::jmsg($nick, 'Done');
		} else {
			&Janus::jmsg($nick, 'Nothing to do');
		}
	},
});

1;
