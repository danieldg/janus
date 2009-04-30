# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Modes;
use Persist;
use strict;
use warnings;
use Carp;

our %mtype;

$mtype{$_} = 'n' for qw/voice halfop op admin owner/;
$mtype{$_} = 'l' for qw/
	ban except invex badwords
	quiet_ban renick_ban gecos_ban
	quiet_ex renick_ex gecos_ex gecos_inv
/;
$mtype{$_} = 'v' for qw/
	flood flood3.2 forward joinlimit key
	kicknorejoin limit nickflood
/;
$mtype{$_} = 'r' for qw/
	auditorium badword blockcaps chanhide colorblock
	ctcpblock invite moderated mustjoin noinvite
	nokick noknock norenick noticeblock
	oper reginvite regmoderated sslonly topic
	delayjoin allinvite permanent survey jcommand
	cb_direct cb_modesync cb_topicsync cb_showjoin
/;

our @nmode_txt = qw{owner admin op halfop voice};
our @nmode_sym = qw{~ & @ % +};
Janus::static(qw(nmode_txt nmode_sym mtype));

=head1 IRC Mode utilities

Intended to be used by IRC server parsers

=over

=item type Modes::mtype(text)

Gives the channel mode type, which is one of:

 r - regular mode, value is integer 0/1 (or 2+ for tristate modes)
 v - text-valued mode, value is text of mode
 l - list-valued mode, value is listref; set/unset single list item
 n - nick-valued mode, value is nick object

=cut

sub mtype {
	my $m = $_[0];
	local $1;
	return $mtype{$m} || ($m =~ /^_(.)/ ? $1 : '');
}

sub implements {
	my($net,$txt) = @_;
	return 0 unless $net->can('hook');
	my @hooks = $net->hook(cmode_out => $txt);
	scalar @hooks;
}

=item (modes, args, dirs) Modes::dump(chan)

Returns the non-list modes of the channel

=cut

sub dump {
	my $chan = shift;
	my %modes = %{$chan->all_modes()};
	my(@modes, @args, @dirs);
	for my $txt (keys %modes) {
		my $type = mtype($txt);
		next if $type eq 'l';
		push @modes, $txt;
		push @dirs, '+';
		push @args, $modes{$txt};
	}
	(\@modes, \@args, \@dirs);
}

=item (modes, args, dirs) Modes::delta(chan1, chan2, net, reops)

Returns the mode change required to make chan1's modes equal to
those of chan2. If network is specified, filters to modes available
on that network. If reops is true, include op/deop mode changes.

=cut

sub delta {
	my($chan1, $chan2, $net, $reops) = @_;
	my %current = $chan1 ? %{$chan1->all_modes()} : ();
	my %add =
		'HASH' eq ref $chan2 ? %$chan2 :
		$chan2 ? %{$chan2->all_modes()} :
		();
	my(@modes, @args, @dirs);
	for my $txt (keys %current) {
		next if $net && !implements($net, $txt);
		my $type = mtype($txt);
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
		next if $net && !implements($net, $txt);
		my $type = mtype($txt);
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
	if ($reops && $chan1 && $chan1->isa('Channel')) {
		for my $nick ($chan1->all_nicks) {
			for my $mode (qw/voice halfop op admin owner/) {
				next unless $chan1->has_nmode($mode, $nick);
				push @modes, $mode;
				push @args, $nick;
				push @dirs, '-';
			}
		}
	}
	if ($reops && $chan2 && $chan2->isa('Channel')) {
		for my $nick ($chan2->all_nicks) {
			for my $mode (qw/voice halfop op admin owner/) {
				next unless $chan2->has_nmode($mode, $nick);
				push @modes, $mode;
				push @args, $nick;
				push @dirs, '+';
			}
		}
	}
	(\@modes, \@args, \@dirs);
}

=item (modes, args, dirs) Modes::revert($chan, $modes, $args, $dirs)

Returns the mode changes required to revert the given MODE action

=cut

sub revert {
	my($chan, $min, $ain, $din) = @_;
	my(@modes, @args, @dirs);
	for my $i (0 .. $#$din) {
		my($m,$a,$d) = ($min->[$i], $ain->[$i], $din->[$i]);
		my $t = Modes::mtype($m);
		my $v = $a;
		my $r;
		if ($t eq 'n') {
			$r = $chan->has_nmode($m, $a) ? '+' : '-';
		} elsif ($t eq 'l') {
			my $val = $chan->get_mode($m) || [];
			$r = '-';
			for my $b (@$val) {
				if ($a eq $b) {
					$r = '+';
					last;
				}
			}
		} else {
			my $val = $chan->get_mode($m);
			if ($val) {
				$r = '+';
				$v = $val;
			} else {
				$r = '-';
				$v = 3 if $t eq 'r';
			}
		}
		if ($d ne $r || $v ne $a) {
			push @modes, $m;
			push @args, $v;
			push @dirs, $r;
		}
	}
	(\@modes, \@args, \@dirs);
}

sub chan_pfx {
	my($chan, $nick, $net) = @_;
	join '', map {
		$chan->has_nmode($nmode_txt[$_], $nick) && (!$net || implements($net, $nmode_txt[$_])) ? $nmode_sym[$_] : ''
	} 0..$#nmode_txt;
}

=back

=cut

1;
