# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;

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
			Data::Dumper::Dumper($_);
		} for values %Janus::netqueues;
		open my $dump, '>', "log/dump-$ts" or return;
		my @all = (
			\%Janus::gnicks,
			\%Janus::gchans,
			\%Janus::nets,
			\%Janus::ijnets,
			\%Janus::gnets,
			\%Janus::netqueues,
			&Persist::dump_all_refs(),
		);
		print $dump Data::Dumper::Dumper(\@all);
		close $dump;
		&Janus::jmsg($nick, 'State dumped to file log/dump-'.$ts);
	},
});

1;
