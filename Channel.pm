package Channel;
use Nick;
use Scalar::Util qw(weaken);
use strict;
use warnings;

sub new {
	my($class,$net,$name) = @_;
	my %chash = (
		ts => time + 60,
		topic => '',
		topicts => 0,
		topicset => '',
		mode => {},
	); my $chan = \%chash;
	my $id = $net->id();
	weaken($chan->{nets}->{$id} = $net);
	$chan->{names}->{$id} = $name;
	bless $chan, $class;
}

sub _ljoin {
	my($chan, $j, $nick, $src) = @_;
	my $id = $nick->id();
	
	my $mode = $src->{nmode}->{$id};
	$chan->{nicks}->{$id} = $nick;
	$chan->{nmode}->{$id} = $mode;
	$nick->rejoin($j, $chan);
}

sub _mergenet {
	my($chan, $src) = @_;
	for my $id (keys %{$src->{nets}}) {
		my $net = $src->{nets}->{$id};
		my $name = $src->{names}->{$id};
		$chan->{nets}->{$id} = $net;
		$chan->{names}->{$id} = $name;
		$net->{chans}->{lc $name} = $chan;
	}
}

sub _modecpy {
	my($chan, $src) = @_;
	for my $txt (keys %{$src->{mode}}) {
		if ($txt =~ /^l/) {
			$chan->{mode}->{$txt} = [ @{$src->{mode}->{$txt}} ];
		} else {
			$chan->{mode}->{$txt} = $src->{mode}->{$txt};
		}
	}
}

