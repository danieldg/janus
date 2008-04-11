# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Save;
use strict;
use warnings;

&Janus::command_add({
	cmd => 'save',
	help => 'Save janus state to filesystem',
	acl => 1,
	code => sub {
		my($nick,$args) = @_;
		if (&Conffile::save()) {
			&Janus::jmsg($nick, 'Saved');
		} else {
			&Janus::jmsg($nick, "Could not save: $!");
		}
	}
});

1;
