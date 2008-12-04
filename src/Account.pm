# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Account;
use strict;
use warnings;
use Persist;

our %accounts;
our %roles;
&Janus::save_vars(accounts => \%accounts, roles => \%roles);

unless (%roles) {
	%roles = (
		'user' => 'user',
		'oper' => 'oper ban rehash link',
		'netop' => 'clink forceid autoconnect netsplit xline',
		'admin' => 'account setpass info/nick dump verify role forcetag globalban',
		'owner' => 'reload unload up-git up-tar upgrade die reboot restart',
		'superadmin' => 'salink eval',
	);
}

sub acl_check {
	my($nick, $acl) = @_;
	local $_;
	my @accts;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id);
	my %hasr;
	$hasr{oper}++ if $nick->has_mode('oper');

	if ($selfid && $accounts{$selfid}) {
		push @accts, $accounts{$selfid};
	}

	for my $ij (values %Janus::ijnets) {
		my $id = $ij->id;
		my $login = $nick->info('account:'.$id) or next;
		push @accts, $accounts{$id.':'.$login} if $accounts{$id.':'.$login};
	}

	for my $acct (@accts) {
		$hasr{user}++;
		next unless $acct->{acl};
		$hasr{$_}++ for split /\s+/, $acct->{acl};
	}
	return 1 if $hasr{'*'};
	my %hasa;
	for my $role (keys %hasr) {
		$hasa{$_}++ for split /\s+/, ($roles{$role} || '');
	}
	for my $itm (split /\|/, $acl) {
		return 1 if $hasa{$itm};
	}
	return 0;
}

# acl is one of:
#	create, link = must be owner/oper on home network
#	delink = must be owner/oper
#	mode = must be owner
#	info = must be op
sub chan_access_chk {
	my($nick, $chan, $acl, $errs) = @_;
	my $net = $nick->homenet;
	if (acl_check($nick, 'salink')) {
		return 1;
	}
	if (($acl eq 'create' || $acl eq 'link') && $chan->homenet != $net) {
		&Janus::jmsg($errs, "This command must be run from the channel's home network");
		return 0;
	}
	if (acl_check($nick, 'link')) {
		return 1;
	}
	my $chanacl = Setting::get(link_requires => $net);
	$chanacl = 'op' if $acl eq 'info';
	if ('n' eq ($Modes::mtype{$chanacl} || '')) {
		return 1 if $chan->has_nmode($chanacl, $nick);
		&Janus::jmsg($errs, "You must be a channel $chanacl to use this command");
	} else {
		&Janus::jmsg($errs, "You must have access to 'link' to use this command");
	}
	return 0;
}

sub has_local {
	my $nick = shift;
	my $selfid = $nick->info('account:'.$RemoteJanus::self->id);
	return '' unless $selfid && defined $accounts{$selfid};
	$selfid;
}

sub get {
	my($nick, $item) = @_;
	my $id = ref $nick ? $nick->info('account:'.$RemoteJanus::self->id) : $nick;
	return undef unless $id && $accounts{$id};
	return $accounts{$id}{$item};
}

sub set {
	my($nick, $item, $value) = @_;
	my $id = ref $nick ? $nick->info('account:'.$RemoteJanus::self->id) : $nick;
	return 0 unless $id && $accounts{$id};
	$accounts{$id}{$item} = $value;
	1;
}

&Event::hook_add(
	ACCOUNT => add => sub {
		my $acctid = shift;
		$Account::accounts{$acctid} = {};
	},
	ACCOUNT => del => sub {
		my $acctid = shift;
		delete $Account::accounts{$acctid};
	},
#	NICKINFO => check => sub {
#		my $act = shift;
#	},
);

1;
