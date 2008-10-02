# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Account;
use strict;
use warnings;
use Persist;

our @account;

# TODO a proper database will eventually be needed
our %accounts;

&Persist::register_vars('Nick::account' => \@account);
&Janus::save_vars(accounts => \%accounts);

sub acl_check {
	my($nick, $acl) = @_;
	if ($acl eq 'oper') {
		return $nick->has_mode('oper');
	}
	return 0 unless $account[$$nick];
	my $acct = $accounts{$account[$$nick]};
	return 0 unless $acct->{acl};
	return 1 if $acct->{acl} eq '*';
	for (split / /, $acct->{acl}) {
		return 1 if $acl eq $_;
	}
	0
}

1;
