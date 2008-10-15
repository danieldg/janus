# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Snapshot;
use strict;
use warnings;
use Data::Dumper;

eval {
	&Data::Dumper::init_refaddr_format();
	# BUG in Data::Dumper, running this is needed before using Seen
};

our $preread;

sub dump_all_globals {
	my %rv;
	for my $pkg (@_) {
		my $ns = do { no strict 'refs'; \%{$pkg.'::'} };
		next unless $ns;
		for my $var (keys %$ns) {
			next if $var =~ /:/ || $var eq 'ISA'; # perl internal variable
			next if ref $ns->{$var}; # Perl 5.10 constants

			my $scv = *{$ns->{$var}}{SCALAR};
			my $arv = *{$ns->{$var}}{ARRAY};
			my $hsv = *{$ns->{$var}}{HASH};
			my $cdv = *{$ns->{$var}}{CODE};
			$rv{'$'.$pkg.'::'.$var} = $$scv if $scv && defined $$scv;
			$rv{'@'.$pkg.'::'.$var} = $arv  if $arv && scalar @$arv;
			$rv{'%'.$pkg.'::'.$var} = $hsv  if $hsv && scalar keys %$hsv;
			$rv{'&'.$pkg.'::'.$var} = $cdv  if $cdv;
		}
	}
	\%rv;
}

sub dump_to {
	my($dump,$pure,$arg) = @_;
	my @modlist = keys %Janus::modinfo;
	my $gbls = dump_all_globals(@modlist);
	my $stat = {};
	my $objs = &Persist::dump_all_refs();
	my %seen;
	my @tmp = keys %$gbls;
	for my $var (@tmp) {
		next unless $var =~ s/^&//;
		$seen{'*'.$var} = delete $gbls->{'&'.$var};
	}
	for my $var (keys %Janus::static) {
		for ('$', '@', '%') {
			my $v = delete $gbls->{$_.$var};
			$stat->{$_.$var} = $v if $v;
		}
	}
	for my $pkg (keys %Persist::vars) {
		for my $var (keys %{$Persist::vars{$pkg}}) {
			$seen{"\$thaw_var->('$pkg','$var')"} = $Persist::vars{$pkg}{$var};
		}
	}
	for my $q (@Connection::queues) {
		my $sock = $q->[&Connection::SOCK()];
		next unless ref $sock;
		$seen{'$thaw_fd->('.$q->[&Connection::FD()].", '".ref($sock)."')"} = $sock;
	}

	my $dd = Data::Dumper->new([]);
	$dd->Sortkeys(1);
	$dd->Bless('findobj');
	$dd->Seen(\%seen);

	my %chanlist = %Janus::gchans;
	for my $net (values %Janus::nets) {
		next unless $net->isa('LocalNetwork');
		for my $chan ($net->all_chans) {
			$chanlist{$chan->real_keyname} = $chan;
		}
	}

	$dd->Names([qw(gnicks chanlist nets ijnets pending listen modules states)])->Values([
		\%Janus::gnicks,
		\%chanlist,
		\%Janus::nets,
		\%Janus::ijnets,
		\%Janus::pending,
		\%Listener::open,
		\@modlist,
		\%Janus::states,
	]);
	$dd->Purity(1);
	print $dump $dd->Dump();
	$dd->Purity(0);
	$dd->Names(['static'])->Values([ $stat ]);
	my $staticdump = $dd->Dump();
	print $dump $staticdump unless $pure;
	print $dump "load_all();\n";
	$dd->Purity($pure);
	$dd->Names([qw(global object arg)])->Values([
		$gbls,
		$objs,
		$arg,
	]);
	print $dump $dd->Dump();
}

sub restore_from {
	my($file) = @_;
	$preread = 1;
	require Conffile;
	$Conffile::conffile = $main::ARGV[0] if @main::ARGV;
	&Conffile::read_conf();
	$preread = 0;
	&Restore::Var::run($file);
	my @logq = @Log::queue;
	for my $var (keys %$Restore::Var::global) {
		my $val = $Restore::Var::global->{$var};
		no strict 'refs';
		$var =~ s/^(.)//;
		if ($1 eq '$') {
			${$var} = $val;
		} elsif ($1 eq '@') {
			@{$var} = @$val;
		} elsif ($1 eq '%') {
			%{$var} = %$val;
		} else {
			die "Unknown global variable type $1$var";
		}
	}

	for my $pkg (keys %$Restore::Var::object) {
		for my $oid (keys %{$Restore::Var::object->{$pkg}}) {
			for my $var (keys %{$Restore::Var::object->{$pkg}{$oid}}) {
				$Persist::vars{$pkg}{$var}[$oid] = $Restore::Var::object->{$pkg}{$oid}{$var};
			}
		}
	}

	&Log::debug('Pre-restore events:');
	push @Log::queue, @logq;
	&Log::debug("Beginning debug deallocations");
	&Restore::Var::clear();

	&Log::debug("State restored.");
	&Janus::insert_full({
		type => 'RESTORE',
	});
}

package Restore::Var;
use Scalar::Util 'blessed';

our($gnicks, $chanlist, $nets, $ijnets, $pending, $listen, $modules, $states);
our($static, $global, $object, $args);
our(%obj_db, $thaw_var, $thaw_fd);

sub clear {
	($gnicks, $chanlist, $nets, $ijnets, $pending, $listen,
	 $modules, $states, $static, $global, $object, $args) = 
	(undef, undef, undef, undef, undef, undef, 
	 undef, undef, undef, undef, undef,	undef);
	%obj_db = ();
}

sub run {
	do $_[0];
	my $err = $@;
	die "Failed to restore: $err" unless $object;
}

sub regobj {
	for my $o (@_) {
		next unless $o && blessed($o);
		my $class = ref $o;
		$obj_db{$class}{$$o} = $o;
	}
}

sub findobj {
	my($o, $class) = @_;
	return bless($o,$class) unless 'SCALAR' eq ref $o && $$o;
	my $c = $obj_db{$class}{$$o};
	$c || bless($o,$class);
}

sub load_all {
	for my $mod (@$modules) {
		&Janus::load($mod);
	}
	regobj %Janus::gnicks, %Janus::gnets, $Janus::global, $RemoteJanus::self;
	$static = &Snapshot::dump_all_globals(@$modules);
}

$thaw_var = sub {
	my($class, $var) = @_;
	$Persist::vars{$class}{$var};
};

$thaw_fd = sub { die "Tried to thaw FD @_" };

1;
