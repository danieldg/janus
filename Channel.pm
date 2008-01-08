# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Channel;
use strict;
use warnings;
use Persist;
use Nick;
use Modes;

our($VERSION) = '$Rev$' =~ /(\d+)/;

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

my @ts       :Persist(ts)                      :Get(ts);
my @name     :Persist(keyname)                 :Get(keyname);
my @topic    :Persist(topic)    :Arg(topic)    :Get(topic);
my @topicts  :Persist(topicts)  :Arg(topicts)  :Get(topicts);
my @topicset :Persist(topicset) :Arg(topicset) :Get(topicset);
my @mode     :Persist(mode)                    :Get(all_modes);
my @nicks    :Persist(nicks); # all nicks on this channel
my @nmode    :Persist(nmode); # modes of those nicks

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
	print "   CHAN:$$c $ifo->{name} allocated\n";
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
	delete $n{$$except} if $except;
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
		my @dirs = @{$act->{dirs}};
		my @args = @{$act->{args}};
		for my $i (@{$act->{mode}}) {
			my $pm = shift @dirs;
			my $arg = shift @args;
			my $t = substr $i, 0, 1;
			if ($t eq 'n') {
				unless (ref $arg && $arg->isa('Nick')) {
					warn "$i without nick arg!";
					next;
				}
				$nmode[$$chan]{$arg->lid()}{$i} = 1 if $pm eq '+';
				delete $nmode[$$chan]{$arg->lid()}{$i} if $pm eq '-';
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
