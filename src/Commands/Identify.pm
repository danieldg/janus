# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Identify;
use strict;
use warnings;
use Account;

&Janus::command_add({
	cmd => 'identify',
	help => 'Identify yourself to janus',
	section => 'Account',
	details => [
		"Syntax: identify [username] password",
		'Your nick is the default username',
	],
	secret => 1,
	code => sub {
		my $nick = $_[0];
		my $user = lc (@_ == 3 ? $nick->homenick : $_[2]);
		my $pass = $_[-1];
		$user =~ s/[^0-9a-z_]//g;
		if ($Account::accounts{$user}) {
			# TODO hash the password
			if ($Account::accounts{$user}{pass} eq $pass) {
				my $id = $RemoteJanus::self->id;
				&Log::info($nick->netnick. ' identified as '.$user);
				&Janus::append({
					type => 'NICKINFO',
					src => $RemoteJanus::self,
					dst => $nick,
					item => "account:$id",
					value => $user,
				})
				&Janus::jmsg($nick, "You are now identified as $user");
				return;
			}
		}
		&Log::info($nick->netnick.' failed identify as '.$user);
		&Janus::jmsg($nick, 'Invalid username or password');
	},
}, {
	cmd => 'setpass',
	help => 'Set your janus identify password',
	section => 'Account',
	details => [
		"Syntax: \002setpass\002 [user] password",
	],
	secret => 1,
	acl => 'user',
	code => sub {
		my($src,$dst) = @_;
		my $acctid = $src->info('account:'.$RemoteJanus::self->id);
		my $user = @_ == 3 ? $acctid : $_[2];
		my $acct = $user ? $Account::accounts{$user} : undef;
		if ($acct && $user eq $acctid) {
			&Log::info($src->netnick .' changed their password (account "'.$user.'")');
		} elsif (&Account::acl_check($src, 'admin')) {
			return &Janus::jmsg($dst, 'Cannot find that user') unless $acct;
			&Log::audit($src->netnick .' changed '.$user."\'s password");
		} else {
			return &Janus::jmsg($dst, 'You can only change your own password');
		}
		$acct->{pass} = $_[-1];
		&Janus::jmsg($dst, 'Done');
	},
});

1;
