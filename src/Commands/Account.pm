# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Account;
use strict;
use warnings;

&Event::hook_add(
	INFO => Account => sub {
		my($dst, $acctid, $src) = @_;
		my $all = &Account::acl_check($src, 'account') || $acctid eq &Account::has_local($src);
		if ($all) {
			&Janus::jmsg($dst, 'Roles: '.$Account::accounts{$acctid}{acl});
		}
	},
);

sub role_acl_super {
	my($src, $role) = @_;
	local $_;
	return 0 if $role eq '*' && !&Account::acl_check($src, '*');
	my %acl;
	$acl{$_}++ for split / /, ($Account::roles{$role} || '');
	for (keys %acl) {
		return 0 unless &Account::acl_check($src, $_);
	}
	1;
}

&Event::command_add({
	cmd => 'account',
	help => 'Manages janus accounts',
	acl => 'account',
	section => 'Account',
	details => [
		"\002ACCOUNT LIST\002                Lists all accounts",
		"\002ACCOUNT SHOW\002 account        Shows details on an account",
		"\002ACCOUNT CREATE\002 account      Creates a new (local or remote) account",
		"\002ACCOUNT DELETE\002 account      Deletes an account",
		"\002ACCOUNT GRANT\002 account role  Grants an account access to the given role",
		"\002ACCOUNT REVOKE\002 account role Revokes an account's access to the given role",
	],
	code => sub {
		my($src,$dst,$cmd,$acctid,@acls) = @_;
		$cmd = lc $cmd;
		$acctid = lc $acctid;
		if ($cmd eq 'create') {
			return &Janus::jmsg($dst, 'Account already exists') if $Account::accounts{$acctid};
			&Event::named_hook('ACCOUNT/add', $acctid);
			return &Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'list') {
			&Janus::jmsg($dst, join ' ', sort keys %Account::accounts);
			return;
		}

		return &Janus::jmsg($dst, 'No such account') unless $Account::accounts{$acctid};
		if ($cmd eq 'show') {
			&Event::named_hook('INFO/Account', $dst, $acctid, $src);
		} elsif ($cmd eq 'delete') {
			my %acl;
			$acl{$_}++ for split / /, (&Account::get($acctid, 'acl') || '');
			for (keys %acl) {
				unless (role_acl_super($src, $_)) {
					return &Janus::jmsg($dst, "You cannot delete accounts with access to permissions you don't have");
				}
			}
			&Event::named_hook('ACCOUNT/del', $acctid);
			&Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'grant' && @acls) {
			my %acl;
			$acl{$_}++ for split / /, (&Account::get($acctid, 'acl') || '');
			for (@acls) {
				$acl{$_}++;
				unless (role_acl_super($src, $_)) {
					return &Janus::jmsg($dst, "You cannot grant access to permissions you don't have");
				}
			}
			&Account::set($acctid, 'acl', join ' ', sort keys %acl);
			&Janus::jmsg($dst, 'Done');
		} elsif ($cmd eq 'revoke' && @acls) {
			my %acl;
			$acl{$_}++ for split / /, (&Account::get($acctid, 'acl') || '');
			for (@acls) {
				delete $acl{$_};
				unless (role_acl_super($src, $_)) {
					return &Janus::jmsg($dst, "You cannot revoke access to permissions you don't have");
				}
			}
			&Account::set($acctid, 'acl', join ' ', sort keys %acl);
			&Janus::jmsg($dst, 'Done');
		} else {
			&Janus::jmsg($dst, 'See "help account" for the correct syntax');
		}
	}
}, {
	cmd => 'role',
	help => 'Manages janus account roles',
	section => 'Account',
	acl => 'role',
	details => [
		"\002ROLE ADD\002 role acl...  Adds ACLs to a role",
		"\002ROLE DEL\002 role acl...  Removes ACLs from a role",
		"\002ROLE DESTROY\002 role     Removes a role",
	],
	api => '=src =replyto $ $ @',
	code => sub {
		my($src,$dst,$cmd,$role,@acls) = @_;
		$cmd = lc $cmd;
		my %acl;
		$acl{$_}++ for split / /, ($Account::roles{$role} || '');
		if ($cmd eq 'add') {
			for (@acls) {
				$acl{$_}++;
				unless (&Account::acl_check($src, $_)) {
					return &Janus::jmsg($dst, "You cannot grant access to permissions you don't have");
				}
			}
			$Account::roles{$role} = join ' ', sort keys %acl;
		} elsif ($cmd eq 'del') {
			for (@acls) {
				delete $acl{$_};
				unless (&Account::acl_check($src, $_)) {
					return &Janus::jmsg($dst, "You cannot revoke access to permissions you don't have");
				}
			}
			$Account::roles{$role} = join ' ', sort keys %acl;
			delete $Account::roles{$role} unless %acl;
		} elsif ($cmd eq 'destroy') {
			for (keys %acl) {
				unless (&Account::acl_check($src, $_)) {
					return &Janus::jmsg($dst, "You cannot revoke access to permissions you don't have");
				}
			}
			delete $Account::roles{$role};
		} else {
			return &Janus::jmsg($dst, 'See "help role" for correct syntax');
		}
		&Janus::jmsg($dst, 'Done');
	},
}, {
	cmd => 'listroles',
	help => 'Lists all janus access roles',
	section => 'Info',
	code => sub {
		my($src,$dst) = @_;
		my @tbl;
		my %all = %Account::roles;
		$all{oper} = $all{user} = 7;
		for my $role (sort keys %all) {
			my $s = $all{$role} eq '7' ? '*' : ' ';
			push @tbl, [ "$s\002$role\002", $Account::roles{$role} ];
		}
		&Interface::msgtable($dst, \@tbl, minw => [ 10, 0 ]);
		&Interface::jmsg($dst, '* = builtin role');
	},
});

1;
