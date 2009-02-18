# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use Snapshot;

Event::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	section => 'Admin',
	acl => 'dump',
	code => sub {
		$Snapshot::pure = ($_[2] eq 'pure' ? 1 : 0);
		my $fn = Snapshot::dump_now(@_);
		Janus::jmsg($_[1], 'State dumped to file '.$fn);
	},
}, {
	cmd => 'testdie',
	acl => 'dump',
	code => sub {
		die "You asked for it!";
	},
});

Event::hook_add(
	ALL => 'die' => sub {
		eval {
			Snapshot::dump_now(@_, Log::call_dump());
			1;
		} or print "Error in dump: $@\n";
	},
);

1;
