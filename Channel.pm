package Channel;
use Nick;
use Scalar::Util qw(weaken);
use strict;
use warnings;

sub new {
	my($class,$net,$name) = @_;
	my %chash = (
		ts => 0,
		topic => '',
		topicts => 0,
		topicset => '',
		ban_b => [],
		ban_e => [],
		ban_I => [],
		mode => {},
	); my $chan = \%chash;
	my $id = $net->id();
	weaken($chan->{nets}->{$id} = $net);
	$chan->{names}->{$id} = $name;
	bless $chan, $class;
}

sub _ljoin {
	my($nick, $chan, $src, $nets) = @_;
	my $id = $nick->id();
	
	for my $net (values %$nets) {
		my $line = $nick->is_klined($net);
		if ($line) {
			return +{
				type => 'KICK',
				src => $line->{net},
				dst => $chan,
				sendto => [ values %{$src->{nets}} ],
				kickee => $nick,
				reason => "K:lined by $line->{net}->{netname} ($line->{reason})",
			}
		}
	}
	my @act;
	for my $net (values %$nets) {
		push @act, $nick->connect($net);
	}
	$nick->_join($chan);

	my $mode = $src->{nmode}->{$id};
	$chan->{nicks}->{$id} = $nick;
	$chan->{nmode}->{$id} = $mode;
	push @act, +{
		type => 'JOIN',
		src => $nick,
		dst => $chan,
		sendto => [ values %$nets ],
		mode => $mode,
	};
	@act;
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
	local $_;
	$chan->{$_} = $src->{$_} for qw/ts topic topicts topicset/;
	$chan->{$_} = [ @{$src->{$_}} ] for qw/ban_b ban_e ban_I/;
	$chan->{mode} = { %{$src->{mode}} };
}

