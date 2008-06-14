# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Channel;
use strict;
use warnings;
use Persist;
use Carp;
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

=item $chan->nets()

List of all networks this channel is on

=item $chan->str($net)

get the channel's name on a given network, or undef if the channel is
not on the network

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

our(@ts, @keyname, @topic, @topicts, @topicset, @mode);

our @nicks;  # all nicks on this channel
our @nmode;  # modes of those nicks

&Persist::register_vars(qw(ts keyname topic topicts topicset mode nicks nmode));
&Persist::autoget(qw(ts keyname topic topicts topicset), all_modes => \@mode);
&Persist::autoinit(qw(ts topic topicts topicset));

my %nmodebit = (
	voice => 1,
	halfop => 2,
	op => 4,
	admin => 8,
	owner => 16,
);

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
	my $n = $nmode[$$chan]{$$nick} || 0;
	$n & $m;
}

=item $chan->get_nmode($nick)

Gets a hashref whose keys are the nick modes on the channel.

=cut

sub get_nmode {
	my($chan, $nick) = @_;
	my %m;
	my $n = $nmode[$$chan]{$$nick} || 0;
	$n & $nmodebit{$_} and $m{$_}++ for keys %nmodebit;
	\%m;
}

sub get_mode {
	my($chan, $itm) = @_;
	$mode[$$chan]{$itm};
}

=item $chan->all_nicks()

return a list of all nicks on the channel

=cut

sub all_nicks {
	my $chan = $_[0];
	return @{$nicks[$$chan]};
}

=item $chan->part($nick)

remove records of this nick (for quitting nicks)

=cut

sub part {
	my($chan,$nick,$fast) = @_;
	$nicks[$$chan] = [ grep { $_ != $nick } @{$nicks[$$chan]} ];
	delete $nmode[$$chan]{$$nick};
	return if $fast || @{$nicks[$$chan]};
	$chan->unhook_destroyed();
	&Janus::append({ type => 'POISON', item => $chan, reason => 'Final part' });
}

