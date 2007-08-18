package Persist;
use strict;
use warnings;
use Attribute::Handlers;
use Persist::Field;
our($VERSION) = '$Rev$' =~ /(\d+)/;

our %vars;

my %reuse;
my %max_gid;

sub Persist : ATTR(ARRAY,BEGIN) {
	my($pk, $sym, $var, $attr, $dat, $phase) = @_;
	my $src = $vars{$pk}{$dat} || [];
	$vars{$pk}{$dat} = $src;
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

sub gid_find {
	my %tops = ( $_[0] => 1 );
	my %isas = ( $_[0] => 1 );
	my $again = 1;
	while ($again) {
		$again = 0;
		for my $pkg (keys %tops) {
			my %isa = map { $_ => 1 } do {
				no strict 'refs';
				@{$pkg.'::ISA'};
			};
			if ($isa{__PACKAGE__ . ''}) {
				unless (1 == keys %isa) {
					$again = 1;
					delete $tops{$pkg};
					$isas{$_}++, $tops{$_}++ for keys %isa;
				}
			} else {
				delete $tops{$pkg};
				delete $isas{$pkg};
				$isas{$_}++, $tops{$_}++ for keys %isa;
			}
		}
	}
	delete $isas{$_} for keys %tops;
	delete $tops{__PACKAGE__ . ''};
	warn "Multiple top-level inheritance doesn't work: ".join ' ', keys %tops if 1 < scalar keys %tops;
	keys(%tops), keys(%isas);
}

sub new {
	my($pk) = gid_find $_[0];
	my $n = $reuse{$pk} && @{$reuse{$pk}} ?
		(shift @{$reuse{$pk}}) :
		(++$max_gid{$pk});
	bless \$n, $pk;
}

sub DESTROY {
	my $self = shift;
	return unless $$self;
	my @pkgs = gid_find ref $self;
	for my $pkg (@pkgs) {
		for my $aref (values %{$vars{$pkg}}) {
			delete $aref->[$$self];
		}
	}
	push @{$reuse{$pkgs[0]}}, $$self;
}

1;
