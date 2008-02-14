# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Upgrade;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'upgrade',
	help => 'Upgrades all modules loaded by janus',
	acl => 1,
	code => sub {
		my($nick,$arg) = @_;
		my @mods = sort grep { $Janus::modules{$_} == 2 } keys %Janus::modules;
		for my $mod (@mods) {
			print "Reload $mod:\n";
			&Janus::reload($mod);
		}
		&Janus::jmsg($nick, 'All modules reloaded');
	}
}, {
	cmd => 'svnup',
	help => 'Runs "svn up"',
	acl => 1,
	code => sub {
		my $nick = shift;
		my $p = fork;
		return &Janus::jmsg($nick, 'Failed') unless defined $p && $p >= 0;
		return if $p;
		do { exec 'svn', 'up'; };
		# failed, try avoiding the SSL destructors
		exec '/bin/false';
		# why are we still alive?
		exit 1;
	}
});

$SIG{CHLD} = 'IGNORE';

1;
