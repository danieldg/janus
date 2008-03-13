# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package RemoteJanus;
use SocketHandler;
use Persist 'SocketHandler';
use strict;
use warnings;
use integer;

# Object representing THIS server
our $self;

my @id     :Persist(id)     :Arg(id)     :Get(id);
my @parent :Persist(parent) :Arg(parent) :Get(parent);

sub _id {
	$id[${$_[0]}] = $_[1];
}

# for sending out some other IJ
sub to_ij {
	my($net, $ij) = @_;
	my $out;
	$out .= ' id='.$ij->ijstr($id[$$net]);
	$out .= ' parent='.$ij->ijstr($parent[$$net] || $RemoteJanus::self);
	$out;
}

sub _init {
	&Debug::alloc($_[0], 1);
}

sub _destroy {
	my $net = $_[0];
	&Debug::alloc($net, 0, $id[$$net]);
}

sub jlink {
	$_[0]->parent();
}

sub is_linked {
	1;
}

&Janus::hook_add(
	'INIT' => act => sub {
		$self = RemoteJanus->new(id => $Conffile::netconf{set}{name});
	},
);

1;
