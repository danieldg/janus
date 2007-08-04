# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Network;
use Persist;
use Object::InsideOut;
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

__PERSIST__
persist @jlink   :Field :Arg(jlink) :Get(jlink);
persist @id      :Field :Arg(id) :Get(id);
persist @netname :Field :Arg(netname) :Get(netname) :Set(_set_netname);
persist @numeric :Field :Arg(numeric) :Get(numeric) :Set(_set_numeric);
__CODE__

sub to_ij {
	my($net,$ij) = @_;
	my $out = '';
	$out .= ' id='.$ij->ijstr($net->id());
	$out .= ' netname='.$ij->ijstr($net->netname());
	$out .= ' numeric='.$ij->ijstr($net->numeric());
	$out;
}

sub _destroy :Destroy {
	print "DBG: $_[0] $netname[${$_[0]}] deallocated\n";
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
			};
		}
		&Janus::insert_full(@clean);
		print "Channel deallocation start\n";
		@clean = ();
		print "Channel deallocation end\n";
	},
);

1;
