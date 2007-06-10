package Network; {
use Object::InsideOut;
use Channel;
use strict;
use warnings;

my @jlink :Field :Arg(jlink) :Get(jlink);
my @id :Field :Arg(id) :Get(id);
my @netname :Field :Arg(netname) :Get(netname) :Set(_set_netname);
my @numeric :Field :Arg(numeric) :Get(numeric) :Set(_set_numeric);

sub to_ij {
	my($net,$ij) = @_;
	' id="'.$net->id().'" netname="'.$net->netname().'"';
}

sub _destroy :Destroy {
	print "DBG: $_[0] $netname[${$_[0]}] deallocated\n";
}

sub str {
	warn;
	$_[0]->id();
}

################################################################################
# Basic Actions
################################################################################

sub modload {
 my $me = shift;
 return unless $me eq 'Network';
 &Janus::hook_add($me,
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
				except => $net,
			};
		}
		&Janus::insert_full(@clean);
		print "Channel deallocation start\n";
		@clean = ();
		print "Channel deallocation end\n";
	});
}

} 1;
