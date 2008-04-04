# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Channel;
use strict;
use warnings;
use Persist;
use Carp;
use Nick;
use Modes;

=head1 Channel

Object representing a set of linked channels

=over

=item Channel->new(arghash)

Create a new channel. Should only be called by LocalNetwork and InterJanus.

=over

=item ts, mode, topic, topicts, topicset - same as getters

=item keyname - if set, is assumed to be a merging channel

=item names - hashref of netname => channame. Only used if keyname set

=item net - network this channel is on. Only used if keyname unset

=back

=item $chan->ts()

Timestamp for this channel

=item $chan->keyname()

Name used for this channel in interjanus communication

=item $chan->topic()

Topic text for the channel

=item $chan->topicts()

Topic set timestamp

=item $chan->topicset()

String representing the setter of the topic

=item $chan->all_modes()

Hash of modetext => modeval (see Modes.pm)

=cut

our(@ts, @name, @topic, @topicts, @topicset, @mode, @nicks, @nmode);

&Persist::register_vars(qw(ts name topic topicts topicset mode nicks nmode));
&Persist::autoget(qw(ts topic topicts topicset), keyname => \@name, all_modes => \@mode);
&Persist::autoinit(qw(ts topic topicts topicset));

my %nmodebit = (
	voice => 1,
	halfop => 2,
	op => 4,
	admin => 8,
	owner => 16,
);

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
	$mode =~ s/^n_// and carp "Stripping deprecated n_ prefix";
	my $m = $nmodebit{$mode} or do {
		carp "Unknown nick mode $mode";
		return 0;
	};
	my $n = $nmode[$$chan]{$nick->lid()} || 0;
	$n & $m;
}

=item $chan->get_nmode($nick)

Gets a hashref whose keys are the nick modes on the channel.

=cut

sub get_nmode {
	my($chan, $nick) = @_;
	my %m;
	my $n = $nmode[$$chan]{$nick->lid()} || 0;
	$n & $nmodebit{$_} and $m{$_}++ for keys %nmodebit;
	\%m;
}

sub get_mode {
	my($chan, $itm) = @_;
	$mode[$$chan]{$itm};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
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
	{	no warnings 'uninitialized';
		$mode[$$c] = $ifo->{mode} || {};
		$nicks[$$c] = [];
		$nmode[$$c] = {};
		$topicts[$$c] += 0;
		$ts[$$c] += 0;
		$ts[$$c] = ($Janus::time + 60) if $ts[$$c] < 1000000;
	}
	$name[$$c] = $ifo->{name};
}

sub _destroy {
	my $c = $_[0];
	$name[$$c];
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		my $m = $mode[$$src]{$txt};
		$m = [ @$m ] if ref $m;
		$mode[$$chan]{$txt} = $m;
	}
}

=item $chan->all_nicks()

return a list of all nicks on the channel

=cut

sub all_nicks {
	my $chan = $_[0];
	return @{$nicks[$$chan]};
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
	values %Janus::nets;
}

=item $chan->part($nick)

remove records of this nick (for quitting nicks)

=cut

sub part {
	my($chan,$nick) = @_;
	$nicks[$$chan] = [ grep { $_ != $nick } @{$nicks[$$chan]} ];
	delete $nmode[$$chan]{$$nick};
	return if @{$nicks[$$chan]};
	$chan->unhook_destroyed();
}

sub unhook_destroyed {
	my $chan = shift;
	# destroy channel
	&LocalNetwork::replace_chan(undef, $name[$$chan], undef);
}

&Janus::hook_add(
	JOIN => act => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		push @{$nicks[$$chan]}, $nick;
		if ($act->{mode}) {
			for (keys %{$act->{mode}}) {
				warn "Unknown mode $_" unless $nmodebit{$_};
				$nmode[$$chan]{$nick->lid()} |= $nmodebit{$_};
			}
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
		my @dirs = @{$act->{dirs}};
		my @args = @{$act->{args}};
		for my $i (@{$act->{mode}}) {
			my $pm = shift @dirs;
			my $arg = shift @args;
			my $t = $Modes::mtype{$i} || '?';
			if ($t eq 'n') {
				unless (ref $arg && $arg->isa('Nick')) {
					warn "$i without nick arg!";
					next;
				}
				$nmode[$$chan]{$arg->lid()} |= $nmodebit{$i}; # will ensure is defined
				$nmode[$$chan]{$arg->lid()} &= ~$nmodebit{$i} if $pm eq '-';
			} elsif ($t eq 'l') {
				if ($pm eq '+') {
					@{$mode[$$chan]{$i}} = ($arg, grep { $_ ne $arg } @{$mode[$$chan]{$i}});
				} else {
					@{$mode[$$chan]{$i}} = grep { $_ ne $arg } @{$mode[$$chan]{$i}};
				}
			} elsif ($t eq 'v') {
				$mode[$$chan]{$i} = $arg if $pm eq '+';
				delete $mode[$$chan]{$i} if $pm eq '-';
			} elsif ($t eq 'r') {
				my $v = 0+($mode[$$chan]{$i} || 0);
				$v |= $arg;
				$v &= ~$arg if $pm eq '-';
				$v ? $mode[$$chan]{$i} = $v : delete $mode[$$chan]{$i};
			} else {
				warn "Unknown mode '$i'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		$topic[$$chan] = $act->{topic};
		$topicts[$$chan] = $act->{topicts} || $Janus::time;
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
