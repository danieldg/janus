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

our(@id, @parent);
&Persist::register_vars(qw(id parent));
&Persist::autoget(qw(id parent));
&Persist::autoinit(qw(id parent));

# for sending out some other IJ
sub to_ij {
	my($net, $ij) = @_;
	my $out;
	$out .= ' id='.$ij->ijstr($id[$$net]);
	$out .= ' parent='.$ij->ijstr($parent[$$net] || $RemoteJanus::self);
	$out;
}

sub _destroy {
	$id[${$_[0]}];
}

sub jlink {
	$_[0]->parent();
}

sub is_linked {
	1;
}

sub send {
	my $ij = shift;
	$ij = $parent[$$ij];
	$ij->send(@_);
}

sub jparent {
	my($self, $net) = @_;
	$net = $net->jlink() if $net && $net->isa('Network');
	$net = $net->parent() while $net && $$net != $$self;
	$net ? 1 : 0;
}

&Janus::hook_add(
	'INIT' => act => sub {
		$self = RemoteJanus->new(id => $Conffile::netconf{set}{name});
	},
);

1;
