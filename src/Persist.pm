# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Persist;
use strict;
use warnings;

our %vars;

our %init_args;
our %reuse;
our %max_gid;
our %gid_shrink;

&Janus::static(qw(vars init_args));

sub dump_all_refs {
	my %out;
	for my $pk (keys %vars) {
		my %oops;
		for my $var (keys %{$vars{$pk}}) {
			next if $Janus::static{$pk.'::'.$var};
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
		@{$pkg.'::ISA'} = (@_, $self);
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

	my $re = $reuse{$pk} || [];
	if (@$re > 2*--$gid_shrink{$pk}) {
		$re = $reuse{$pk} = [ sort { $a <=> $b } @$re ];
		while (@$re && $max_gid{$pk} == $re->[-1]) {
			pop @$re; $max_gid{$pk}--;
		}
		$gid_shrink{$pk} = @$re;
	}
	push @$re, ++$max_gid{$pk} unless @$re;

	my $n = shift @$re;
	my $s = bless \$n, $target;

	for my $pkg (@pkgs) {
		next unless $init_args{$pkg};
		for my $arg (keys %{$init_args{$pkg}}) {
			$init_args{$pkg}{$arg}[$n] = $args{$arg};
		}
	}
	my @objid;
	for my $pkg (@pkgs) {
		no strict 'refs';
		my $init = *{$pkg.'::_init'}{CODE};
		push @objid, $init->($s, \%args) if $init;
	}
	&Log::alloc($s, 'allocated', grep defined && !ref, @objid);
	$s;
}

sub DESTROY {
	my $self = shift;
	return unless $$self;
	my @pkgs = gid_find ref $self;
	my @objid;
	for my $pkg (@pkgs) {
		no strict 'refs';
		my $dest = *{$pkg.'::_destroy'}{CODE};
		push @objid, $dest->($self) if $dest;
	}
	&Log::alloc($self, 'deallocated', grep defined && !ref, @objid);
	for my $pkg (@pkgs) {
		for my $aref (values %{$vars{$pkg}}) {
			delete $aref->[$$self];
		}
	}
	push @{$reuse{$pkgs[0]}}, $$self;
}

sub _enhash {
	my $pk = shift;
	my $ns = do { no strict 'refs'; \%{$pk.'::'} };
	my %h;
	while (@_) {
		my $v = pop;
		if (ref $v) {
			$h{pop @_} = $v
		} else {
			my $tg = $ns->{$v} or die "Undefined variable $v requested by $pk";
			$h{$v} = *$tg{ARRAY};
		}
	}
	\%h;
}

sub autoget {
	my $pk = caller;
	my $arg = _enhash($pk, @_);
	for (keys %$arg) {
		my $var = $arg->{$_};
		no strict 'refs';
		*{$pk.'::'.$_} = sub {
			$var->[${$_[0]}];
		}
	}
}

sub autoinit {
	my $pk = caller;
	my $arg = _enhash($pk,@_);
	for (keys %$arg) {
		$init_args{$pk}{$_} = $arg->{$_};
	}
}

sub register_vars {
	my $pk = caller;
	my $arg = _enhash($pk,@_);
	for (keys %$arg) {
		if (/^(.+)::([^:]+)$/) {
			$vars{$1}{$pk.'::'.$2} = $arg->{$_};
		} else {
			$vars{$pk}{$_} = $arg->{$_};
		}
	}
}

sub poison {
	my $ref = shift;
	return if ref $ref eq 'Persist::Poison';
	&Log::alloc($ref, 'poisoned');
	my $cls = ref $ref;
	my $oid = $$ref;
	my $pdata = bless {
		class => $cls,
		id => $oid,
		ts => $Janus::time,
		refs => 0,
	}, 'Persist::Poison::Int';
	$$ref = $pdata;
	bless $ref, 'Persist::Poison';
}

sub unpoison {
	my $ref = shift;
	return unless ref $ref eq 'Persist::Poison';
	my $pdata = $$ref;
	$$ref = $pdata->{id};
	bless $ref, $pdata->{class};
	&Log::alloc($ref, 'unpoisoned', $pdata->{ts}, $pdata->{refs});
}

package Persist::Poison;

our $AUTOLOAD;

sub DESTROY {
	my $ref = shift;
	my $fake = $$ref->{id};
	bless \$fake, $$ref->{class};
}

sub AUTOLOAD {
	local $_;
	my $ref = $_[0];
	my($method) = $AUTOLOAD =~ /.*::([^:]+)/;
	$$ref->{refs}++;
	&Log::poison(caller, $method, $$ref, @_);
	my $sub = &UNIVERSAL::can($$ref->{class}, $method);
	goto &$sub;
}

sub isa {
	my $ref = $_[0];
	$$ref->{refs}++;
	&Log::poison(caller, 'isa', $$ref, @_);
	&UNIVERSAL::isa($$ref->{class}, $_[1]);
}

package Persist::Poison::Int;

use overload '0+' => sub {
	local $_;
	my $pdat = $_[0];
	$pdat->{refs}++;
	&Log::poison(caller, '+', $pdat);
	$pdat->{id};
}, '<=>' => sub {
	local $_;
	my $side = ref $_[0];
	my $pdat = $side ? $_[0] : $_[1];
	$pdat->{refs}++;
	&Log::poison(caller, '=', $pdat);
	$side ? ($pdat->{id} <=> $_[1]) : ($_[0] <=> $pdat->{id});
};

1;
