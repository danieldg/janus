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
			$seen{"\$Snapshot::thaw_var->('$pkg','$var')"} = $Persist::vars{$pkg}{$var};
		}
	}
	for my $q (@Connection::queues) {
		my $sock = $q->[&Connection::SOCK()];
		next unless ref $sock;
		$seen{'$Snapshot::thaw_fd->('.$q->[&Connection::FD()].", '".ref($sock)."')"} = $sock;
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
	$dd->Purity($pure);
	$dd->Names([qw(global object arg)])->Values([
		$gbls,
		$objs,
		$arg,
	]);
	print $dump $dd->Dump();
}

1;
