# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Identify;
use strict;
use warnings;
use Account;

our @fails;
&Persist::register_vars('Nick::fails' => \@fails);

sub gen_salt {
	my($nick,$acct) = @_;
	my $h = $Janus::new_sha1->();
	# perl's rand is initialized with 32 bits of entropy from urandom;
	# the other items are to reduce correlation between people setting
	# their passwords during the same run of the server
	$h->add(rand() . $Janus::time . $nick->gid . '!' . $acct);
	substr $h->b64digest, 0, 8;
}

# avoid a dependency on Digest::HMAC_SHA1
sub hash {
	my($pass, $salt) = @_;
	my $h = $Janus::new_sha1->();
	$salt =~ s/(.)/chr(0x36 ^ ord $1)/eg;
	$h->add($salt)->add($pass);
	my $v1 = $h->digest;
	$salt =~ s/(.)/chr(0x6A ^ ord $1)/eg; # HMAC spec says 5c = 6a^36
	$h->add($salt)->add($v1);
	$h->b64digest;
}

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
		my $salt = gen_salt($src, $user);
		my $hash = hash($_[-1], $salt);
		$acct->{salt} = $salt;
		$acct->{pass} = $hash;
		&Janus::jmsg($dst, 'Done');
	},
});

1;
