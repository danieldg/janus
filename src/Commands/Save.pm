# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Save;
use strict;
use warnings;

Event::command_add({
	cmd => 'save',
	help => 'Save janus state to filesystem',
	section => 'Admin',
	acl => 'oper',
	api => '=replyto',
	code => sub {
		if (Conffile::save()) {
			Janus::jmsg($_[0], 'Saved');
		} else {
			Janus::jmsg($_[0], "Could not save: $!");
		}
	}
});

1;
