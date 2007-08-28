# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Channel;
use Persist;
use strict;
use warnings;
BEGIN {
	&Janus::load('Nick');
}

our($VERSION) = '$Rev$' =~ /(\d+)/;

=head1 Channel

Object representing a set of linked channels

=over

=cut

my @ts       :Persist(ts)                     :Get(ts);
my @name     :Persist(keyname)                :Get(keyname);
my @topic    :Persist(topic)   :Arg(topic)    :Get(topic);
my @topicts  :Persist(topicts) :Arg(topicts)  :Get(topicts);
my @topicset :Persist(topicts) :Arg(topicset) :Get(topicset);
my @mode     :Persist(mode);
my @nicks    :Persist(nicks);
my @nmode    :Persist(nmode);

=item $chan->nets()

List of all networks this channel is on

=cut

sub nets {
	values %Janus::nets;
}

=item $chan->has_nmode($mode, $nick)

Returns true if the nick has the given mode in the channel (n_* modes)

=cut

sub has_nmode {
	my($chan, $mode, $nick) = @_;
	$nmode[$$chan]{$nick->lid()}{$mode};
}

sub get_nmode {
	my($chan, $nick) = @_;
	$nmode[$$chan]{$nick->lid()};
}

sub get_mode {
	my($chan, $itm) = @_;
	$mode[$$chan]{$itm};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
# perl -e "print q[\$out .= ' ],\$_,q[='.\$ij->ijstr(\$],\$_,q[{\$\$chan});],qq(\n) for qw/ts topic topicts topicset mode/"
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' name='.$ij->ijstr($name[$$chan]);
	$out;
}

sub _init {
	my($c, $ifo) = @_;
	$topicts[$$c] = 0 unless $topicts[$$c];
	$mode[$$c] = $ifo->{mode} || {};
	$ts[$$c] = $ifo->{ts} || 0;
	$ts[$$c] = (time + 60) if $ts[$$c] < 1000000;
	$name[$$c] = $ifo->{name};
}

sub _destroy {
	my $c = $_[0];
	my $n = $name[$$c];
	print "   CHAN:$$c $n deallocated\n";
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		if ($txt =~ /^l/) {
			$mode[$$chan]{$txt} = [ @{$mode[$$src]{$txt}} ];
		} else {
			$mode[$$chan]{$txt} = $mode[$$src]{$txt};
		}
	}
}

sub mode_delta {
	my($chan, $dst) = @_;
	my %add = $dst ? %{$mode[$$dst]} : ();
	my(@modes, @args);
	for my $txt (keys %{$mode[$$chan]}) {
		if ($txt =~ /^l/) {
			my %torm = map { $_ => 1} @{$mode[$$chan]{$txt}};
			if (exists $add{$txt}) {
				for my $i (@{$add{$txt}}) {
					if (exists $torm{$i}) {
						delete $torm{$i};
					} else {
						push @modes, '+'.$txt;
						push @args, $i;
					}
				}
			}
			for my $i (keys %torm) {
				push @modes, '-'.$txt;
				push @args, $i;
			}
		} elsif ($txt =~ /^[vs]/) {
			if (exists $add{$txt}) {
				if ($mode[$$chan]{$txt} && $mode[$$chan]{$txt} eq $add{$txt}) {
					# hey, isn't that nice
				} else {
					push @modes, '+'.$txt;
					push @args, $add{$txt};
				}
			} else {
				push @modes, '-'.$txt;
				push @args, $mode[$$chan]{$txt} unless $txt =~ /^s/;
			}
		} else {
			push @modes, '-'.$txt unless exists $add{$txt};
		}
		delete $add{$txt};
	}
	for my $txt (keys %add) {
		if ($txt =~ /^l/) {
			for my $i (@{$add{$txt}}) {
				push @modes, '+'.$txt;
				push @args, $i;
			}
		} elsif ($txt =~ /^[vs]/) {
			push @modes, '+'.$txt;
			push @args, $add{$txt};
		} else {
			push @modes, '+'.$txt;
		}
	}
	(\@modes, \@args);
}

=item $chan->all_nicks()

return a list of all nicks on the channel

=cut

sub all_nicks {
	my $chan = $_[0];
	return values %{$nicks[$$chan]};
}

=item $chan->str($net)

get the channel's name on a given network, or undef if the channel is
not on the network

=cut

sub str {
	my($chan,$net) = @_;
	$name[$$chan];
}

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

sub is_on {
	1
}

sub sendto {
	my($chan,$act,$except) = @_;
	my %n = %Janus::nets;
	delete $n{$except->id()} if $except;
	values %n;
}

=item $chan->part($nick)

remove records of this nick (for quitting nicks)

=cut

sub part {
	my($chan,$nick) = @_;
	delete $nicks[$$chan]{$nick->lid()};
	delete $nmode[$$chan]{$nick->lid()};
	return if keys %{$nicks[$$chan]};
	# destroy channel
	&LocalNetwork::replace_chan(undef, $name[$$chan], undef);
}

&Janus::hook_add(
	JOIN => act => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$nicks[$$chan]{$nick->lid()} = $nick;
		if ($act->{mode}) {
			$nmode[$$chan]{$nick->lid()} = { %{$act->{mode}} };
		}
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, TIMESYNC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		my $ts = $act->{ts};
		if ($ts < 1000000) {
			#don't EVER destroy channel TSes with that annoying Unreal message
			warn "Not destroying channel timestamp; mode desync may happen!" if $ts;
			return;
		}
		$ts[$$chan] = $ts;
		if ($act->{wipe}) {
			$nmode[$$chan] = {};
			$mode[$$chan] = {};
		}
	}, MODE => act => sub {
		my $act = $_[0];
		local $_;
		my $chan = $act->{dst};
		my @args = @{$act->{args}};
		for my $itxt (@{$act->{mode}}) {
			my $pm = substr $itxt, 0, 1;
			my $t = substr $itxt, 1, 1;
			my $i = substr $itxt, 1;
			if ($t eq 'n') {
				my $nick = shift @args or next;
				$nmode[$$chan]{$nick->lid()}{$i} = 1 if $pm eq '+';
				delete $nmode[$$chan]{$nick->lid()}{$i} if $pm eq '-';
			} elsif ($t eq 'l') {
				if ($pm eq '+') {
					my $b = shift @args;
					@{$mode[$$chan]{$i}} = ($b, grep { $_ ne $b } @{$mode[$$chan]{$i}});
				} else {
					my $b = shift @args;
					@{$mode[$$chan]{$i}} = grep { $_ ne $b } @{$mode[$$chan]{$i}};
				}
			} elsif ($t eq 'v') {
				$mode[$$chan]{$i} = shift @args;
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 's') {
				$mode[$$chan]{$i} = shift @args if $pm eq '+';
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 'r') {
				$mode[$$chan]{$i} = 1;
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 't') {
				$i =~ s/t(\d)/t/ or warn "Invalid tristate mode string $i";
				$mode[$$chan]{$i} = $1;
				delete $mode[$$chan]{$i} if $pm eq '-';
			} else {
				warn "Unknown mode '$itxt'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		$topic[$$chan] = $act->{topic};
		$topicts[$$chan] = $act->{topicts} || time;
		$topicset[$$chan] = $act->{topicset};
		unless ($topicset[$$chan]) {
			if ($act->{src} && $act->{src}->isa('Nick')) {
				$topicset[$$chan] = $act->{src}->homenick();
			} else {
				$topicset[$$chan] = 'janus';
			}
		}
	}
);

=back

=cut

1;
