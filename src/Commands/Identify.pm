# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Identify;
use strict;
use warnings;
use Account;

&Janus::command_add({
	cmd => 'identify',
	help => 'identify yourself to janus',
	details => [
		"Syntax: identify [username] password",
		'Your nick is the default username',
	],
	secret => 1,
	code => sub {
		my $nick = $_[0];
		my $user = lc (@_ == 3 ? $nick->homenick : $_[2]);
		my $pass = $_[-1];
		if ($Account::accounts{$user}) {
			# TODO hash the password
			if ($Account::accounts{$user}{pass} eq $pass) {
				$Account::account[$$nick] = $user;
				&Log::info($nick->netnick. ' identified as '.$user);
				&Janus::jmsg($nick, "You are now identified as $user");
				return;
			}
		}
		&Log::info($nick->netnick.' failed identify as '.$user);
		&Janus::jmsg($nick, 'Invalid username or password');
	},
});

1;
