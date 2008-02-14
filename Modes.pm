# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modes;
use Persist;
use strict;
use warnings;

our %mtype = ();

$mtype{$_} = 'n' for qw/voice halfop op admin owner/;
$mtype{$_} = 'l' for qw/ban except invex badwords/;
$mtype{$_} = 'v' for qw/
	flood flood3.2 forward joinlimit key
	kicknorejoin limit nickflood
/;
$mtype{$_} = 'r' for qw/
	auditorium badword blockcaps chanhide colorblock
	ctcpblock invite moderated mustjoin noinvite
	nokick noknock nooperover norenick noticeblock
	oper operadmin opernetadm opersvsadm reginvite
	register regmoderated sslonly topic
/;

=head1 IRC Mode utilities

Intended to be used by IRC server parsers

=over

=item (modes,args,dirs) Modes::from_irc(net,chan,mode,args...)

Translates an IRC-style mode string into a Janus mode change triplet

net must implement cmode2txt() and nick()

=cut

sub from_irc {
	my($net,$chan,$str) = (shift,shift,shift);
	my(@modes,@args,@dirs);
	local $_;
	my $pm = '+';
	for (split //, $str) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		my $txt = $net->cmode2txt($_) || '?';
		my $arg;
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			$arg = $net->nick(shift);
		} elsif ($type eq 'l') {
			$arg = shift;
		} elsif ($type eq 'v') {
			$arg = shift;
		} elsif ($type eq 's') {
			# "s" modes are emulated as "v" modes in janus
			if ($pm eq '+') {
				$arg = shift;
			} else {
				$arg = $chan->get_mode($txt);
			}
		} elsif ($type eq 't') {
			if ($txt =~ s/^t(\d+)/r/) {
				$arg = $1;
			} else {
				warn "Invalid mode text $txt for mode $_ in network $net";
				next;
			}
		} elsif ($type eq 'r') {
			$arg = 1;
		} else {
			warn "Invalid mode text $txt for mode $_ in network $net";
			next;
		}
		push @modes, substr $txt, 2;
		push @args, $arg;
		push @dirs, $pm;
	}
	(\@modes, \@args, \@dirs);
}

=item (mode, args...) Modes::to_irc(net, modes, args, dirs)

Translates a Janus triplet into its IRC equivalent

net must implement txt2cmode(), which must return undef for unknown modes

=cut

sub to_irc {
	my @m = to_multi(@_);
	warn "to_irc cannot handle overlong mode" if @m > 1;
	@m ? @{$m[0]} : ();
}

sub to_multi {
	my($net, $mods, $args, $dirs, $maxm, $maxl) = @_;
	$maxm ||= 100; # this will never be hit, maxl will be used instead
	$maxl ||= 450; # this will give enough room for a source, etc
	my @modin = @$mods;
	my @argin = @$args;
	my @dirin = @$dirs;
	my $pm = '';
	my @out;

	my($count,$len) = (0,0);
	my $mode = '';
	my @args;
	while (@modin) {
		my($txt,$arg,$dir) = (shift @modin, shift @argin, shift @dirin);
		my $type = $mtype{$txt};
		my $out = ($type ne 'r');

		my $char = $net->txt2cmode($type.'_'.$txt);
		if (!defined $char && $type eq 'v') {
			# maybe this is an s-type rather than a v-type command?
			$char = $net->txt2cmode('s_'.$txt);
			$out = 0 if $dir eq '-' && defined $char;
		}
		
		if (!defined $char && $type eq 'r') {
			# maybe a tristate mode?
			my $ar1 = $net->txt2cmode('t1_'.$txt);
			my $ar2 = $net->txt2cmode('t2_'.$txt);
			if ($ar1 && $ar2) {
				$char .= $ar1 if $arg & 1;
				$char .= $ar2 if $arg & 2;
			} elsif ($ar1 || $ar2) {
				# only one of the two available; use it
				$char = ($ar1 || $ar2);
			}
		}

		if (defined $char && $char ne '') {
			$count++;
			$len++ if $dir ne $pm;
			$len += length($char) + ($out ? 1 + length $arg : 0);
			if ($count > $maxm || $len > $maxl) {
				push @out, [ $mode, @args ];
				$pm = '';
				$mode = '';
				@args = ();
				$count = 1;
				$len = 1 + length($char) + ($out ? 1 + length $arg : 0);
			}
			$mode .= $dir if $dir ne $pm;
			$mode .= $char;
			$pm = $dir;
			push @args, $arg if $out;
		}
	}
	push @out, [ $mode, @args ] unless $mode =~ /^[-+]*$/;
	@out;
}

