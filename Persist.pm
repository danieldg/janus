package Persist;
use strict;
use warnings;
use Filter::Util::Call;

our($VERSION) = '$Rev$' =~ /(\d+)/;

sub import {
	my $pkg = caller;
	my $state = eval "\$${pkg}::PERSIST_STATE;";
	my $first = !defined $state;
	eval "\$${pkg}::PERSIST_STATE = {}" if $first;
	my $filter = bless {
		pkg => $pkg,
		init => 0,
		runonce => 0,
		qlevel => 0,
		first => $first,
		state => $state,
	};
	filter_add($filter);
}

sub filter {
	my $self = $_[0];
	my $status = filter_read();
	unless ($status > 0) {
		if ($self->{qlevel}) {
			$_ = '';
			for my $i (1 .. $self->{qlevel}) {
				s/(['\\])/\\$1/g;
				$_ .= "' or die \$\@;";
			}
			$self->{qlevel} = 0;
			return 1;
		}
		return $status;
	}
	if (/^__PERSIST__$/) {
		$self->{init}++;
		$_ = ($self->{first} ? '' : 'use Data::Alias;'). "our \$PERSIST_STATE;\n";
	} elsif (s/^\s*__RUNFIRST__//) {
		s/^/#/ unless $self->{first};
	} elsif (s/^\s*__RUNFIRST_START__//) {
		$self->{comment} = !$self->{first};
	} elsif (s/^\s*__RUNELSE__//) {
		s/^/#/ if $self->{first};
	} elsif (s/^\s*__RUNELSE_START__//) {
		$self->{comment} = $self->{first};
	} elsif (s/^\s*__RUN(FIRST|ELSE)_END__//) {
		$self->{comment} = 0;
	} elsif (/^__CODE__$/) {
		$self->{qlevel}++;
		$_ = q{eval '#line '.__LINE__.' "'.__FILE__."\"\n".'};
		$_ .= $self->{first} ? "\n" : "no warnings qw(redefine);\n";
		return $status;
	}

	s/^/#/ if $self->{comment};
	for my $i (1 .. $self->{qlevel}) { s/(['\\])/\\$1/g }
	return $status unless $self->{init};

	if (/^persist ([\%\@\$])([^ =]+)(.*?);\s*(#|$)/) {
		my ($t,$var,$args) = ($1,$2,$3);
		if ($self->{state}->{$t.$var}) {
			$_ = "my $t$var; alias $t$var = $t\{\$PERSIST_STATE->{'$t$var'}};\n";
		} else {
			$_ = "my $t$var$args; \$PERSIST_STATE->{'$t$var'} = \\$t$var;\n";
		}
	}
	$status;
}

1;
