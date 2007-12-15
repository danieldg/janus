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
	code => sub {
		my $nick = shift;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
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
		print $dump Data::Dumper::Dumper(\@all);
		close $dump;
		&Janus::jmsg($nick, 'State dumped to file log/dump-'.$ts);
	},
}, {
	cmd => 'showmode',
	help => 'Shows the current intended modes of a channel',
	code => sub {
		my($nick,$cname) = @_;
		my $hn = $nick->homenet();
		return &Janus::jmsg($nick, 'Local command only') unless $hn->isa('LocalNetwork');
		my $chan = $hn->chan($cname,0);
		return &Janus::jmsg($nick, 'That channel does not exist') unless $chan;
		my @modes = &Modes::to_multi($hn, &Modes::delta(undef, $chan), 0, 400);
		&Janus::jmsg($nick, join ' ', $chan->str($hn), @$_) for @modes;
	},
});

1;
