package Persist;
use strict;
use warnings;
use Attribute::Handlers;
use Persist::Field;
our($VERSION) = '$Rev$' =~ /(\d+)/;

our %vars;

sub Persist : ATTR(ARRAY,BEGIN) {
	my($pk, $sym, $var, $attr, $dat, $phase) = @_;
	my $src = $vars{$pk}{$dat} || [];
	$vars{$pk}{$dat} = $src;
	print "Persist: $pk-$dat\n";
	tie @$var, 'Persist::Field', $src;
}

sub import {
	my $self = shift;
	return unless $self eq __PACKAGE__;
	my $pkg = caller;
	{
		no strict 'refs';
		push @{$pkg.'::ISA'}, $self;
	}
}

sub new {
	my $pk = shift;
	my $n = $
	bless $$n, $pk;
}

sub DESTROY {
	my $self = shift;
	my $pk = ref $self;
	return unless $$self;
	for my $aref (values %{$vars{$pk}}) {
		delete $aref->[$$self];
	}
}


1;
