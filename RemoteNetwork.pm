package RemoteNetwork;
use base 'Network';
use strict;
use warnings;

sub from_ij {
	my($class,$ij,$net) = @_;
	$net->{nicks} = {};
	$net->{chans} = {};
	$net->{jlink} = $ij;
	$ij->{nets}->{$net->{id}} = $net;
	bless $net, $class;
}

sub connect {
	die;
}

sub request_nick {
	die;
}

sub release_nick {
	die;
}

sub banlist {
	die;
}

1;
