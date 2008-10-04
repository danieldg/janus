# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::SvsAccount;
use strict;
use warnings;
use Account;

sub get_aid {
	my $nick = shift;
	my $net = $nick->homenet;
	return undef unless $net->isa('LocalNetwork');

# XXX this is very network- and services-dependent code
	return undef unless $nick->has_mode('registered');
	if (defined $nick->info('svsts')) {
		return undef unless $nick->ts == $nick->info('svsts');
	}
	my $acctid = $nick->info('svsaccount');
	$acctid = lc $nick->homenick unless defined $acctid;
	return $net->id . ':' . $acctid;
}

# TODO this is slow
sub find_account {
	my $id = shift;
	keys %Account::accounts;
	while (my($aid, $acct) = each %Account::accounts) {
		my $auth = $acct->{svsauth} or next;
		return $aid if grep { $_ eq $id } split / /, $auth;
	}
	undef;
}

&Event::command_add({
	cmd => 'svsaccount',
	help => 'Associates a services account with a janus account',
	details => [
		"\002svsaccount add\002       Authorizes your current login for your current account",
		"\002svsaccount list\002      Lists the accounts allowed for your account",
		"\002svsaccount del\002 acct  Removes a services account from your access list",
		'You must have already identified to an account to use this command',
	],
	acl => 'user',
	code => sub {
		my($src,$dst,$cmd,$idx) = @_;
		my $acct = $Account::accounts{$src->info('account:'.$RemoteJanus::self->id)};
		return &Janus::jmsg($dst, 'You need a local account for this command') unless $acct;
		my $auth = $acct->{svsauth};
		if ($cmd eq 'add') {
			my $acctid = get_aid($src);
			if ($acctid) {
				$acct->{svsauth} = $auth ? "$auth $acctid" : $acctid;
				&Janus::jmsg($dst, "Account $acctid authorized for your account");
			} else {
				&Janus::jmsg($dst, 'You are not logged into services');
			}
		} elsif ($cmd eq 'list') {
			if ($auth) {
				&Janus::jmsg($dst, "Services accounts authorized: $auth");
			} else {
				&Janus::jmsg($dst, 'No services accounts authorized');
			}
		} elsif ($cmd eq 'del') {
			my %ids;
			$ids{$_}++ for split /\s+/, $auth;
			if (delete $ids{$idx}) {
				$acct->{svsauth} = join ' ', keys %ids;
				&Janus::jmsg($dst, 'Deleted');
			} else {
				&Janus::jmsg($dst, 'Not found');
			}
		} else {
			&Janus::jmsg($dst, 'See "help svsaccount" for usage');
		}
	},
});

&Event::hook_add(
	NEWNICK => act => sub {
		my $act = shift;
		my $nick = $act->{dst};
		my $svsacct = get_aid($nick) or return;
		my $jacct = find_account($svsacct) or return;
		&Event::append({
			type => 'NICKINFO',
			dst => $nick,
			item => 'account:'.$RemoteJanus::self->id,
			value => $jacct,
		});
	}, UMODE => act => sub {
		my $act = shift;
		return unless grep { $_ eq '+registered' } @{$act->{mode}};
		my $nick = $act->{dst};
		my $svsacct = get_aid($nick) or return;
		my $jacct = find_account($svsacct) or return;
		&Event::append({
			type => 'NICKINFO',
			dst => $nick,
			item => 'account:'.$RemoteJanus::self->id,
			value => $jacct,
		});
	}
);

1;