&Janus::hook_add(
	JOIN => act => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		my $on;
		$nick == $_ and $on++ for @{$nicks[$$chan]};
		push @{$nicks[$$chan]}, $nick unless $on;
		if ($act->{mode}) {
			for (keys %{$act->{mode}}) {
				warn "Unknown mode $_" unless $nmodebit{$_};
				$nmode[$$chan]{$$nick} |= $nmodebit{$_};
			}
		}
	}, PART => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->part($nick, $act->{delink});
	}, KICK => cleanup => sub {
		my $act = $_[0];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$chan->part($nick, 0);
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
				$nmode[$$chan]{$$arg} |= $nmodebit{$i}; # will ensure is defined
				$nmode[$$chan]{$$arg} &= ~$nmodebit{$i} if $pm eq '-';
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

### MODE SPLIT ###
eval($Janus::lmode eq 'Bridge' ? '#line '.__LINE__.' "'.__FILE__.'"'.q[
### BRIDGE MODE ###
sub nets {
	values %Janus::nets;
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' name='.$ij->ijstr($keyname[$$chan]);
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
	$keyname[$$c] = $ifo->{name};
}

sub _destroy {
	my $c = $_[0];
	$keyname[$$c];
}

sub str {
	my($chan,$net) = @_;
	$keyname[$$chan];
}

sub is_on {
	1
}

sub sendto {
	values %Janus::nets;
}

sub unhook_destroyed {
	my $chan = shift;
	&LocalNetwork::replace_chan(undef, $keyname[$$chan], undef);
}

1 ] : '#line '.__LINE__.' "'.__FILE__.'"'.q[
### LINK MODE ###
our @homenet; # controlling network of this channel
our @names;   # channel's name on the various networks
our @nets;    # networks this channel is shared to

&Persist::register_vars(qw(homenet names nets));
&Persist::autoinit(qw(homenet));
&Persist::autoget(qw(homenet));

sub nets {
	values %{$nets[${$_[0]}]};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' homenet='.$ij->ijstr($homenet[$$chan]);
	my %nnames = map { $_->gid(), $names[$$chan]{$$_} } values %{$nets[$$chan]};
	$out .= ' names='.$ij->ijstr(\%nnames);
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
	if ($ifo->{net}) {
		my $net = $ifo->{net};
		my $kn = $net->gid().lc $ifo->{name};
		$keyname[$$c] = $kn;
		$homenet[$$c] = $net;
		$nets[$$c]{$$net} = $net;
		$names[$$c]{$$net} = $ifo->{name};
	} else {
		my $names = $ifo->{names} || {};
		$names[$$c] = {};
		$nets[$$c] = {};
		for my $id (keys %$names) {
			my $name = $names->{$id};
			my $net = $Janus::gnets{$id} or warn next;
			$names[$$c]{$$net} = $name;
			$nets[$$c]{$$net} = $net;
			my $kn = $net->gid().lc $name;
			$keyname[$$c] = $kn if $net == $homenet[$$c];
		}
		&Debug::err("Constructing unkeyed channel!") unless $keyname[$$c];
	}
	join ',', sort map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
}

sub _destroy {
	my $c = $_[0];
	join ',', sort map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		my $m = $mode[$$src]{$txt};
		$m = [ @$m ] if ref $m;
		$mode[$$chan]{$txt} = $m;
	}
}

sub add_net {
	my($chan, $src) = @_;
	my $net = $homenet[$$src];
	my $sname = $src->str($net);

	for my $nick (@{$nicks[$$chan]}) {
		next if $$nick == 1 || $nick->jlink();
		&Janus::append(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $chan->get_nmode($nick),
			sendto => $net,
		});
	}

	my $joinnets = [ values %{$nets[$$chan]} ];

	$nets[$$chan]{$$net} = $net;
	$names[$$chan]{$$net} = $sname;

	$Janus::gchans{$net->gid().lc $sname} = $chan;

	return if $net->jlink();

	&Debug::info("Link $keyname[$$src] into $keyname[$$chan] ($$src -> $$chan)");

	my $tsctl = ($ts[$$src] <=> $ts[$$chan]);

	if ($tsctl > 0) {
		$net->send({
			type => 'TIMESYNC',
			dst => $src,
			wipe => 1,
			ts => $ts[$$chan],
			oldts => $ts[$$src],
		});
	}

	$net->replace_chan($sname, $chan);

	if ($tsctl < 0) {
		&Debug::info("Resetting timestamp from $ts[$$chan] to $ts[$$src]");
		&Janus::insert_full(+{
			type => 'TIMESYNC',
			dst => $chan,
			wipe => 0,
			ts => $ts[$$src],
			oldts => $ts[$$chan],
		});
	}

	&Janus::insert_full(+{
		type => 'JOIN',
		src => $Interface::janus,
		dst => $chan,
		nojlink => 1,
	});

	my ($mode, $marg, $dirs) = &Modes::delta($tsctl <= 0 ? $src : undef, $chan);
	$net->send({
		type => 'MODE',
		dst => $chan,
		mode => $mode,
		args => $marg,
		dirs => $dirs,
	}) if @$mode;

	$net->send(+{
		type => 'TOPIC',
		dst => $chan,
		topic => $topic[$$chan],
		topicts => $topicts[$$chan],
		topicset => $topicset[$$chan],
		in_link => 1,
		nojlink => 1,
	}) if $topic[$$chan] && (!$topic[$$src] || $topic[$$chan] ne $topic[$$src]);


	for my $nick (@{$nicks[$$src]}) {
		next if $$nick == 1;

		&Janus::append(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $src->get_nmode($nick),
			sendto => $joinnets,
		});
	}
}

sub str {
	my($chan,$net) = @_;
	$net ? $names[$$chan]{$$net} : undef;
}

sub is_on {
	my($chan, $net) = @_;
	exists $nets[$$chan]{$$net};
}

sub sendto {
	my($chan,$act) = @_;
	values %{$nets[$$chan]};
}

sub unhook_destroyed {
	my $chan = shift;
	# destroy channel
	for my $id (keys %{$nets[$$chan]}) {
		my $net = $nets[$$chan]{$id};
		my $name = $names[$$chan]{$id};
		delete $Janus::gchans{$net->gid().lc $name};
		next if $net->jlink();
		$net->replace_chan($name, undef);
	}
}

