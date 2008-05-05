# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;
use Modes;
use POSIX qw(strftime);

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

sub dump_now {
	my $fmt = $Conffile::netconf{set}{datefmt};
	my $fn = 'log/';
	if ($fmt) {
		$fn .= strftime $fmt, gmtime $Janus::time;
	} else {
		$fn .= $Janus::time;
	}
	$fn .= '.dump';
	if (-f $fn) {
		my $seq;
		1 while -f $fn.++$seq;
		$fn .= $seq;
	}

	open my $dump, '>', $fn or return undef;
	my $gbls = dump_all_globals(keys %Janus::modules);
	my $objs = &Persist::dump_all_refs();
	my %seen;
	my @tmp = keys %$gbls;
	for my $var (@tmp) {
		next unless $var =~ s/^&//;
		$seen{'*'.$var} = delete $gbls->{'&'.$var};
	}
	for my $pkg (keys %Persist::vars) {
		for my $var (keys %{$Persist::vars{$pkg}}) {
			$seen{"\$Replay::thaw_var->('$pkg','$var')"} = $Persist::vars{$pkg}{$var};
		}
	}
	for my $q (@Connection::queues) {
		my $sock = $q->[&Connection::SOCK()];
		next unless ref $sock;
		$seen{'$Replay::thaw_fd->('.$q->[&Connection::FD()].", '".ref($sock)."')"} = $sock;
	}

	my $dd = Data::Dumper->new([]);
	$dd->Sortkeys(1);
	$dd->Bless('findobj');
	$dd->Seen(\%seen);

	$dd->Names([qw(gnicks gchans gnets ijnets state listen)])->Values([
		\%Janus::gnicks,
		\%Janus::gchans,
		\%Janus::gnets,
		\%Janus::ijnets,
		\%Janus::states,
		\%Listener::open,
	]);
	$dd->Purity(1);
	print $dump $dd->Dump();
	$dd->Purity(0);
	$dd->Names([qw(global object arg)])->Values([
		$gbls,
		$objs,
		\@_,
	]);
	print $dump $dd->Dump();
	close $dump;
	$fn;
}

&Janus::command_add({
	cmd => 'dump',
	help => 'Dumps current janus internal state to a file',
	acl => 1,
	code => sub {
		my $fn = dump_now(@_);
		&Janus::jmsg($_[0], 'State dumped to file '.$fn);
	},
}, {
	cmd => 'testdie',
	acl => 1,
	code => sub {
		die "You asked for it!";
	},
});

&Janus::hook_add(
	ALL => 'die' => sub {
		eval {
			dump_now(@_);
			1;
		} or print "Error in dump: $@\n";
	},
);

1;
