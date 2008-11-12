# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use POSIX qw(strftime);
use Snapshot;

our $pure;

sub dump_now {
	my $fmt = $Conffile::netconf{set}{datefmt};
	my $fn = 'log/';
	if ($fmt) {
		$fn .= strftime $fmt, gmtime $Janus::time;
	} else {
		$fn .= $Janus::time;
	}
	$fn .= '.dump';
	if (-f $fn) {
		my $seq;
		1 while -f $fn.++$seq;
		$fn .= $seq;
	}

	open my $dump, '>', $fn or return undef;
	&Snapshot::dump_to($dump, $pure, \@_);
	close $dump;
	$fn;
}

&Event::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	section => 'Admin',
	acl => 'dump',
	code => sub {
		$pure = ($_[2] eq 'pure' ? 1 : 0);
		my $fn = dump_now(@_);
		&Janus::jmsg($_[1], 'State dumped to file '.$fn);
	},
}, {
	cmd => 'testdie',
	acl => 'dump',
	code => sub {
		die "You asked for it!";
	},
});

&Event::hook_add(
	ALL => 'die' => sub {
		eval {
			dump_now(@_);
			1;
		} or print "Error in dump: $@\n";
	},
);

1;