sub del_remoteonly {
	my $chan = shift;
	if (@{$nicks[$$chan]}) {
		my @nets = values %{$nets[$$chan]};
		my $cij = undef;
		for my $net (@nets) {
			my $ij = $net->jlink();
			return unless $ij;
			$ij = $ij->parent() while $ij->parent();
			return if $cij && $cij ne $ij;
			$cij = $ij;
		}
		# all networks are on the same ij network. We can't see you anymore
		for my $nick (@{$nicks[$$chan]}) {
			&Janus::append({
				type => 'PART',
				src => $nick,
				dst => $chan,
				msg => 'Delink of invisible channel',
				delink => 1,
				nojlink => 1,
			});
		}
	}
	$chan->unhook_destroyed();
	&Janus::append({ type => 'POISON', item => $chan, reason => 'delink gone' });
}

&Janus::hook_add(
	CHANLINK => check => sub {
		my $act = shift;
		my $schan = $act->{in};
		unless ($schan) {
			my $net = $act->{net};
			my $name = $act->{name};
			$schan = $net->chan($name, 1);
		}
		return 1 if 1 < scalar $schan->nets();

		$act->{in} = $schan;
		undef;
	}, CHANLINK => act => sub {
		my $act = shift;
		my $dchan = $act->{dst};
		my $schan = $act->{in};

		$dchan->add_net($schan);

		$Janus::gchans{$dchan->keyname()} = $dchan;
	}, DELINK => check => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		if ($net == $homenet[$$chan]) {
			for my $on (values %{$nets[$$chan]}) {
				next if $on == $net;
				&Janus::append(+{
					type => 'DELINK',
					net => $on,
					dst => $chan,
					nojlink => 1,
				});
			}
		}
		unless (exists $nets[$$chan]{$$net}) {
			&Debug::warn("Cannot delink: channel $$chan is not on network #$$net");
			return 1;
		}
		undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		return if $net == $homenet[$$chan];
		$act->{sendto} = [ values %{$nets[$$chan]} ]; # before the splitting
		delete $nets[$$chan]{$$net} or warn;

		my $name = delete $names[$$chan]{$$net};

		my $split = Channel->new(
			net => $net,
			name => $name,
			ts => $ts[$$chan],
		);
		$topic[$$split] = $topic[$$chan];
		$topicts[$$split] = $topicts[$$chan];
		$topicset[$$split] = $topicset[$$chan];

		$act->{split} = $split;
		$split->_modecpy($chan);
		$net->replace_chan($name, $split) unless $net->jlink();

		my @presplit = @{$nicks[$$chan]};
		$nicks[$$split] = [ @presplit ];
		$nmode[$$split] = { %{$nmode[$$chan]} };

		my $delink_lvl = $act->{netsplit_quit} ? 2 : 1;

		my @parts;

		for my $nick (@presplit) {
			# we need to insert the nick into the split off channel before the delink
			# PART is sent, because code is allowed to assume a PARTed nick was actually
			# in the channel it is parting from; this also keeps the channel from being
			# prematurely removed from the list.

			warn "c$$chan/n$$nick:no HN", next unless $nick->homenet();
			if ($nick->homenet() eq $net) {
				$nick->rejoin($split);
				push @parts, {
					type => 'PART',
					src => $nick,
					dst => $chan,
					msg => 'Channel delinked',
					delink => $delink_lvl,
					($act->{netsplit_quit} ? (sendto => []) : (nojlink => 1)),
				};
			} else {
				push @parts, +{
					type => 'PART',
					src => $nick,
					dst => $split,
					msg => 'Channel delinked',
					delink => $delink_lvl,
					($act->{netsplit_quit} ? (sendto => []) : (nojlink => 1)),
				};
			}
		}
		&Janus::insert_full(@parts);
	}, DELINK => cleanup => sub {
		my $act = shift;
		del_remoteonly($act->{dst});
		del_remoteonly($act->{split}) if $act->{split};
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my @clean;
		for my $chan ($net->all_chans()) {
			warn "Channel not on network!" unless $chan->is_on($net);
			push @clean, +{
				type => 'DELINK',
				dst => $chan,
				net => $net,
				netsplit_quit => 1,
				except => $net,
				reason => 'netsplit',
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean);
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		&Persist::poison($_) for $net->all_chans();
	},
);

1 ]) or die $@;

=back

=cut

1;
