# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Identify;
use strict;
use warnings;
use Account;
use Util::Crypto;

our @fails;
&Persist::register_vars('Nick::fails' => \@fails);

&Event::command_add({
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
		my $id = $RemoteJanus::self->id;
		if ($user eq 'admin') {
			# special-case: admin password is in configuration
			my $confpass = $Conffile::netconf{set}{password};
			if ($confpass && $pass eq $confpass) {
				&Log::audit($_[0]->netnick . ' logged in as admin');
				$Account::accounts{admin}{acl} = '*';
				&Event::append({
					type => 'NICKINFO',
					src => $RemoteJanus::self,
					dst => $nick,
					item => "account:$id",
					value => $user,
				});
				&Janus::jmsg($nick, 'You are logged in as admin. '.
					'Please create named accounts for normal use using the "account" command.');
				return;
			}
		} elsif ($Account::accounts{$user}) {
			my $salt = $Account::accounts{$user}{salt} || '';
			my $hash = hash($pass, $salt);
			if ($Account::accounts{$user}{pass} eq $hash) {
				&Log::info($nick->netnick. ' identified as '.$user);
				&Event::append({
					type => 'NICKINFO',
					src => $RemoteJanus::self,
					dst => $nick,
					item => "account:$id",
					value => $user,
				});
				&Janus::jmsg($nick, "You are now identified as $user");
				return;
			}
		}
		&Log::info($nick->netnick.' failed identify as '.$user);
		my $count = ++$fails[$$nick];
		if ($count < 5) {
			&Janus::jmsg($nick, 'Invalid username or password.');
		} elsif ($count == 5) {
			&Janus::jmsg($nick, 'Invalid username or password. Your next misidentify will result in a kill.');
		} else {
			&Log::info('Too many login failures, killing '.$nick->netnick);
			&Event::append({
				type => 'KILL',
				net => $nick->homenet,
				dst => $nick,
				src => $Interface::janus,
				msg => 'Too many incorrect passwords',
			});
		}
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
	aclchk => 'setpass',
	code => sub {
		my($src,$dst) = @_;
		my $acctid = $src->info('account:'.$RemoteJanus::self->id);
		my $user = @_ == 3 ? $acctid : lc $_[2];
		my $acct = $user ? $Account::accounts{$user} : undef;
		if ($acct && $user eq $acctid) {
			&Log::info($src->netnick .' changed their password (account "'.$user.'")');
		} elsif (&Account::acl_check($src, 'setpass')) {
			return &Janus::jmsg($dst, 'Cannot find that user') unless $acct;
			for my $acl (split /\s+/, $acct->{acl}) {
				unless (&Account::acl_check($src, $acl)) {
					return &Janus::jmsg($dst, "You must have access to '$acl' to modify this user");
				}
			}
			&Log::audit($src->netnick .' changed '.$user."\'s password");
		} else {
			return &Janus::jmsg($dst, 'You can only change your own password');
		}
		my $salt = Util::Crypto::salt(8, $src, $src->gid, $user);
		my $hash = Util::Crypto::hmacsha1($_[-1], $salt);
		$acct->{salt} = $salt;
		$acct->{pass} = $hash;
		&Janus::jmsg($dst, 'Done');
	},
});

1;
