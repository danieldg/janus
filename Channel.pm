# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Channel;
use Object::InsideOut;
use Persist;
use strict;
use warnings;
&Janus::load('Nick');

our($VERSION) = '$Rev$' =~ /(\d+)/;

=head1 Channel

Object representing a set of linked channels

=over

=cut

__PERSIST__
persist @ts       :Field :Get(ts);
persist @keyname  :Field :Arg(keyname) :Get(keyname);
persist @topic    :Field :Arg(topic);
persist @topicts  :Field :Arg(topicts);
persist @topicset :Field :Arg(topicset);
persist @mode     :Field;

persist @names    :Field;
persist @nets     :Field;

persist @nicks    :Field;
persist @nmode    :Field;

__CODE__

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
	$nmode[$$chan]{$nick->lid()}{$mode};
}

sub to_ij {
	my($chan,$ij) = @_;
	my $out = '';
# perl -e "print q[\$out .= ' ],\$_,q[='.\$ij->ijstr(\$],\$_,q[{\$\$chan});],qq(\n) for qw/keyname ts topic topicts topicset mode names/"
	$out .= ' keyname='.$ij->ijstr($keyname[$$chan]);
	$out .= ' ts='.$ij->ijstr($ts[$$chan]);
	$out .= ' topic='.$ij->ijstr($topic[$$chan]);
	$out .= ' topicts='.$ij->ijstr($topicts[$$chan]);
	$out .= ' topicset='.$ij->ijstr($topicset[$$chan]);
	$out .= ' mode='.$ij->ijstr($mode[$$chan]);
	$out .= ' names='.$ij->ijstr($names[$$chan]);
	$out;
}

my %initargs :InitArgs = (
	names => '',
	net => '',
	name => '',
	ts => '',
	mode => '',
);

sub _init :Init {
	my($c, $ifo) = @_;
	$topicts[$$c] = 0 unless $topicts[$$c];
	$mode[$$c] = $ifo->{mode} || {};
	$ts[$$c] = $ifo->{ts} || 0;
	$ts[$$c] = (time + 60) if $ts[$$c] < 1000000;
	if ($keyname[$$c]) {
		my $names = $ifo->{names} || {};
		$names[$$c] = $names;
		for my $id (keys %$names) {
			my $name = $names->{$id};
			$nets[$$c]{$id} = $Janus::nets{$id};
			$Janus::gchans{$id.$name} = $c unless $Janus::gchans{$id.$name};
		}
	} else {
		my $net = $ifo->{net};
		my $id = $net->id();
		$keyname[$$c] = $id.$ifo->{name};
		$nets[$$c]{$id} = $net;
		$names[$$c]{$id} = $ifo->{name};
		$Janus::gchans{$id.$ifo->{name}} = $c;
	}
}

