# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;

&Janus::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	code => sub {
		my $ts = time;
		open my $dump, '>', "log/dump-$ts" or return;
		my @all = (
			\%Janus::gnicks,
			\%Janus::gchans,
			\%Janus::nets,
			\%Janus::ijnets,
			&Persist::dump_all_refs(),
		);
		print $dump Data::Dumper::Dumper(\@all);
		close $dump;
	},
});

1;
