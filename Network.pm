package Network; {
use Object::InsideOut;
use Channel;
use IO::Socket::INET6;
use IO::Socket::SSL 'inet6';
use strict;
use warnings;

my @parms :Field :Set(configure); # filled from rehash
my @cparms :Field; # currently active

my @jlink :Field :Get(jlink);
my @id :Field :Arg(id) :Get(id);
my @nicks :Field;
my @chans :Field;
my @lreq :Field;
my @synced :Field Get(is_synced);

sub netname {
	$cparms[${$_[0]}]{netname};
}

sub to_ij {
	my($net,$ij) = @_;
	' id='.$net->id().' netname='.$net->netname();
}

sub param {
	$parms[${$_[0]}]{$_[1]};
}
sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub _destroy :Destroy {
	print "DBG: $_[0] $cparms[${$_[0]}]{netname} deallocated\n";
}

sub _connect {
	my $net = shift;
	$cparms[$$net] = { %{$parms[$$net]} };
}

sub connect {
	my($net,$sock) = @_;
	$cparms[$$net] = { %{$parms[$$net]} };
	if ($sock) {
		$cparms[$$net]{incoming} = 1;
	} elsif ($cparms[$$net]{linktype} eq "ssl"){
		print "Creating SSL connection to $cparms[$$net]{linkaddr}:$cparms[$$net]{linkport}\n";
		$sock = IO::Socket::SSL->new(
			PeerAddr => $cparms[$$net]{linkaddr},
			PeerPort => $cparms[$$net]{linkport},
			Blocking => 0,
		) or return undef;
 	} else {
		print "Creating Non-SSL connection to $cparms[$$net]{linkaddr}:$cparms[$$net]{linkport}\n";
		$sock = IO::Socket::INET6->new(
			PeerAddr => $cparms[$$net]{linkaddr},
			PeerPort => $cparms[$$net]{linkport}, 
			Blocking => 0,
		) or return undef;
	}
	$sock->autoflush(1);
	$net->intro();
	$sock;
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $old = delete $nicks[$$net]{lc $name};
	unless ($old) {
		$nicks[$$net]{lc $name} = $new;
		return;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	$nicks[$$net]{lc $name} = $new if $tsctl > 0;
	$nicks[$$net]{lc $name} = $old if $tsctl < 0;

	if ($tsctl <= 0) {
		# new nick lost
		$net->send($net->cmd1(KILL => $name, "hub.janus (Nick Collision)")); # FIXME this is unreal-specific
	}
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet()->id() eq $net->id()) {
			warn "Nick collision on home network!";
		} else {
			Janus::insert_full(+{
				type => 'CONNECT',
				dst => $new,
				net => $net,
				reconnect => 1,
				nojlink => 1,
			});
		}
	}
}

sub _nicks {
	my $net = $_[0];
	$nicks[$$net];
}

sub _chans {
	my $net = $_[0];
	$chans[$$net];
}

sub nick {
	my($net, $name) = @_;
	return $nicks[$$net]{lc $name} if $nicks[$$net]{lc $name};
	print "Nick '$name' does not exist; ignoring\n" unless $_[2];
	undef;
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $chans[$$net]{lc $name}) {
		return undef unless $new;
		print "Creating channel $name\n" if $new;
		$chans[$$net]{lc $name} = Channel->new(
			net => $net, 
			name => $name,
		);
	}
	$chans[$$net]{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	warn "replacing nonexistant channel" unless exists $chans[$$net]{lc $name};
	if (defined $new) {
		$chans[$$net]{lc $name} = $new;
	} else {
		delete $chans[$$net]{lc $name};
	}
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
		my $txt = $net->cmode2txt($_) || 'UNK';
		my $type = substr $txt,0,1;
		if ($type eq 'n') {
			push @args, $net->nick(shift);
		} elsif ($type eq 'l') {
			push @args, shift;
		} elsif ($type eq 'v') {
			push @args, shift;
		} elsif ($type eq 's') {
			push @args, shift if $pm eq '+';
		} elsif ($type ne 'r') {
			warn "Unknown mode '$_' ($txt)";
			next;
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
		if (defined $net->txt2cmode($txt)) {
			push @args, ref $itm ? $itm->str($net) : $itm if defined $itm;
			$mode .= $ipm if $ipm ne $pm;
			$mode .= $net->txt2cmode($txt);
			$pm = $ipm;
		} else {
			warn "Unsupported channel mode '$txt' for network";
		}
	}
	$mode, @args;
}

sub item {
	my($net, $item) = @_;
	return undef unless defined $item;
	return $nicks[$$net]{lc $item} if exists $nicks[$$net]{lc $item};
	return $chans[$$net]{lc $item} if exists $chans[$$net]{lc $item};
	return $net if $item =~ /\./;
	return undef;
}

sub str {
	warn;
	$_[0]->id();
}

################################################################################
# Basic Actions
################################################################################

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick) = @_;
	my $maxlen = $net->nicklen();
	my $given = substr $reqnick, 0, $maxlen;
	if ($_[3] || exists $nicks[$$net]{lc $given}) {
		my $tag = $net->param('tag_prefix');
		$tag = '/' unless defined $tag;
		$tag .= $nick->homenet()->id();
		my $i = 0;
		$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
		while (exists $nicks[$$net]{lc $given}) {
			my $itag = (++$i).$tag; # it will find a free nick eventually...
			$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
		}
	}
	$nicks[$$net]{lc $given} = $nick;
	return $given;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
	delete $nicks[$$net]{lc $req};
}

sub add_req {
	my($net, $lchan, $onet, $ochan) = @_;
	$lreq[$$net]{$lchan}{$onet->id()} = $ochan;
}

sub is_req {
	my($net, $lchan, $onet) = @_;
	$lreq[$$net]{$lchan}{$onet->id()};
}

sub del_req {
	my($net, $lchan, $onet) = @_;
	delete $lreq[$$net]{$lchan}{$onet->id()};
}

sub modload {
 my $me = shift;
 return unless $me eq 'Network';
 Janus::hook_add($me,
 	LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
	}, NETSPLIT => act => sub {
		my $act = shift;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;
		for my $nick (values %{$nicks[$$net]}) {
			next if $nick->homenet()->id() ne $tid;
			push @clean, +{
				type => 'QUIT',
				dst => $nick,
				msg => "hub.janus $tid.janus",
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean);
		print "Nick deallocation start\n";
		@clean = ();
		print "Nick deallocation end\n";
		for my $chan (values %{$chans[$$net]}) {
			push @clean, +{
				type => 'DELINK',
				dst => $chan,
				net => $net,
				sendto => [],
			};
		}
		&Janus::insert_full(@clean);
		print "Channel deallocation start\n";
		@clean = ();
		print "Channel deallocation end\n";
	}, NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		my $tid = $net->id();
		my @clean;

		warn "nicks remain after a netsplit\n" if %{$nicks[$$net]};
		for my $nick (values %{$nicks[$$net]}) {
			push @clean, +{
				type => 'KILL',
				dst => $nick,
				net => $net,
				msg => 'JanusSplit',
				nojlink => 1,
			};
		}
		&Janus::insert_full(@clean) if @clean;
		warn "nicks still remain after netsplit kills\n" if %{$nicks[$$net]};
		delete $nicks[$$net];
		warn "channels remain after a netsplit\n" if %{$chans[$$net]};
		delete $chans[$$net];
	});
}

} 1;