sub delink {
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

sub try_join {
	my($chan,$nick) = @_;
	for my $id (keys %{$chan->{nets}}) {
		my $net = $chan->{nets}->{$id};
		my $line = $nick->is_klined($net);
		if ($line) {
			return +{
				type => 'KICK',
				src => $line->{net},
				dst => $chan,
				sendto => [ $nick->{homenet} ],
				kickee => $nick,
				reason => "K:lined by $line->{net}->{netname} ($line->{reason})",
			};
		}
	}
	my @acts;
	for my $id (keys %{$chan->{nets}}) {
		my $net = $chan->{nets}->{$id};
		push @acts, $nick->connect($net);
	}
	$chan->{nicks}->{$nick->id()} = $nick;
	$nick->_join($chan);
	push @acts, +{
		type => 'JOIN',
		src => $nick,
		dst => $chan,
		mode => $_[2],
	};
	@acts;
}

sub _part {
	my($chan,$nick) = @_;
	delete $chan->{nicks}->{$nick->id()};
	delete $chan->{nmode}->{$nick->id()};
}

sub timesync {
	my($chan, $ts) = @_;
	$chan->{ts} = $ts;
	# TODO wipe modes if older $ts given
}

sub modload {
	my($me, $janus) = @_;
	$janus->hook_add($me, 
		JOIN => act => sub {
			my $act = shift;
			my $nick = $act->{src};
			my $chan = $act->{dst};
			if ($act->{mode}) {
				$chan->{nmode}->{$nick->id()} = $act->{mode};
			}
			undef;
		}, PART => postact => sub {
			my $act = shift;
			my $nick = $act->{src};
			my $chan = $act->{dst};
			$chan->_part($nick);
			undef;
		}, KICK => postact => sub {
			my $act = shift;
			my $nick = $act->{kickee};
			my $chan = $act->{dst};
			$chan->_part($nick);
			undef;
		}, MODE => act => sub {
			my $act = shift;
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
			undef;
		}, TOPIC => act => sub {
			my $act = shift;
			my $chan = $act->{dst};
			$chan->{topic} = $act->{topic};
			$chan->{topicts} = $act->{topicts} || time;
			$chan->{topicset} = $act->{topicset} || $act->{src}->{homenick};
			undef;
		}, LINK => presend => sub {
			my $act = shift;
			my($chan1,$chan2) = ($act->{dst}, $act->{add});
	
			for my $id (keys %{$chan1->{nets}}) {
				return +{
					type => 'MSG',
					dst => $act->{src},
					notice => 1,
					msg => "Cannot link: this channel would be in $id twice",
				} if exists $chan2->{nets}->{$id};
			}
			$act;
			# TODO append Channel information when masking Janus-Janus info
		}, LINK => act => sub {
			my $act = shift;
			my($chan1,$chan2) = ($act->{dst}, $act->{add});

			my %chanh;
			my $chan = \%chanh;
			bless $chan;
			my @acts;

			if ($chan1->{ts} == $chan2->{ts}) {
				# Equal timestamps; recovering from a split. Merge any information
				# chan1 wins ties since they asked for the link
				print "Link on equal TS\n";
				if ($chan1->{topicts} >= $chan2->{topicts}) {
					$chan->{$_} = $chan1->{$_} for qw/topic topicts topicset/;
					push @acts, +{
						type => 'TOPIC',
						dst => $chan2,
						topic => $chan->{topic},
						topicts => $chan->{topicts},
						topicset => $chan->{topicset},
					} unless $chan1->{topic} eq $chan2->{topic};
				} else {
					$chan->{$_} = $chan2->{$_} for qw/topic topicts topicset/;
					push @acts, +{
						type => 'TOPIC',
						dst => $chan1,
						topic => $chan->{topic},
						topicts => $chan->{topicts},
						topicset => $chan->{topicset},
					} unless $chan1->{topic} eq $chan2->{topic};
				}
				$chan->{ts} = $chan1->{ts};
				$chan->{$_} = [ @{$chan1->{$_}}, @{$chan2->{$_}} ] for qw/ban_b ban_e ban_I/;
				my %m = %{$chan2->{mode}};
				$m{$_} = $chan1->{mode}->{$_} for keys %{$chan1->{mode}};
				$chan->{mode} = \%m;
			} elsif (!$chan1->{ts} || ($chan1->{ts} > $chan2->{ts} && $chan2->{ts})) {
				print "Channel 2 wins TS\n";
				$chan->_modecpy($chan2);
				$chan1->timesync(1); # mode wipe
			} else {
				print "Channel 1 wins TS\n";
				$chan->_modecpy($chan1);
				$chan2->timesync(1); # mode wipe
			}

			$chan->_mergenet($chan1);
			$chan->_mergenet($chan2);

			for my $nick (values %{$chan1->{nicks}}) {
				push @acts, _ljoin $nick, $chan, $chan1, $chan2->{nets};
			}
			for my $nick (values %{$chan2->{nicks}}) {
				push @acts, _ljoin $nick, $chan, $chan2, $chan1->{nets};
			}
			
			@acts;
		}, DELINK => act => sub {
			my $act = shift;
			my $chan = $act->{dst};
			my $net = $act->{net};
			my $id = $net->id();
			return () unless exists $chan->{nets}->{$id};
			delete $chan->{nets}->{$id};
			my $name = delete $chan->{names}->{$id};

			my %chanh = (
				nets => { $id => $net },
				names => { $id => $name },
			);
			my $split = \%chanh;
			bless $split;
			$split->_modecpy($chan);

			$net->{chans}->{lc $name} = $split;

			my @act;
			for my $nid (keys %{$chan->{nicks}}) {
				if ($chan->{nicks}->{$nid}->{homenet}->id() eq $id) {
					my $nick = $split->{nicks}->{$nid} = $chan->{nicks}->{$nid};
					$split->{nmode}->{$nid} = $chan->{nmode}->{$nid};
					$nick->_join($split);
					push @act, +{
						type => 'PART',
						src => $nick,
						dst => $chan,
						msg => 'Channel delinked',
					};
				} else {
					my $nick = $chan->{nicks}->{$nid};
					push @act, +{
						type => 'PART',
						src => $nick,
						dst => $split,
						sendto => [ $net ],
						msg => 'Channel delinked',
					};
				}
			}
			@act;
		},
	);
}

1;
