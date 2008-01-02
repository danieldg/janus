# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Upgrade;
use strict;
use warnings;
our($VERSION) = '$Rev$' =~ /(\d+)/;

&Janus::command_add({
	cmd => 'upgrade',
	help => 'Upgrades all modules loaded by janus',
	code => sub {
		my($nick,$arg) = @_;
		my @mods = grep { $Janus::modules{$_} == 2 } keys %Janus::modules;
		for my $mod (@mods) {
			print "Reload $mod:\n";
			&Janus::reload($mod);
		}
		&Janus::jmsg($nick, 'All modules reloaded');
	}
});

1;
