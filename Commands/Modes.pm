# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Modes;
use strict;
use warnings;
use Data::Dumper;
use Modes;

our($VERSION) = '$Rev$' =~ /(\d+)/;

sub guess_pre {
	my($chan, $m) = @_;
	return "l_$m" if $m eq 'ban' || $m eq 'except' || $m eq 'invex';
	return "v_$m";
}

&Janus::command_add({
	cmd => 'showmode',
	help => 'Shows the current intended modes of a channel',
	details => [
		"\002SHOWMODE\002 #channel - shows the intended modes of the channel on your network",
		"\002SHOWMODE RAW\002 #channel - shows the internal (textual) modes of the channel",
	],
	code => sub {
		my($nick,$args) = @_;
		my $hn = $nick->homenet();
		return &Janus::jmsg($nick, 'Local command only') unless $hn->isa('LocalNetwork');
		$args =~ /^(raw )?(#\S*)/i or return &Janus::jmsg($nick, 'Syntax: SHOWMODE [raw] #chan');
		my($raw,$cname) = ($1,$2);
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(n_owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner or oper to use this command");
			return;
		}
		if ($raw) {
			my $modeh = $chan->all_modes() or return;
			my $out = $cname;
			for my $mk (sort keys %$modeh) {
				my $mv = $modeh->{$mk};
				$mk =~ /^(.)_(.+)/ or warn $mk;
				if ($1 eq 'r') {
					$out .= ' '.$2.('+'x($mv - 1));
				} elsif ($1 eq 'v') {
					$out .= ' '.$2.'='.$mv;
				} elsif ($1 eq 'l') {
					$out .= join ' ', '', $2.'={', @$mv, '}';
				}
			}
			&Janus::jmsg($nick, $1) while $out =~ s/(.{,450}) //;
			&Janus::jmsg($nick, $out);
		} else {
			my @modes = &Modes::to_multi($hn, &Modes::delta(undef, $chan), 0, 400);
			&Janus::jmsg($nick, join ' ', $chan->str($hn), @$_) for @modes;
		}
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
		return &Janus::jmsg($nick, 'Local command only') unless $hn->isa('LocalNetwork');
		$args =~ s/^(#\S*)\s+//i or return &Janus::jmsg($nick, 'Syntax: SETMODE #chan modes');
		my $cname = $1;
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		unless ($chan->has_nmode(n_owner => $nick) || $nick->has_mode('oper')) {
			&Janus::jmsg($nick, "You must be a channel owner or oper to use this command");
			return;
		}
		my(@modes,@args,@dirs);
		for (split /\s+/, $args) {
			if (/^-([^=]+)(?:=(.+))?$/) {
				if (length $2) {
					unshift @modes, 'l_'.$1;
					unshift @args, $2;
					unshift @dirs, '-';
				} else {
					for my $pfx (qw/r v/) {
						my $m = $chan->get_mode($pfx.'_'.$1);
						next unless defined $m;
						unshift @modes, $pfx.'_'.$1;
						unshift @args, $m;
						unshift @dirs, '-';
					}
				}
			} elsif (/^(\++)([^=]+)$/) {
				unshift @modes, 'r_'.$2;
				unshift @args, length($1);
				unshift @dirs, '+';
			} elsif (/^\+?([^-+=]+)=(.+)$/) {
				my $pre = guess_pre($chan, $1);
				unshift @modes, $pre;
				unshift @args, $2;
				unshift @dirs, '+';
			}
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
		}
	},
});

1;
