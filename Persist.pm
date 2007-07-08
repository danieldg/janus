package Persist;
use strict;
use warnings;
use Filter::Util::Call;

sub import {
	my $pkg = caller;
	my $state = eval "\$${pkg}::PERSIST_STATE;";
	my $first = !defined $state;
	eval "\$${pkg}::PERSIST_STATE = {}" if $first;
	my $filter = bless {
		pkg => $pkg,
		init => 0,
		runonce => 0,
		first => $first,
		state => $state,
	};
	filter_add($filter);
}

sub filter {
	my $self = $_[0];
	my $status = filter_read();
	return $status unless $status > 0;
	if (/^__PERSIST__$/) {
		$self->{init}++;
		$_ = "our \$PERSIST_STATE;\n";
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
	}

	s/^/#/ if $self->{comment};
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