sub _mode_delta {
	my($chan, $dst, $j) = @_;
	my %add = %{$dst->{mode}};
	my(@modes, @args);
	for my $txt (keys %{$chan->{mode}}) {
		if ($txt =~ /^l/) {
			my %torm = map { $_ => 1} @{$chan->{mode}->{$txt}};
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
				if ($chan->{mode}->{$txt} eq $add{$txt}) {
					# hey, isn't that nice
				} else {
					push @modes, '+'.$txt;
					push @args, $add{$txt};
				}
			} else {
				push @modes, '-'.$txt;
				push @args, $chan->{mode}->{$txt} unless $txt =~ /^s/;
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
}

# get name on a network
sub str {
	my($chan,$net) = @_;
	$chan->{names}->{$net->id()};
}

sub id { die }

sub sendto {
	my($chan,$act,$except) = @_;
	my %n = %{$chan->{nets}};
	delete $n{$except->id()} if $except;
	values %n;
}

sub part {
	my($chan,$nick) = @_;
	delete $chan->{nicks}->{$nick->id()};
	delete $chan->{nmode}->{$nick->id()};
	return if keys %{$chan->{nicks}};
	# destroy channel
	for my $id (keys %{$chan->{nets}}) {
		my $name = $chan->{names}->{$id};
		delete $chan->{nets}->{$id}->{chans}->{$name};
	}
}

sub DESTROY {
	my $name = join ',', map $_.$_[0]->{names}->{$_}, keys %{$_[0]->{names}};
	print "DBG: $_[0] $name deallocated\n";
}

sub timesync {
	my($chan, $new) = @_;
	return unless $new > 1000000; #don't EVER destroy channel TSes with that annoying Unreal message
	my $old = $chan->{ts};
	return if $old <= $new; # we are actually not resetting the TS, how nice!
	# Wipe modes in preparation for an overriding merge
	$chan->{ts} = $new;
	$chan->{nmode} = {};
	$chan->{mode} = {};
}

sub modload {
 my($me, $janus) = @_;
 $janus->hook_add($me, 
	JOIN => act => sub {
		my $act = $_[1];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->{nicks}->{$nick->id()} = $nick;
		if ($act->{mode}) {
			$chan->{nmode}->{$nick->id()} = { %{$act->{mode}} };
		}
	}, PART => cleanup => sub {
		my $act = $_[1];
		my $nick = $act->{src};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, KICK => cleanup => sub {
		my $act = $_[1];
		my $nick = $act->{kickee};
		my $chan = $act->{dst};
		$chan->part($nick);
	}, MODE => act => sub {
		my $act = $_[1];
		local $_;
		my $chan = $act->{dst};
		my @args = @{$act->{args}};
		for my $itxt (@{$act->{mode}}) {
			my $pm = substr $itxt, 0, 1;
			my $t = substr $itxt, 1, 1;
			my $i = substr $itxt, 1;
			if ($t eq 'n') {
				my $nick = shift @args;
				$chan->{nmode}->{$nick->id()}->{$i} = 1 if $pm eq '+';
				delete $chan->{nmode}->{$nick->id()}->{$i} if $pm eq '-';
			} elsif ($t eq 'l') {
				if ($pm eq '+') {
					push @{$chan->{mode}->{$i}}, shift @args;
				} else {
					my $b = shift @args;
					@{$chan->{mode}->{$i}} = grep { $_ ne $b } @{$chan->{mode}->{$i}};
				}
			} elsif ($t eq 'v') {
				$chan->{mode}->{$i} = shift @args;
				delete $chan->{mode}->{$i} if $pm eq '-';
			} elsif ($t eq 's') {
				$chan->{mode}->{$i} = shift @args if $pm eq '+';
				delete $chan->{mode}->{$i} if $pm eq '-';
			} elsif ($t eq 'r') {
				$chan->{mode}->{$i} = 1;
				delete $chan->{mode}->{$i} if $pm eq '-';
			} else {
				warn "Unknown mode '$itxt'";
			}
		}
	}, TOPIC => act => sub {
		my $act = $_[1];
		my $chan = $act->{dst};
		$chan->{topic} = $act->{topic};
		$chan->{topicts} = $act->{topicts} || time;
		$chan->{topicset} = $act->{topicset} || $act->{src}->{homenick};
	}, LINK => check => sub {
		my($j,$act) = @_;
		my($chan1,$chan2) = ($act->{chan1}, $act->{chan2});

		for my $id (keys %{$chan1->{nets}}) {
			if (exists $chan2->{nets}->{$id}) {
				$j->append(+{
					type => 'MSG',
					src => $j->{janus},
					dst => $act->{src},
					notice => 1,
					msg => "Cannot link: this channel would be in $id twice",
				});
				return 1;
			}
		}
		undef;
	}, LINK => act => sub {
		my($j,$act) = @_;
		my $send = $act->{src}->{homenet}->{jlink} ? 0 : 1;
		my($chan1,$chan2) = ($act->{chan1}, $act->{chan2});
		
		my $tsctl = ($chan2->{ts} <=> $chan1->{ts});
		# topic timestamps are backwards: later topic change is taken IF the creation stamps are the same
		# otherwise go along with the channel sync
		my $topctl = $tsctl ? $tsctl : ($chan1->{topicts} <=> $chan2->{topicts});

		my %chanh = (
			mode => {},
		);
		my $chan = \%chanh;
		bless $chan;
		$act->{dst} = $chan;

		# basic strategy: Modify the two channels in-place to have the same modes as we create
		# the unified channel

		# First, set the timestamps
		$chan1->timesync($chan2->{ts});
		$chan2->timesync($chan1->{ts});
		$chan->{ts} = $chan1->{ts}; # the timestamps are now equal so just copy #1 because it's first

		if ($topctl >= 0) {
			print "Channel 1 wins control of topic\n";
			$chan->{$_} = $chan1->{$_} for qw/topic topicts topicset/;
			if ($chan1->{topic} ne $chan2->{topic}) {
				$j->append(+{
					type => 'TOPIC',
					dst => $chan2,
					topic => $chan->{topic},
					topicts => $chan->{topicts},
					topicset => $chan->{topicset},
					nojlink => 1,
				});
			}
		} else {
			print "Channel 2 wins control of topic\n";
			$chan->{$_} = $chan2->{$_} for qw/topic topicts topicset/;
			if ($chan1->{topic} ne $chan2->{topic}) {
				$j->append(+{
					type => 'TOPIC',
					dst => $chan1,
					topic => $chan->{topic},
					topicts => $chan->{topicts},
					topicset => $chan->{topicset},
					nojlink => 1,
				});
			}
		}

		if ($tsctl > 0) {
			print "Channel 1 wins TS\n";
			$chan->_modecpy($chan1);
		} elsif ($tsctl < 0) {
			print "Channel 2 wins TS\n";
			$chan->_modecpy($chan2);
		} else {
			# Equal timestamps; recovering from a split. Merge any information
			my @allmodes = keys(%{$chan1->{mode}}), keys(%{$chan2->{mode}});
			for my $txt (@allmodes) {
				if ($txt =~ /^l/) {
					my %m;
					if (exists $chan1->{mode}->{$txt}) {
						$m{$_} = 1 for @{$chan1->{mode}->{$txt}};
					}
					if (exists $chan2->{mode}->{$txt}) {
						$m{$_} = 1 for @{$chan2->{mode}->{$txt}};
					}
					$chan->{mode}->{$txt} = [ keys %m ];
				} else {
					if (exists $chan1->{mode}) {
						$chan->{mode}->{$txt} = $chan1->{mode}->{$txt};
					} else {
						$chan->{mode}->{$txt} = $chan2->{mode}->{$txt};
					}
				}
			}
		}

		$chan1->_mode_delta($chan, $j) if $send;
		$chan2->_mode_delta($chan, $j) if $send;

		$chan->_mergenet($chan1);
		$chan->_mergenet($chan2);

		my $nets1 = [ values %{$chan1->{nets}} ];
		my $nets2 = [ values %{$chan2->{nets}} ];

		for my $nick (values %{$chan1->{nicks}}) {
			$chan->_ljoin($j,$nick, $chan1);
			$j->append(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				sendto => $nets2,
				mode => $chan->{nmode}->{$nick->id()},
				nojlink => 1,
			});
		}
		for my $nick (values %{$chan2->{nicks}}) {
			$chan->_ljoin($j, $nick, $chan2);
			$j->append(+{
				type => 'JOIN',
				src => $nick,
				dst => $chan,
				sendto => $nets1,
				mode => $chan->{nmode}->{$nick->id()},
				nojlink => 1,
			});
		}
	}, DELINK => act => sub {
		my($j,$act) = @_;
		my $chan = $act->{dst};
		my $net = $act->{net};
		my $id = $net->id();
		return unless exists $chan->{nets}->{$id};
		$act->{sendto} = [ values %{$chan->{nets}} ]; # before the splitting
		delete $chan->{nets}->{$id};
		return if $net->{jlink};

		my $name = delete $chan->{names}->{$id};
		my %chanh = (
			nets => { $id => $net },
			names => { $id => $name },
			ts => $chan->{ts},
			topic => $chan->{topic},
			topicts => $chan->{topicts},
			topicset => $chan->{topicset},
		);
		my $split = \%chanh;
		bless $split;
		$act->{split} = $split;
		$split->_modecpy($chan);
		$net->{chans}->{lc $name} = $split;

		for my $nid (keys %{$chan->{nicks}}) {
			if ($chan->{nicks}->{$nid}->{homenet}->id() eq $id) {
				my $nick = $split->{nicks}->{$nid} = $chan->{nicks}->{$nid};
				$split->{nmode}->{$nid} = $chan->{nmode}->{$nid};
				$nick->rejoin($j, $split);
				$j->append(+{
					type => 'PART',
					src => $nick,
					dst => $chan,
					msg => 'Channel delinked',
					nojlink => 1,
				});
			} else {
				my $nick = $chan->{nicks}->{$nid};
				$j->append(+{
					type => 'PART',
					src => $nick,
					dst => $split,
					sendto => [ $net ],
					msg => 'Channel delinked',
					nojlink => 1,
				});
			}
		}
	});
}

1;
