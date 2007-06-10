# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Network; {
use Object::InsideOut;
use Channel;
use strict;
use warnings;

my @jlink :Field :Get(jlink);
my @id :Field :Arg(id) :Get(id);
my @nicks :Field;
my @chans :Field;
my @netname :Field :Get(netname) :Set(_set_netname);

sub _init :Init {
	my $net = shift;
	$nicks[$$net] = {};
	$chans[$$net] = {};
}

sub to_ij {
	my($net,$ij) = @_;
	' id='.$net->id().' netname='.$net->netname();
}

sub _destroy :Destroy {
	print "DBG: $_[0] $netname[${$_[0]}] deallocated\n";
}

sub _nicks {
	my $net = $_[0];
	$nicks[$$net];
}

sub _chans {
	my $net = $_[0];
	$chans[$$net];
}

sub mynick {
	my($net, $name) = @_;
	my $nick = $nicks[$$net]{lc $name};
	unless ($nick) {
		print "Nick '$name' does not exist; ignoring\n";
		return undef;
	}
	if ($nick->homenet()->id() ne $net->id()) {
		print "Nick '$name' is from network '".$nick->homenet()->id().
			"' but was sourced from network '".$net->id()."'\n";
		return undef;
	}
	return $nick;
}

sub nick {
	my($net, $name) = @_;
	return $nicks[$$net]{lc $name} if $nicks[$$net]{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $chans[$$net]{lc $name}) {
		return undef unless $new;
		print "Creating channel $name\n" if $new;
		$chans[$$net]{lc $name} = Channel->new(
			net => $net, 
			name => $name,
		);
	}
	$chans[$$net]{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	warn "replacing nonexistant channel" unless exists $chans[$$net]{lc $name};
	if (defined $new) {
		$chans[$$net]{lc $name} = $new;
	} else {
		delete $chans[$$net]{lc $name};
	}
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $nicks[$$net]{lc $item} if exists $nicks[$$net]{lc $item};
	return $chans[$$net]{lc $item} if exists $chans[$$net]{lc $item};
	return $net if $item =~ /\./;
	return undef;
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
		for my $nick (values %{$nicks[$$net]}) {
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
		for my $chan (values %{$chans[$$net]}) {
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
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;

		warn "nicks remain after a netsplit\n" if %{$nicks[$$net]};
		for my $nick (values %{$nicks[$$net]}) {
			push @clean, +{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => 'JanusSplit',
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean) if @clean;
		warn "nicks still remain after netsplit kills\n" if %{$nicks[$$net]};
		delete $nicks[$$net];
		warn "channels remain after a netsplit\n" if %{$chans[$$net]};
		delete $chans[$$net];
	});
}

} 1;
