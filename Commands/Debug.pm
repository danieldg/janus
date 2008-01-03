# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;
use Modes;

our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	acl => 1,
	code => sub {
		my $nick = shift;
		my $ts = time;
		# workaround for a bug in Data::Dumper that only allows one "new" socket per dump
		eval {
			Data::Dumper::Dumper(\%Connection::queues);
		} for values %Connection::queues;
		open my $dump, '>', "log/dump-$ts" or return;
		my @all = (
			\%Janus::gnicks,
			\%Janus::gchans,
			\%Janus::nets,
			\%Janus::ijnets,
			\%Janus::gnets,
			\%Connection::queues,
			&Persist::dump_all_refs(),
		);
		local $Data::Dumper::Sortkeys = 1;
		print $dump Data::Dumper::Dumper(\@all);
		close $dump;
		&Janus::jmsg($nick, 'State dumped to file log/dump-'.$ts);
	},
}, {
	cmd => 'showmode',
	help => 'Shows the current intended modes of a channel',
	details => [
		"\002SHOWMODE\002 #channel - shows the intended modes of the channel on your network",
		"\002SHOWMODE RAW\002 #channel - shows the internal (textual) modes of the channel",
	],
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		my $hn = $nick->homenet();
		return &Janus::jmsg($nick, 'Local command only') unless $hn->isa('LocalNetwork');
		$args =~ /^(raw )?(#\S*)/i or return &Janus::jmsg($nick, 'Syntax: SHOWMODE [raw] #chan');
		my($raw,$cname) = ($1,$2);
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
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
});

1;
