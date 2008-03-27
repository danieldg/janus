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

my @ts       :Persist(ts)       :Arg(ts)       :Get(ts);
my @keyname  :Persist(keyname)                 :Get(keyname);
my @topic    :Persist(topic)    :Arg(topic)    :Get(topic);
my @topicts  :Persist(topicts)  :Arg(topicts)  :Get(topicts);
my @topicset :Persist(topicset) :Arg(topicset) :Get(topicset);
my @mode     :Persist(mode)                    :Get(all_modes);

my @names    :Persist(names);  # channel's name on the various networks
my @nets     :Persist(nets);   # networks this channel is shared to

my @locker   :Persist(locker); # Lock ID of the currently held lock, or undef
my @lockts   :Persist(lockts); # Time the lock will expire

my @nicks    :Persist(nicks);  # all nicks on this channel
my @nmode    :Persist(nmode);  # modes of those nicks

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
	values %{$nets[${$_[0]}]};
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
	my %nnames = map { $_->gid(), $names[$$chan]{$$_} } values %{$nets[$$chan]};
	$out .= ' names='.$ij->ijstr(\%nnames);
	$out;
}

sub _init {
	my($c, $ifo) = @_;
	{	no warnings 'uninitialized';
		$mode[$$c] = $ifo->{mode} || {};
		$topicts[$$c] += 0;
		$ts[$$c] += 0;
		$ts[$$c] = ($Janus::time + 60) if $ts[$$c] < 1000000;
	}
	if ($ifo->{net}) {
		my $net = $ifo->{net};
		$keyname[$$c] = $net->gid().$ifo->{name};
		$nets[$$c]{$$net} = $net;
		$names[$$c]{$$net} = $ifo->{name};
		$Janus::gchans{$net->gid().$ifo->{name}} = $c;
	} elsif ($ifo->{merge}) {
		$keyname[$$c] = $ifo->{merge};
		$names[$$c] = {};
		$nets[$$c] = {};
	} else {
		my $names = $ifo->{names} || {};
		$names[$$c] = {};
		$nets[$$c] = {};
		for my $id (keys %$names) {
			my $name = $names->{$id};
			my $net = $Janus::gnets{$id} or warn next;
			$names[$$c]{$$net} = $name;
			$nets[$$c]{$$net} = $net;
			my $kn = $net->gid().$name;
			$Janus::gchans{$kn} = $c unless $Janus::gchans{$kn};
			$keyname[$$c] = $kn; # it just has to be one of them
		}
		&Debug::err("Constructing unkeyed channel!") unless $keyname[$$c];
	}
	my $n = join ',', map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
	&Debug::alloc($c, 1, $n);
}

sub _destroy {
	my $c = $_[0];
	my $n = join ',', map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
	&Debug::alloc($c, 0, $n);
}

sub _mergenet {
	my($chan, $src) = @_;
	for my $id (keys %{$nets[$$src]}) {
		$nets[$$chan]{$id}  = $nets[$$src]{$id};
		$names[$$chan]{$id} = $names[$$src]{$id};
	}
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$mode[$$src]}) {
		my $m = $mode[$$src]{$txt};
		$m = [ @$m ] if ref $m;
		$mode[$$chan]{$txt} = $m;
	}
}

sub _link_into {
	my($src,$chan) = @_;
	my %dstnets = %{$nets[$$chan]};
	my $dbg = "Link into ($$src -> $$chan):";
	for my $id (keys %{$nets[$$src]}) {
		$dbg .= " $id";
		my $net = $nets[$$src]{$id};
		my $name = $names[$$src]{$id};
		$Janus::gchans{$net->gid().$name} = $chan;
		delete $dstnets{$id};
		next if $net->jlink();
		$dbg .= '+';
		$net->replace_chan($name, $chan);
	}
	&Debug::info($dbg);

	my $modenets = [ values %{$nets[$$src]} ];
	my $joinnets = [ values %dstnets ];

	my ($mode, $marg, $dirs) = &Modes::delta($src, $chan);
	&Janus::append(+{
		type => 'MODE',
		dst => $chan,
		mode => $mode,
		args => $marg,
		dirs => $dirs,
		sendto => $modenets,
		nojlink => 1,
	}) if @$mode;

	if (($topic[$$src] || '') ne ($topic[$$chan] || '')) {
		&Janus::append(+{
			type => 'TOPIC',
			dst => $chan,
			topic => $topic[$$chan],
			topicts => $topicts[$$chan],
			topicset => $topicset[$$chan],
			sendto => $modenets,
			in_link => 1,
			nojlink => 1,
		});
	}

	for my $nick (@{$nicks[$$src]}) {
		unless ($nick->homenet()) {
			&Debug::err("nick $$nick in channel $$src but should be gone");
			next;
		}
		next if $$nick == 1;

		unless ($nick->jlink()) {
			&Janus::append(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				mode => $src->get_nmode($nick),
				sendto => $joinnets,
			});
		}
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
	$net ? $names[$$chan]{$$net} : undef;
}

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

