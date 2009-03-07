# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::SvsAccount;
use strict;
use warnings;
use Account;

sub get_aid {
	my $nick = shift;
	my $net = $nick->homenet;
	return undef unless $net->isa('LocalNetwork');

	my $acctid = $nick->info('svsaccount');
	if (defined $nick->info('svsts')) {
		return undef unless $nick->ts == $nick->info('svsts');
		$acctid = lc $nick->homenick unless $acctid;
	}
	return $acctid ? $net->name . ':' . $acctid : undef;
}

our %auth_cache;
Janus::static(qw(auth_cache)); # is a cache, so not part of state

sub find_account {
	my $id = shift;
	unless ($auth_cache{''}) {
		$auth_cache{''}++;
		keys %Account::accounts;
		while (my($aid, $acct) = each %Account::accounts) {
			my $auth = $acct->{svsauth} or next;
			$auth_cache{$_} = $aid for split / /, $auth;
		}
	}
	$auth_cache{$id};
}

Event::command_add({
	cmd => 'svsaccount',
	help => 'Associates a services account with a janus account',
	section => 'Account',
	details => [
		"\002svsaccount add\002       Authorizes your current login for your current account",
		"\002svsaccount list\002      Lists the accounts allowed for your account",
		"\002svsaccount del\002 acct  Removes a services account from your access list",
		'You must have already identified to an account to use this command',
	],
	acl => 'user',
	code => sub {
		my($src,$dst,$cmd,$idx) = @_;
		my $local_id = Account::has_local($src);
		return Janus::jmsg($dst, 'You need a local account for this command') unless $local_id;
		my $auth = Account::get($src, 'svsauth');
		if ($cmd eq 'add') {
			my $acctid = get_aid($src);
			if ($acctid) {
				Account::set($src, 'svsauth', $auth ? "$auth $acctid" : $acctid);
				$auth_cache{$acctid} = $local_id;
				Janus::jmsg($dst, "Account $acctid authorized for your account");
			} else {
				Janus::jmsg($dst, 'You are not logged into services');
			}
		} elsif ($cmd eq 'list') {
			if ($auth) {
				Janus::jmsg($dst, "Services accounts authorized: $auth");
			} else {
				Janus::jmsg($dst, 'No services accounts authorized');
			}
		} elsif ($cmd eq 'del') {
			my %ids;
			$ids{$_}++ for split /\s+/, $auth;
			if (delete $ids{$idx}) {
				Account::set($src, 'svsauth', join ' ', keys %ids);
				delete $auth_cache{$idx};
				Janus::jmsg($dst, 'Deleted');
			} else {
				Janus::jmsg($dst, 'Not found');
			}
		} else {
			Janus::jmsg($dst, 'See "help svsaccount" for usage');
		}
	},
});

Event::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $svsacct = get_aid($nick) or return;
		my $jacct = find_account($svsacct) or return;
		Event::append({
			type => 'NICKINFO',
			dst => $nick,
			item => 'account:'.$RemoteJanus::self->id,
			value => $jacct,
		});
	}, NICKINFO => 'act:1' => sub {
		my $act = shift;
		return unless $act->{item} eq 'svsaccount' || $act->{item} eq 'svsts';
		my $nick = $act->{dst};
		my $svsacct = get_aid($nick) or return;
		my $jacct = find_account($svsacct) or return;
		Event::append({
			type => 'NICKINFO',
			dst => $nick,
			item => 'account:'.$RemoteJanus::self->id,
			value => $jacct,
		});
	}, ACCOUNT => del => sub {
		%auth_cache = ();
	},
);

1;
