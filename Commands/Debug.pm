# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;
use Modes;

sub dump_now {
	# workaround for a bug in Data::Dumper that only allows one "new" socket per dump
	for (values %Connection::queues) {
		eval { Data::Dumper::Dumper(\%Connection::queues); 1 } and last;
	}

	open my $dump, '>', "log/dump-$Janus::time" or return;
	my @all = (
		\%Janus::gnicks,
		\%Janus::gchans,
		\%Janus::nets,
		\%Janus::ijnets,
		\%Janus::gnets,
		\%Connection::queues,
		&Persist::dump_all_refs(),
		@_,
	);
	local $Data::Dumper::Sortkeys = 1;
	for (1..10) {
		eval {
			print $dump Data::Dumper::Dumper(\@all);
			1;
		} and last;
	}
	close $dump;
}

&Janus::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	acl => 1,
	code => sub {
		dump_now(@_);
		&Janus::jmsg($_[0], 'State dumped to file log/dump-'.$Janus::time);
	},
}, {
	cmd => 'testdie',
	acl => 1,
	code => sub {
		die "You asked for it!";
	},
});

&Janus::hook_add(
	ALL => 'die' => sub {
		dump_now(@_);
	},
);

1;
