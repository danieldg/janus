# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Debug;
use strict;
use warnings;
use Data::Dumper;
use Modes;

our $DUMP_SEQ;

sub dump_all_globals {
	my %rv;
	for my $pkg (@_) {
		my $ns = do { no strict 'refs'; \%{$pkg.'::'} };
		next unless $ns;
		my %objarr;
		if ($pkg eq 'Persist') {
			$objarr{\%Persist::vars}++;
			$objarr{\%Persist::init_args}++;
		} elsif ($Persist::vars{$pkg}) {
			$objarr{$_}++ for values %{$Persist::vars{$pkg}};
		}
		for my $var (keys %$ns) {
			next if $var =~ /:/ || $var eq 'ISA'; # perl internal variable
			my $scv = *{$ns->{$var}}{SCALAR};
			my $arv = *{$ns->{$var}}{ARRAY};
			my $hsv = *{$ns->{$var}}{HASH};
			$rv{'$'.$pkg.'::'.$var} = $$scv if $scv && defined $$scv;
			$rv{'@'.$pkg.'::'.$var} = $arv  if $arv && scalar @$arv && !$objarr{$arv};
			$rv{'%'.$pkg.'::'.$var} = $hsv  if $hsv && scalar keys %$hsv && !$objarr{$hsv};
		}
	}
	\%rv;
}

sub dump_now {
	# workaround for a bug in Data::Dumper that only allows one "new" socket per dump
	for (values %Connection::queues) {
		eval { Data::Dumper::Dumper(\%Connection::queues); 1 } and last;
	}

	my $fn = 'log/dump-'.$Janus::time.'-'.++$DUMP_SEQ;
	open my $dump, '>', $fn or return;
	my @all = (
		\%Janus::gnicks,
		\%Janus::gchans,
		\%Janus::gnets,
		\%Janus::ijnets,
		dump_all_globals(keys %Janus::modules),
		&Persist::dump_all_refs(),
		@_,
	);
	local $Data::Dumper::Sortkeys = 1;
	for (1..10) {
		eval {
			print $dump Data::Dumper::Dumper(\@all);
			1;
		} and last;
	}
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
		dump_now(@_);
	},
);

1;