sub is_on {
	my($chan, $net) = @_;
	exists $nets[$$chan]{$$net};
}

sub sendto {
	my($chan,$act) = @_;
	carp "except in sendto is deprecated" if @_ > 2;
	values %{$nets[$$chan]};
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
	for my $id (keys %{$nets[$$chan]}) {
		my $net = $nets[$$chan]{$id};
		my $name = $names[$$chan]{$id};
		delete $Janus::gchans{$net->gid().$name};
		next if $net->jlink();
		$net->replace_chan($name, undef);
	}
}

sub del_remoteonly {
	my $chan = shift;
	my @nets = values %{$nets[$$chan]};
	my $cij = undef;
	for my $net (@nets) {
		my $ij = $net->jlink();
		return unless $ij;
		$ij = $ij->parent() while $ij->parent();
		return if $cij && $cij ne $ij;
		$cij = $ij;
	}
	# all networks are on the same ij network. Wipe out the channel.
	for my $nick (@{$nicks[$$chan]}) {
		&Janus::append({
			type => 'PART',
			src => $nick,
			dst => $chan,
			msg => 'Delink of invisible channel',
			nojlink => 1,
		});
	}
}

sub can_lock {
	my $chan = shift;
	return 1 unless $locker[$$chan];
	if ($lockts[$$chan] < $Janus::time) {
		&Debug::info("Stealing expired lock from $locker[$$chan]");
		return 1;
	} else {
		&Debug::info("Lock on #$$chan held by $locker[$$chan] until $lockts[$$chan]");
		return 0;
	}
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
	}, LOCKREQ => check => sub {
		my $act = shift;
		my $net = $act->{dst};
		if ($net->isa('LocalNetwork')) {
			my $chan = $net->chan($act->{name}, 1) or return 1;
			$act->{dst} = $chan;
		} elsif ($net->isa('Network')) {
			my $kn = $net->gid().$act->{name};
			my $chan = $Janus::gchans{$kn};
			$act->{dst} = $chan if $chan;
		}
		return undef;
	}, LOCKREQ => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		return unless $chan->isa('Channel');

		if ($chan->can_lock()) {
			$locker[$$chan] = $act->{lockid};
			$lockts[$$chan] = $Janus::time + 60;
			&Janus::append(+{
				type => 'LOCKACK',
				src => $RemoteJanus::self,
				dst => $act->{src},
				lockid => $act->{lockid},
				chan => $chan,
				expire => ($Janus::time + 40),
			});
		} else {
			&Janus::append(+{
				type => 'LOCKACK',
				src => $RemoteJanus::self,
				dst => $act->{src},
				lockid => $act->{lockid},
			});
		}
	}, UNLOCK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		delete $locker[$$chan];
	}, LOCKED => act => sub {
		my $act = shift;
		my $chan1 = $act->{chan1};
		my $chan2 = $act->{chan2};

		for my $id (keys %{$nets[$$chan1]}) {
			my $exist = $nets[$$chan2]{$id};
			next unless $exist;
			&Debug::info("Cannot link: this channel would be in $id twice");
			&Janus::jmsg($act->{src}, "Cannot link: this channel would be in $id twice");
			return;
		}
	
		my $tsctl = ($ts[$$chan2] <=> $ts[$$chan1]);
		# topic timestamps are backwards: later topic change is taken IF the creation stamps are the same
		# otherwise go along with the channel sync

		# basic strategy: Modify the two channels in-place to have the same modes as we create
		# the unified channel

		if ($tsctl > 0) {
			&Debug::info("Channel 1 wins TS");
			&Janus::append(+{
				type => 'TIMESYNC',
				dst => $chan2,
				ts => $ts[$$chan1],
				oldts => $ts[$$chan2],
				wipe => 1,
			});
		} elsif ($tsctl < 0) {
			&Debug::info("Channel 2 wins TS");
			&Janus::append(+{
				type => 'TIMESYNC',
				dst => $chan1,
				ts => $ts[$$chan2],
				oldts => $ts[$$chan1],
				wipe => 1,
			});
		} else {
			&Debug::info("No TS conflict");
		}

		my $chan = Channel->new(merge => $keyname[$$chan1]);

		my $topctl = ($tsctl > 0 || ($tsctl == 0 && $topicts[$$chan1] >= $topicts[$$chan2]))
			? $$chan1 : $$chan2;
		$topic[$$chan] = $topic[$topctl];
		$topicts[$$chan] = $topicts[$topctl];
		$topicset[$$chan] = $topicset[$topctl];

		if ($tsctl > 0) {
			$ts[$$chan] = $ts[$$chan1];
			$chan->_modecpy($chan1);
		} elsif ($tsctl < 0) {
			$ts[$$chan] = $ts[$$chan2];
			$chan->_modecpy($chan2);
		} else {
			# Equal timestamps; recovering from a split. Merge any information
			$ts[$$chan] = $ts[$$chan1];
			&Modes::merge($chan, $chan1, $chan2);
		}

		# copy in nets and names of the channel
		$chan->_mergenet($chan1);
		$chan->_mergenet($chan2);

		&Janus::append(+{
			type => 'LINK',
			src => $act->{src},
			dst => $chan,
			linkfile => $act->{linkfile},
		});
	}, LINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};

		my %from;
		for my $nid (keys %{$nets[$$chan]}) {
			my $net = $nets[$$chan]{$nid} or next;
			my $kn = $net->gid().$names[$$chan]{$nid};
			my $src = $Janus::gchans{$kn} or next;
			$from{$$src} = $src;
		}
		
		&Janus::append(+{
			type => 'JOIN',
			src => $Interface::janus,
			dst => $chan,
			nojlink => 1,
		});
		for my $src (values %from) {
			next if $src eq $chan;
			$src->_link_into($chan);
			delete $locker[$$src];
		}
		delete $locker[$$chan];
	}, DELINK => check => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		my %nets = %{$nets[$$chan]};
		&Debug::info("Delink channel $$chan which is currently on: ", join ' ', keys %nets);
		if (scalar keys %nets <= 1) {
			&Debug::warn("Cannot delink: channel $$chan is not shared");
			return 1;
		}
		unless (exists $nets{$$net}) {
			&Debug::warn("Cannot delink: channel $$chan is not on network #$$net");
			return 1;
		}
		unless ($chan->can_lock()) {
			return undef if $act->{netsplit_quit};
			&Debug::warn("Cannot delink: channel $$chan is locked by $locker[$$chan]");
			return 1;
		}
		undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		$act->{sendto} = [ values %{$nets[$$chan]} ]; # before the splitting
		delete $nets[$$chan]{$$net} or warn;

		my $name = delete $names[$$chan]{$$net};
		if ($keyname[$$chan] eq $net->gid().$name) {
			my @onets = grep defined, values %{$nets[$$chan]};
			if (@onets && $onets[0]) {
				$keyname[$$chan] = $onets[0]->gid().$names[$$chan]{$onets[0]->lid()};
			} else {
				&Debug::err("no new keyname in DELINK of $$chan");
			}
		}
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

		for my $nick (@presplit) {
			# we need to insert the nick into the split off channel before the delink
			# PART is sent, because code is allowed to assume a PARTed nick was actually
			# in the channel it is parting from; this also keeps the channel from being
			# prematurely removed from the list.

			warn "c$$chan/n$$nick:no HN", next unless $nick->homenet();
			if ($nick->homenet() eq $net) {
				$nick->rejoin($split);
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $chan,
					msg => 'Channel delinked',
					nojlink => 1,
				});
			} else {
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $split,
					msg => 'Channel delinked',
					nojlink => 1,
				});
			}
		}
	}, DELINK => cleanup => sub {
		my $act = shift;
		del_remoteonly($act->{dst});
		del_remoteonly($act->{split});
	}
);

=back

=cut

1;
