# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Server::BaseParser;
use LocalNetwork;
use Persist 'LocalNetwork';
use strict;
use warnings;

our @rawout;
Persist::register_vars(qw(rawout));

sub _init {
	my $net = shift;
	$rawout[$$net] = '';
}

sub parse {
	my($net, $line) = @_;
	return () unless $line;
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	unshift @args, undef unless $args[0] =~ s/^://;
	return () unless $net->inner_parse(\@args, $line);
	my @hand = $net->hook(parse => $args[1]);
	@hand = $net->no_parse_hand(@args) unless @hand;
	return map { $_->($net, @args) } @hand;
}

sub inner_parse { 1 }

sub no_parse_hand {
	my($net, undef, $cmd) = @_;
	Log::warn_in($net, "Unknown command '$cmd'");
	();
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			my @hand = $net->hook('send', $type);
			my @lines = map { $_->($net, $act) } @hand;
			if (@lines) {
				unshift @lines, $net->dump_reorder();
				$net->inner_send(\@lines);
				$rawout[$$net] .= join "\r\n", @lines, '';
			}
		} else {
			my @lines = ($net->dump_reorder(), $act);
			$net->inner_send(\@lines);
			$rawout[$$net] .= join "\r\n", @lines, '';
		}
	}
}

sub dump_reorder {
	()
}

sub inner_send {
	my($net, $lines) = @_;
	Log::netout($net, $_) for @$lines;
}

# send without reorder buffer or hooks
sub rawsend {
	my $net = shift;
	$net->inner_send(\@_);
	$rawout[$$net] .= join "\r\n", @_, '';
}

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = $rawout[$$net];
	$rawout[$$net] = '';
	my @lines = $net->dump_reorder();
	$net->inner_send(\@lines) if @lines;
	$q .= join "\r\n", @lines, '';
	$q;
}

sub cmd1 {
	my $net = shift;
	$net->cmd2(undef, @_);
}

sub cmd2 {
	my($net,$src) = (shift,shift);
	my $out = defined $src ? ':'.$net->_out($src).' ' : '';
	$out .= join ' ', map { $net->_out($_) } @_;
	$out;
}

sub ncmd {
	my $net = shift;
	$net->cmd2($net->cparam('linkname'), @_);
}

### Mode parsing and deparsing

sub umode_from_irc {
	my($net, $mode) = (shift, shift);
	my @mode;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
		} else {
			my @hooks = $net->hook(umode_in => $_);
			push @mode, map { $_->($pm, @_) } @hooks;
		}
	}
	\@mode;
}

sub umode_to_irc {
	my($net, $modes) = (shift, shift);
	my $out = '';
	my $pm = '';
	for my $ltxt (@$modes) {
		my($d, $txt) = $ltxt =~ /^([-+]?)(.+?)$/;
		my @hooks = $net->hook(umode_out => $txt);
		my $char = join '', map { $_->($d || '+', @_) } @hooks;
		if ($pm ne $d) {
			$pm = $d;
			$out .= $d;
		}
		$out .= $char;
	}
	$out;
}

sub cmode_from_irc {
	my($net,$chan,$str) = (shift,shift,shift);
	my(@modes,@args,@dirs);
	local $_;
	my $pm = '+';
	for (split //, $str) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		$_->($net, $pm, $chan, \@_, \@modes, \@args, \@dirs) for $net->hook(cmode_in => $_);
	}
	(\@modes, \@args, \@dirs, @_);
}

sub cmode_to_irc {
	my($net, $chan, $mods, $args, $dirs, $maxm, $maxl) = @_;
	$maxm ||= 100; # this will never be hit, maxl will be used instead
	$maxl ||= 450; # this will give enough room for a source, etc
	my $pm = '';

	my($count,$len, $mode) = (0,0, '');
	my(@args, @out);
	for my $i (0..$#$mods) {
		my($txt,$arg,$dir) = ($mods->[$i], $args->[$i], $dirs->[$i]);
		for my $h ($net->hook(cmode_out => $txt)) {
			my($m, @a) = map { $net->_out($_) } $h->($net, $chan, $txt, $arg, $dir);
			$count += length $m;
			$len += length join ' ', $m, @a;
			if ($count > $maxm || $len > $maxl) {
				push @out, [ $mode, @args ];
				$count = length $m;
				$len = length join ' ', $m, @a;
				$mode = '';
				@args = ();
			}
			($pm,$mode) = ($dir, $mode.$dir) if $dir ne $pm && defined $m;
			$mode .= $m;
			push @args, @a;
		}
	}
	push @out, [ $mode, @args ] unless $mode =~ /^[-+]*$/;
	@out;
}

sub cmode_to_irc_1 {
	my $net = shift;
	my @out = $net->cmode_to_irc(@_);
	return '+' unless @out;
	Log::warn_in($net, "Need multiline mode in cmode_to_irc_1") if @out > 1;
	return @{$out[0]};
}

1;
