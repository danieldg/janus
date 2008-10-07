# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Account;
use strict;
use warnings;

&Event::hook_add(
	INFO => Account => sub {
		my($dst, $acctid, $src) = @_;
		my $all = &Account::acl_check($src, 'admin') || $acctid eq &Account::has_local($src);
		if ($all) {
			&Janus::jmsg($dst, 'ACL: '.$Account::accounts{$acctid}{acl});
		}
	},
);
&Janus::command_add({
	cmd => 'account',
	help => 'Manages janus accounts',
	acl => 'admin',
	section => 'Account',
	details => [
		"\002ACCOUNT LIST\002               Lists all accounts",
		"\002ACCOUNT SHOW\002 account       Shows details on an account",
		"\002ACCOUNT CREATE\002 account     Creates a new (local or remote) account",
		"\002ACCOUNT DELETE\002 account     Deletes an account",
		"\002ACCOUNT GRANT\002 account acl  Grants an account access to the given command ACL",
		"\002ACCOUNT REVOKE\002 account acl Revokes an account's access to the given command ACL",
	],
	code => sub {
		my($src,$dst,$cmd,$acctid,@acls) = @_;
		$cmd = lc $cmd;
		$acctid = lc $acctid;
		my $acct = $Account::accounts{$acctid};
		if ($cmd eq 'list') {
			&Janus::jmsg($dst, join ' ', sort keys %Account::accounts);
		} elsif ($cmd eq 'show') {
			return &Janus::jmsg($dst, 'No such account') unless $acct;
			&Event::named_hook('INFO/Account', $dst, $acctid, $src);
		} elsif ($cmd eq 'create') {
			&Event::named_hook('ACCOUNT/add', $acctid);
			&Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'delete') {
			return &Janus::jmsg($dst, 'No such account') unless $acct;
			&Event::named_hook('ACCOUNT/del', $acctid);
			&Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'grant' && @acls) {
			return &Janus::jmsg($dst, 'No such account') unless $acct;
			my %acl;
			$acl{$_}++ for split / /, ($acct->{acl} || '');
			for (@acls) {
				$acl{$_}++;
				unless (&Account::acl_check($src, $_)) {
					return &Janus::jmsg($dst, "You cannot grant access to permissions you don't have");
				}
			}
			$acct->{acl} = join ' ', sort keys %acl;
			&Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'revoke' && @acls) {
			return &Janus::jmsg($dst, 'No such account') unless $acct;
			my %acl;
			$acl{$_}++ for split / /, ($acct->{acl} || '');
			for (@acls) {
				delete $acl{$_};
				unless (&Account::acl_check($src, $_)) {
					return &Janus::jmsg($dst, "You cannot revoke access to permissions you don't have");
				}
			}
			$acct->{acl} = join ' ', sort keys %acl;
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'See "help account" for the correct syntax');
		}
	}
});

1;
