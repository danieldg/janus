# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Network;
use Persist;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @jlink   :Persist(jlink)   :Get(jlink)   :Arg(jlink);
my @id      :Persist(id)      :Get(id)      :Arg(id);
my @netname :Persist(netname) :Get(netname) :Arg(netname);
my @numeric :Persist(numeric) :Get(numeric) :Arg(numeric);

sub _set_id {
	$id[${$_[0]}] = $_[1];
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
	$out .= ' id='.$ij->ijstr($net->id());
	$out .= ' netname='.$ij->ijstr($net->netname());
	$out .= ' numeric='.$ij->ijstr($net->numeric());
	$out;
}

sub _destroy {
	my $net = $_[0];
	print "   NET:$$net ".ref($net).' '.$netname[$$net]." deallocated\n";
}

sub str {
	warn;
	$_[0]->id();
}

&Janus::hook_add(
 	NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;
		for my $nick ($net->all_nicks()) {
			next if $nick->homenet()->id() ne $tid;
			push @clean, +{
				type => 'QUIT',
				dst => $nick,
				msg => "hub.janus $tid.janus",
				except => $net,
				netsplit_quit => 1,
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean);
		print "Nick deallocation start\n";
		@clean = ();
		print "Nick deallocation end\n";
		for my $chan ($net->all_chans()) {
			push @clean, +{
				type => 'DELINK',
				dst => $chan,
				net => $net,
				netsplit_quit => 1,
				except => $net,
				reason => 'netsplit',
			};
		}
		&Janus::insert_full(@clean);
		print "Channel deallocation start\n";
		@clean = ();
		print "Channel deallocation end\n";
	},
);

1;
