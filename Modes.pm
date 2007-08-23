# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Modes;
use Persist;
use strict;
use warnings;

our($VERSION) = '$Rev: 329 $' =~ /(\d+)/;

&Janus::hook_add(
	MODE => check => sub {
		my $act = shift;
		local $_;
		my $chan = $act->{dst};
		my @mode = @{$act->{mode}};
		my @nargs;
		my @args = @{$act->{args}};
		for my $itxt (@{$act->{mode}}) {
			my $pm = substr $itxt, 0, 1;
			my $t = substr $itxt, 1, 1;
			my $i = substr $itxt, 1;
			if ($t eq 'n') {
				push @nargs, shift @args;
			} elsif ($t eq 'l') {
				push @nargs, shift @args;
			} elsif ($t eq 'v') {
				my $val = shift @args;
				push @nargs, $val;
				$itxt =~ s/v/s/;
				push @mode, $itxt;
				push @args, $val if $pm eq '+';
			} elsif ($t eq 's') {
				my $val = ($pm eq '+') ? shift @args : $chan->get_mode($i);
				$itxt =~ s/s/v/;
				push @mode, $itxt;
				push @args, $val;
			} elsif ($t eq 'r') {
			} elsif ($t eq 't') {
			} else {
				warn "Unknown mode '$itxt'";
			}
		}
		push @nargs, @args;
		$act->{mode} = \@mode;
		$act->{args} = \@nargs;
		0;
	},
);

1;
