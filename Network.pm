package Network;
use Channel;
use Scalar::Util qw(weaken);
use IO::Socket::INET6;
use IO::Socket::SSL 'inet6';

sub new {
	my $class = shift;
	my %neth = @_;
	my $net = \%neth;
	bless $net, $class;
}

sub DESTROY {
	print "DBG: $_[0] $_[0]->{netname} deallocated\n";
}

sub connect {
	my $net = shift;
	if (@_) {
		$net->{sock} = shift;
		$net->intro(1);
	} elsif ($net->{linktype} eq "ssl"){
		my $sock = IO::Socket::SSL->new(
			PeerAddr => $net->{linkaddr},
			PeerPort => $net->{linkport},
		) or return 0;
		$sock->autoflush(1);
		$net->{sock} = $sock;
		$net->intro(0);
 	} else {
		my $sock = IO::Socket::INET6->new(
			PeerAddr => $net->{linkaddr},
			PeerPort => $net->{linkport}, 
		) or return 0;
		$sock->autoflush(1);
		$net->{sock} = $sock;
		$net->intro(0);
	}
	1;
}

sub netsplit {
	warn
}

sub id {
	return $_[0]->{id};
}

sub nick {
	my($net, $name) = @_;
	return $net->{nicks}->{lc $name} if $net->{nicks}->{lc $name};
	print "Nick '$name' does not exist; ignoring\n";
	undef;
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $net->{chans}->{lc $name}) {
		print "Creating channel $name when creation was not requested\n" unless $new;
		my $id = $net->{id};
		$net->{chans}->{lc $name} = Channel->new($net, $name);
	}
	$net->{chans}->{lc $name};
}

sub _ban {
	# TODO translate bans
	$_[1];
}

sub _modeargs {
	my $net = shift;
	my $mode = shift;
	my @modes;
	my @args;
	local $_;
	my $pm = '+';
	for (split //, $mode) {
		if (/[-+]/) {
			$pm = $_;
			next;
		}
		my $txt = $net->{params}->{cmode2txt}->{$_} || 'UNK';
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			push @args, $net->nick(shift);
		} elsif ($type eq 'l') {
			push @args, $net->_ban(shift);
		} elsif ($type eq 'v') {
			push @args, shift;
		} elsif ($type eq 's') {
			push @args, shift if $pm eq '+';
		} elsif ($type ne 'r') {
			warn "Unknown mode '$_' ($txt)";
		}
		push @modes, $pm.$txt;
	}
	(\@modes, \@args);
}

sub _mode_interp {
	my($net, $act) = @_;
	my $pm = '';
	my $mode;
	my @argin = @{$act->{args}};
	my @args;
	for my $mtxt (@{$act->{mode}}) {
		my($ipm,$txt) = ($mtxt =~ /^([-+])(.*)/) or warn $mtxt;
		my $itm = ($txt =~ /^[nlv]/ || $mtxt =~ /^\+s/) ? shift @argin : undef;
		if (exists $net->{params}->{txt2cmode}->{$txt}) {
			push @args, ref $itm ? $itm->str($net) : $itm if defined $itm;
			$mode .= $ipm if $ipm ne $pm;
			$mode .= $net->{params}->{txt2cmode}->{$txt};
			$pm = $ipm;
		} else {
			warn "Unsupported channel mode '$txt' for network";
		}
	}
	$mode, @args;
}

sub item {
	my($net, $item) = @_;
	return $net->{nicks}->{lc $item} if exists $net->{nicks}->{lc $item};
	return $net->{chans}->{lc $item} if exists $net->{chans}->{lc $item};
	return undef;
}

sub str {
	$_[0]->{id};
}

################################################################################
# Basic Actions
################################################################################

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick) = @_;
	my $maxlen = $net->{params}->{nicklen};
	$reqnick = substr $reqnick, 0, $maxlen;
	if ($_[3] || exists $net->{nicks}->{lc $reqnick}) {
		my $tag = '/'.$nick->{homenet}->id();
		my $i = 0;
		$reqnick = substr($reqnick, 0, $maxlen - length $tag) . $tag;
		while (exists $net->{nicks}->{lc $reqnick}) {
			$itag = (++$i).$tag; # it will find a free nick eventually...
			$reqnick = substr($reqnick, 0, $maxlen - length $itag) . $itag;
		}
	}
	$net->{nicks}->{lc $reqnick} = $nick;
	return $reqnick;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
	delete $net->{nicks}->{lc $req};
}

sub banlist {
	my $net = shift;
	my @list = keys %{$net->{ban}};
	my @good;
	for my $i (@list) {
		my $exp = $net->{ban}->{$i}->{expire};
		if ($exp && $exp < time) {
			delete $net->{ban}->{$i};
		} else {
			push @good, $exp;
		}
	}
	@good;
}

sub modload {
 my($me, $janus) = @_;
 return unless $me eq 'Network';
 $janus->hook_add($me,
	NETSPLIT => act => sub {
		my($j, $act) = @_;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;
		for my $nick (values %{$net->{nicks}}) {
			next if $nick->{homenet}->id() ne $tid;
			push @clean, +{
				type => 'QUIT',
				dst => $nick,
				msg => "hub.janus $tid.janus",
				nojlink => 1,
			};
		}
		$j->insert_full(@clean);
		for my $chan (values %{$net->{chans}}) {
			$j->append(+{
				type => 'DELINK',
				dst => $chan,
				net => $net,
				sendto => [],
			});
		}
	}, NETSPLIT => clean => sub {
		my($j, $act) = @_;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;

		warn "nicks remain after a netsplit\n" if %{$net->{nicks}};
		for my $nick (values %{$net->{nicks}}) {
			push @clean, +{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => 'JanusSplit',
				nojlink => 1,
			};
		}
		$j->insert_full(@clean) if @clean;
		warn "nicks still remain after netsplit kills\n" if %{$net->{nicks}};
		delete $net->{nicks};
		warn "channels remain after a netsplit\n" if %{$net->{chans}};
		delete $net->{chans};
	});
}

1;
