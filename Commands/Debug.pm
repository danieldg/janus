# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
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
		my $ts = $Janus::time;
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
});

1;
