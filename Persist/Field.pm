# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Persist::Field;
use strict;
use warnings;
use Carp;

sub TIEARRAY {
	my $class = shift;
	my $self = shift || [];
	bless $self, $class;
}

sub FETCH {
	my($s,$i) = @_;
	$s->[$i];
}

sub STORE {
	my($s,$i,$v) = @_;
	$s->[$i] = $v;
}

sub FETCHSIZE {
	my $s = shift;
	scalar @$s;
}

sub STORESIZE {
	my($s,$l) = @_;
	$#$s = $l - 1;
}

sub DELETE {
	my($s,$i) = @_;
	delete $s->[$i];
}

sub EXISTS {
	my($s,$i) = @_;
	exists $s->[$i];
}

1;