=item (modes, args, dirs) Modes::delta(chan1, chan2)

Returns the mode change required to make chan1's modes equal to
those of chan2

=cut

sub delta {
	my($chan1, $chan2) = @_;
	my %current = $chan1 ? %{$chan1->all_modes()} : ();
	my %add = $chan2 ? %{$chan2->all_modes()} : ();
	my(@modes, @args, @dirs);
	for my $txt (keys %current) {
		my $type = $mtype{$txt};
		if ($type eq 'l') {
			my %torm = map { $_ => 1 } @{$current{$txt}};
			if (exists $add{$txt}) {
				for my $i (@{$add{$txt}}) {
					if (exists $torm{$i}) {
						delete $torm{$i};
					} else {
						push @modes, $txt;
						push @dirs, '+';
						push @args, $i;
					}
				}
			}
			for my $i (keys %torm) {
				push @modes, $txt;
				push @dirs, '-';
				push @args, $i;
			}
		} else {
			if (exists $add{$txt}) {
				if ($current{$txt} eq $add{$txt}) {
					# hey, isn't that nice
				} else {
					push @modes, $txt;
					push @dirs, '+';
					push @args, $add{$txt};
				}
			} else {
				push @modes, $txt;
				push @dirs, '-';
				push @args, $current{$txt};
			}
		}
		delete $add{$txt};
	}
	for my $txt (keys %add) {
		my $type = $mtype{$txt};
		if ($type eq 'l') {
			for my $i (@{$add{$txt}}) {
				push @modes, $txt;
				push @dirs, '+';
				push @args, $i;
			}
		} else {
			push @modes, $txt;
			push @dirs, '+';
			push @args, $add{$txt};
		}
	}
	(\@modes, \@args, \@dirs);
}

=item Modes::merge(dest, src1, src2)

Merges the modes of the two channels src1 and src2 into the channel dest,
which is assumed to have no modes currently set.

=cut

sub merge {
	my($c0, $c1, $c2) = @_;
	my %allmodes;
	my %m1 = %{$c1->all_modes()};
	my %m2 = %{$c2->all_modes()};
	my $mset = $c0->all_modes();

	$allmodes{$_}++ for keys %m1;
	$allmodes{$_}++ for keys %m2;
	for my $txt (keys %allmodes) {
		my $type = $mtype{$txt};
		if ($type eq 'l') {
			my %m;
			if (exists $m1{$txt}) {
				$m{$_} = 1 for @{$m1{$txt}};
			}
			if (exists $m2{$txt}) {
				$m{$_} = 1 for @{$m2{$txt}};
			}
			$mset->{$txt} = [ keys %m ];
		} else {
			if (defined $m1{$txt}) {
				if (defined $m2{$txt} && $m1{$txt} ne $m2{$txt}) {
					print "Merging $txt: using $m1{$txt} over $m2{$txt}\n";
				} elsif (defined $m2{$txt}) {
					print "Merging $txt: using $m1{$txt} by agreement\n";
				} else {
					print "Merging $txt: using m1=$m1{$txt} by default\n";
				}
				$mset->{$txt} = $m1{$txt};
			} else {
				print "Merging $txt: using m2=$m2{$txt} by default\n";
				$mset->{$txt} = $m2{$txt};
			}
		}
	}
}

=back

=cut

1;
