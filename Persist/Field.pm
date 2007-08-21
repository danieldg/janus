package Persist::Field;
use strict;
use warnings;
use Carp;

our($VERSION) = '$Rev$' =~ /(\d+)/;

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

1;
