# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Account;
use strict;
use warnings;
use Persist;

our %accounts;

&Janus::save_vars(accounts => \%accounts);

sub acl_check {
	my($nick, $acl) = @_;
	my @accts;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id);
	my %has = (
		oper => $nick->has_mode('oper'),
	);

	if ($accounts{$selfid}) {
		push @accts, $accounts{$selfid};
	}

	for my $ij (values %Janus::ijnets) {
		my $id = $ij->id;
		my $login = $nick->info('account:'.$id) or next;
		push @accts, $accounts{$id.':'.$login} if $accounts{$id.':'.$login};
	}

	for my $acct (@accts) {
		$has{user}++;
		next unless $acct->{acl};
		$has{$_}++ for split /\s+/, $acct->{acl};
	}
	return 1 if $has{'*'};
	$has{$acl};
}

sub has_local {
	my $nick = shift;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id);
	defined $selfid && defined $accounts{$selfid};
}

sub get {
	my($nick, $item) = @_;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id) or return undef;
	return undef unless $accounts{$selfid};
	return $accounts{$selfid}{$item};
}

sub set {
	my($nick, $item, $value) = @_;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id) or return 0;
	return 0 unless $accounts{$selfid};
	$accounts{$selfid}{$item} = $value;
	1;
}

#&Event::hook_add(
#	NICKINFO => check => sub {
#		my $act = shift;
#	},
#);

1;
