# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Network;
use SocketHandler;
use Persist 'SocketHandler';
use Carp qw(cluck);
use strict;
use warnings;
use RemoteJanus;

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

=item $net->numeric()

The unique numeric value for this network. May be deprecated at some time in the future.

=cut

our(@jlink, @gid, @name, @netname, @numeric, @synced);
&Persist::register_vars(qw(jlink gid name netname numeric synced));
&Persist::autoget(qw(jlink gid name netname numeric), is_synced => \@synced);
&Persist::autoinit(qw(jlink gid netname numeric), id => \@name);

sub jname {
	my $net = $_[0];
	$name[$$net].'.janus';
}

sub lid {
	${$_[0]};
}

sub _init {
	my $net = $_[0];
	$gid[$$net] ||= $RemoteJanus::self->id().':'.$$net;
}

sub _set_name {
	$name[${$_[0]}] = $_[1];
}

sub _set_numeric {
	$numeric[${$_[0]}] = $_[1];
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
	$out .= ' numeric='.$ij->ijstr($net->numeric());
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

=back

=cut

&Janus::hook_add(
	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		return undef unless $net->isa(__PACKAGE__);
		$synced[$$net] = 1;
		undef;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $msg = 'hub.janus '.$net->jname();
		my @clean;
		for my $nick (values %Janus::nicks) {
			next if $nick->homenet() ne $net;
			push @clean, +{
				type => 'QUIT',
				dst => $nick,
				msg => $msg,
				except => $net,
				netsplit_quit => 1,
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean);
		&Debug::info("Nick deallocation start");
		@clean = ();
		&Debug::info("Nick deallocation end");
	},
);

1;
