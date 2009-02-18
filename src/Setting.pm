# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Setting;
use strict;
use warnings;

our %value;
for my $nk (keys %Janus::setting) {
	for my $ik (keys %{$Janus::setting{$nk}}) {
		$value{$ik.' '.$nk} = $Janus::setting{$nk}{$ik};
	}
}

Janus::save_vars(value => \%value);

sub get {
	my($name, $key) = @_;
	my $iid =
		$key->isa('Network') ? $key->name :
		$key->isa('Channel') ? $key->netname :
		$key.'';
	my $val = $value{$name.' '.$iid};
	$val = $Event::settings{$name}{default} unless $val;
	return $val;
}

sub set {
	my($name, $key, $val) = @_;
	my $iid =
		$key->isa('Network') ? $key->name :
		$key->isa('Channel') ? $key->netname :
		$key.'';
	if ($val) {
		$value{$name.' '.$iid} = $val;
	} else {
		delete $value{$name.' '.$iid};
	}
}
