# Copyright (C) 2007 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Persist;
use strict;
use warnings;
use Attribute::Handlers;
use Persist::Field;

our %vars;

our %init_args;
our %reuse;
our %max_gid;

sub Persist : ATTR(ARRAY,BEGIN) {
	my($pk, $sym, $var, $attr, $dat, $phase) = @_;
	my $src = $vars{$pk}{$dat} || [];
	$vars{$pk}{$dat} = $src;
	tie @$var, 'Persist::Field', $src;
}

sub PersistAs : ATTR(ARRAY,BEGIN) {
	my($spk, $sym, $var, $attr, $dat, $phase) = @_;
	my($pk, $name) = @$dat;
	$name = $spk.'::'.$name;
	my $src = $vars{$pk}{$name} || [];
	$vars{$pk}{$name} = $src;
	tie @$var, 'Persist::Field', $src;
}

sub dump_all_refs {
	my %out;
	for my $pk (keys %vars) {
		my %oops;
		for my $var (keys %{$vars{$pk}}) {
			my $arr = $vars{$pk}{$var};
			for my $i (0..$#$arr) {
				next unless exists $arr->[$i];
				$oops{$i}{$var} = $arr->[$i];
			}
		}
		if (%oops) {
			$out{$pk} = \%oops;
		}
	}
	\%out;
}

sub import {
	my $self = shift;
	return unless $self eq __PACKAGE__;
	my $pkg = caller;
	{
		no strict 'refs';
		push @{$pkg.'::ISA'}, @_, $self;
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
	warn "Can't find top-level inheritance object for $_[0]" unless %tops;
	warn "Multiple top-level inheritance doesn't work: ".join ' ', keys %tops if 1 < scalar keys %tops;
	keys(%tops), keys(%isas);
}

sub new {
	my $target = shift;
	my %args = @_;

	my @pkgs = gid_find $target;
	my $pk = $pkgs[0];

	my $n = $reuse{$pk} && @{$reuse{$pk}} ?
		(shift @{$reuse{$pk}}) :
		(++$max_gid{$pk});
	my $s = bless \$n, $target;
	
	for my $pkg (@pkgs) {
		next unless $init_args{$pkg};
		for my $arg (keys %{$init_args{$pkg}}) {
			$init_args{$pkg}{$arg}[$n] = $args{$arg};
		}
	}
	for my $pkg (@pkgs) {
		no strict 'refs';
		my $init = *{$pkg.'::_init'}{CODE};
		$init->($s, \%args) if $init;
	}
	$s;
}

sub DESTROY {
	my $self = shift;
	return unless $$self;
	$self->_destroy() if $self->can('_destroy');
	my @pkgs = gid_find ref $self;
	for my $pkg (@pkgs) {
		for my $aref (values %{$vars{$pkg}}) {
			delete $aref->[$$self];
		}
	}
	push @{$reuse{$pkgs[0]}}, $$self;
}

sub Get : ATTR(ARRAY) {
#	my($pk, $sym, $var, $attr, $dat, $phase) = @_;
	my $var = $_[2];
	no strict 'refs';
	*{"$_[0]::$_[4]"} = sub {
		$var->[${$_[0]}];
	}
}

sub Arg : ATTR(ARRAY) {
	my($pk, $sym, $var, $attr, $dat, $phase) = @_;
	$init_args{$pk}{$dat} = $var;
}

1;