sub _destroy :Destroy {
	my $c = $_[0];
	my $n = join ',', map { $_.$names[$$c]{$_} } keys %{$names[$$c]};
	print "   CHAN: $n deallocated\n";
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
				if ($mode[$$chan]{$txt} eq $add{$txt}) {
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

sub _link_into {
	my($src,$chan) = @_;
	my %dstnets = %{$nets[$$chan]};
	print "Link into:";
	for my $id (keys %{$nets[$$src]}) {
		print " $id";
		my $net = $nets[$$src]{$id};
		my $name = $names[$$src]{$id};
		$Janus::gchans{$id.$name} = $chan;
		delete $dstnets{$id};
		next if $net->jlink();
		print '+';
		$net->replace_chan($name, $chan);
	}
	print "\n";
	my $sendnets = [ values %dstnets ];

	my ($mode, $marg) = $src->mode_delta($chan);
	&Janus::append(+{
		type => 'MODE',
		dst => $chan,
		mode => $mode,
		args => $marg,
		sendto => $sendnets,
		nojlink => 1,
	}) if @$mode;

	if (($topic[$$src] || '') ne ($topic[$$chan] || '')) {
		&Janus::append(+{
			type => 'TOPIC',
			dst => $chan,
			topic => $topic[$$chan],
			topicts => $topicts[$$chan],
			topicset => $topicset[$$chan],
			sendto => $sendnets,
			nojlink => 1,
		});
	}

	for my $nid (keys %{$nicks[$$src]}) {
		my $nick = $nicks[$$src]{$nid};
		$nicks[$$chan]{$nid} = $nick;

		my $mode = $nmode[$$src]{$nid};
		$nmode[$$chan]{$nid} = $mode;

		$nick->rejoin($chan);
		&Janus::append(+{
			type => 'JOIN',
			src => $nick,
			dst => $chan,
			mode => $nmode[$$src]{$nid},
			rejoin => 1,
			sendto => $sendnets,
		}) unless $nick->jlink();
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
	$names[$$chan]{$net->id()};
}

=item $chan->is_on($net)

returns true if the channel is linked onto the given network

=cut

sub is_on {
	my($chan, $net) = @_;
	exists $nets[$$chan]{$net->id()};
}

sub sendto {
	my($chan,$act,$except) = @_;
	my %n = %{$nets[$$chan]};
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
	for my $id (keys %{$nets[$$chan]}) {
		my $net = $nets[$$chan]{$id};
		my $name = $names[$$chan]{$id};
		delete $Janus::gchans{$id.$name};
		next if $net->jlink();
		$net->replace_chan($name, undef);
	}
}

&Janus::hook_add(
 	JOIN => validate => sub {
		my $act = $_[0];
		my $valid = eval {
			return 0 unless $act->{src}->isa('Nick');
			return 0 unless $act->{dst}->isa('Channel');
			1;
		};
		$valid ? undef : 1;
	}, JOIN => act => sub {
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
					push @{$mode[$$chan]{$i}}, shift @args;
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
			} else {
				warn "Unknown mode '$itxt'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[0];
		my $chan = $act->{dst};
		$topic[$$chan] = $act->{topic};
		$topicts[$$chan] = $act->{topicts} || time;
		$topicset[$$chan] = $act->{topicset} || $act->{src}->homenick();
	}, LSYNC => validate => sub {
		my $act = shift;
		eval {
			return 0 unless $act->{dst}->isa('Network');
			return 0 unless $act->{chan}->isa('Channel');
			1;
		} ? undef : 1;
	}, LSYNC => act => sub {
		my $act = shift;
		return if $act->{dst}->jlink();
		my $chan1 = $act->{dst}->chan($act->{linkto},1);
		my $chan2 = $act->{chan};
	
		# This is the atomic creation of the merged channel. Everyone else
		# just gets a copy of the channel created here and send out the 
		# events required to merge into it.

		for my $id (keys %{$nets[$$chan1]}) {
			if (exists $nets[$$chan2]{$id}) {
				&Janus::jmsg($act->{src}, "Cannot link: this channel would be in $id twice");
				return;
			}
		}
	
		my $tsctl = ($ts[$$chan2] <=> $ts[$$chan1]);
		# topic timestamps are backwards: later topic change is taken IF the creation stamps are the same
		# otherwise go along with the channel sync

		# basic strategy: Modify the two channels in-place to have the same modes as we create
		# the unified channel

		if ($tsctl > 0) {
			print "Channel 1 wins TS\n";
			&Janus::append(+{
				type => 'TIMESYNC',
				dst => $chan2,
				ts => $ts[$$chan1],
				oldts => $ts[$$chan2],
				wipe => 1,
			});
		} elsif ($tsctl < 0) {
			print "Channel 2 wins TS\n";
			&Janus::append(+{
				type => 'TIMESYNC',
				dst => $chan1,
				ts => $ts[$$chan2],
				oldts => $ts[$$chan1],
				wipe => 1,
			});
		}

		my $chan = Channel->new(keyname => $keyname[$$chan1], names => {});

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
			my @allmodes = keys(%{$mode[$$chan1]}), keys(%{$mode[$$chan2]});
			for my $txt (@allmodes) {
				if ($txt =~ /^l/) {
					my %m;
					if (exists $mode[$$chan1]{$txt}) {
						$m{$_} = 1 for @{$mode[$$chan1]{$txt}};
					}
					if (exists $mode[$$chan2]{$txt}) {
						$m{$_} = 1 for @{$mode[$$chan2]{$txt}};
					}
					$mode[$$chan]{$txt} = [ keys %m ];
				} else {
					if (exists $mode[$$chan1]) {
						$mode[$$chan]{$txt} = $mode[$$chan1]{$txt};
					} else {
						$mode[$$chan]{$txt} = $mode[$$chan2]{$txt};
					}
				}
			}
		}

		# copy in nets and names of the channel
		$chan->_mergenet($chan1);
		$chan->_mergenet($chan2);

		&Janus::append(+{
			type => 'LINK',
			src => $act->{src},
			dst => $chan,
			chan1 => $chan1,
			chan2 => $chan2,
		});
	}, LINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my($chan1,$chan2) = ($act->{chan1}, $act->{chan2});
		
		$chan1->_link_into($chan) if $chan1;
		$chan2->_link_into($chan) if $chan2;
	}, DELINK => check => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		return 1 unless ref $net && $net->isa('Network');
		return 1 unless ref $chan && $chan->isa('Channel');
		return 1 unless exists $nets[$$chan]{$net->id()};
		my @nets = keys %{$nets[$$chan]};
		return 1 if @nets == 1;
		undef;
	}, DELINK => act => sub {
		my $act = shift;
		my $chan = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		$act->{sendto} = [ values %{$nets[$$chan]} ]; # before the splitting
		delete $nets[$$chan]{$id} or warn;

		my $name = delete $names[$$chan]{$id};
		if ($keyname[$$chan] eq $id.$name) {
			my @onets = sort keys %{$names[$$chan]};
			$keyname[$$chan] = $onets[0].$names[$$chan]{$onets[0]};
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

		for my $nid (keys %{$nicks[$$chan]}) {
			if ($nicks[$$chan]{$nid}->homenet()->id() eq $id) {
				my $nick = $nicks[$$split]{$nid} = $nicks[$$chan]{$nid};
				$nmode[$$split]{$nid} = $nmode[$$chan]{$nid};
				$nick->rejoin($split);
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $chan,
					msg => 'Channel delinked',
					nojlink => 1,
				});
			} else {
				my $nick = $nicks[$$split]{$nid} = $nicks[$$chan]{$nid};
				# need to insert the nick into the split off channel before the delink
				# PART is sent, because code is allowed to assume a PARTed nick was actually
				# in the channel it is parting from; this also keeps the channel from being 
				# prematurely removed from the list.
				&Janus::append(+{
					type => 'PART',
					src => $nick,
					dst => $split,
					sendto => [ $net ],
					msg => 'Channel delinked',
					nojlink => 1,
				});
			}
		}
	}
);

=back

=cut

1;
