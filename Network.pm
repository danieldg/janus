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

sub id {
	return $_[0]->{id};
}

sub nick {
	my($net, $name) = @_;
	$net->{nicks}->{lc $name};
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $net->{chans}->{lc $name}) {
		warn "$name" unless $new;
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
		my $txt = $net->{cmode2txt}->{$_} || 'UNK';
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
		if (exists $net->{txt2cmode}->{$txt}) {
			push @args, ref $itm ? $itm->str($net) : $itm if defined $itm;
			$mode .= $ipm if $ipm ne $pm;
			$mode .= $net->{txt2cmode}->{$txt};
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
	return $net;
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
	if (exists $net->{nicks}->{lc $reqnick}) {
		my $tag = '/'.$nick->{homenet}->id();
		$reqnick = substr($reqnick, 0, 30 - length $tag) . $tag;
		if (exists $net->{nicks}->{lc $reqnick}) {
			warn "Collision with tagged nick"; # TODO kill or change tag
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

1;
