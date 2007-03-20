package Network;
use Channel;
use Scalar::Util qw(weaken);
use IO::Socket::INET6;

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
	} else {
		my $sock = IO::Socket::INET6->new(
			PeerAddr => $net->{linkaddr},
			PeerPort => $net->{linkport},
		) or return 0;
		$sock->autoflush(1);
		$net->{sock} = $sock;
		$net->intro(0);
	}
	$net->{recvq} = '';
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
	$_[0];
}

sub _modeargs {
	my $net = shift;
	my $mode = shift;
	my @args;
	local $_;
	my $pm = '+';
	for (split //, $mode) {
		if (/[+-]/) {
			$pm = $_;
		} elsif (-1 != index $net->{chmode_lvl}, $_) {
			push @args, $net->nick(shift);
		} elsif (-1 != index $net->{chmode_list}, $_) {
			push @args, $net->_ban(shift);
		} elsif (-1 != index $net->{chmode_val}, $_) {
			push @args, shift;
		} elsif (-1 != index $net->{chmode_val2}, $_) {
			push @args, shift if $pm eq '+';
		} elsif (-1 != index $net->{chmode_bit}, $_) {
		} else {
			warn "Unknown mode '$_'";
		}
	}
	\@args;
}

sub _mode_interp {
	my($net, $act) = @_;
	# TODO translate stuff
	my @args = map { ref $_ ? $_->str($net) : $_ } @{$act->{args}};
	$act->{mode}, @args;
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
