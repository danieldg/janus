# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Network;
use SocketHandler;
use Persist 'SocketHandler';
use Carp qw(cluck);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @jlink   :Persist(jlink)   :Get(jlink)   :Arg(jlink);
my @gid     :Persist(gid)     :Get(gid)     :Arg(gid);
my @name    :Persist(id)      :Get(name)    :Arg(id);
my @netname :Persist(netname) :Get(netname) :Arg(netname);
my @numeric :Persist(numeric) :Get(numeric) :Arg(numeric);

sub jname {
	my $net = $_[0];
	$name[$$net].'.janus';
}

sub lid {
	${$_[0]};
}

sub _init {
	my $net = $_[0];
	$gid[$$net] ||= $Janus::name.':'.$$net;
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
	$out .= ' netname='.$ij->ijstr($net->netname());
	$out .= ' numeric='.$ij->ijstr($net->numeric());
	$out;
}

sub _destroy {
	my $net = $_[0];
	print "   NET:$$net ".ref($net).' '.$netname[$$net]." deallocated\n";
}

sub str {
	cluck "str called on a network";
	$_[0]->jname();
}

sub id {
	cluck "id called on a network";
	$_[0]->name();
}

&Janus::hook_add(
 	NETSPLIT => act => sub {
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
		print "Nick deallocation start\n";
		@clean = ();
		print "Nick deallocation end\n";
	},
);

1;
