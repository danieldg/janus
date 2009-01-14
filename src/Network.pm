# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Network;
use SocketHandler;
use Persist 'SocketHandler';
use Carp qw(cluck);
use strict;
use warnings;

=head1 Network

Object representing a network

=over

=item $net->jlink()

The InterJanus object if the network is remote, or undef if local

=item $net->gid()

Globally unique ID for this network

=item $net->name()

The network ID for this network (short form)

=item $net->netname()

The human-readable name for this network (long form)

=cut

our(@jlink, @gid, @name, @netname, @synced);
&Persist::register_vars(qw(jlink gid name netname synced));
&Persist::autoget(qw(jlink gid name netname), is_synced => \@synced);
&Persist::autoinit(qw(jlink gid netname), id => \@name);

our $net_gid;

sub jname {
	my $net = $_[0];
	$name[$$net].'.janus';
}

sub _init {
	my $net = $_[0];
	unless ($gid[$$net]) {
		$gid[$$net] = $RemoteJanus::self->id().':'.&EventDump::seq2gid(++$net_gid);
	}
}

sub _set_name {
	$name[${$_[0]}] = $_[1];
}

sub _set_netname {
	$netname[${$_[0]}] = $_[1];
}

sub to_ij {
	my($net,$ij) = @_;
	my $out = '';
	$out .= ' gid='.$ij->ijstr($net->gid());
	$out .= ' id='.$ij->ijstr($net->name());
	$out .= ' jlink='.$ij->ijstr($net->jlink() || $RemoteJanus::self);
	$out .= ' netname='.$ij->ijstr($net->netname());
	$out;
}

sub _destroy {
	my $net = $_[0];
	$netname[$$net];
}

sub str {
	cluck "str called on a network";
	$_[0]->jname();
}

sub id {
	cluck "id called on a network";
	$_[0]->name();
}

sub netnick {
	$_[0]->name;
}

sub delink {
	my($net,$msg) = @_;
	delete $Janus::pending{$net->name};
	&Event::insert_full(+{
		type => 'NETSPLIT',
		net => $net,
		msg => $msg,
	});
}


=back

=cut

&Event::hook_add(
	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		return undef unless $net->isa(__PACKAGE__);
		$synced[$$net] = 1;
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		&Event::append({ type => 'POISON', item => $act->{net} });
	},
);

1;
