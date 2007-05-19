package LocalNetwork; {
use Object::InsideOut qw(Network);
use Scalar::Util qw(weaken);
use strict;
use warnings;

my @parms :Field :Set(configure); # filled from rehash
my @cparms :Field; # currently active

my @lreq :Field;
my @synced :Field Get(is_synced);
my @ponged :Field;

sub param {
	$parms[${$_[0]}]{$_[1]};
}
sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub pong {
	my $net = shift;
	$ponged[$$net] = time;
}

sub intro :Cumulative {
	my $net = shift;
	$cparms[$$net] = { %{$parms[$$net]} };
	$net->_set_netname($cparms[$$net]->{netname});
	$ponged[$$net] = time;
	my %pinger = (
		repeat => 30,
		net => $net,
		code => sub {
			my $p = shift;
			my $net = $p->{net};
			unless ($net) {
				delete $p->{repeat};
				return;
			}
			my $last = $ponged[$$net];
			if ($last + 90 < time) {
				print "PING TIMEOUT!\n";
				&Janus::delink($net, 'Ping timeout');
				delete $p->{net};
				delete $p->{repeat};
			} else {
				$net->send(+{
					type => 'PING',
				});
			}
		},
	);
	weaken($pinger{$net});
	&Janus::schedule(\%pinger);
}

sub nick_collide {
	my($net, $name, $new) = @_;
	my $nicks = $net->_nicks();
	my $old = delete $nicks->{lc $name};
	unless ($old) {
		$nicks->{lc $name} = $new;
		return;
	}
	my $tsctl = $old->ts() <=> $new->ts();

	$nicks->{lc $name} = $new if $tsctl > 0;
	$nicks->{lc $name} = $old if $tsctl < 0;

	if ($tsctl <= 0) {
		# new nick lost
		$net->send($net->cmd1(KILL => $name, "hub.janus (Nick Collision)")); # FIXME this is unreal-specific
	}
	if ($tsctl >= 0) {
		# old nick lost, reconnect it
		if ($old->homenet()->id() eq $net->id()) {
			warn "Nick collision on home network!";
		} else {
			&Janus::insert_full(+{
				type => 'RECONNECT',
				dst => $new,
				net => $net,
				killed => 1,
				nojlink => 1,
			});
		}
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

################################################################################
# Basic Actions
################################################################################

# Request a nick on a remote network (CONNECT/JOIN must be sent AFTER this)
sub request_nick {
	my($net, $nick, $reqnick, $tagged) = @_;
	my $maxlen = $net->nicklen();
	my $nicks = $net->_nicks();
	my $given = substr $reqnick, 0, $maxlen;

	$tagged = 1 if exists $nicks->{lc $given};

	if ($nick->homenet()->id() eq $net->id()) {
		warn "Unhandled nick change collision on home network" if $tagged;
		$tagged = 0;
	} else {
		my $tagre = $net->param('force_tag');
		$tagged = 1 if $tagre && $given =~ /$tagre/;
	}
	
	if ($tagged) {
		my $tagsep = $net->param('tag_prefix');
		$tagsep = '/' unless defined $tagsep;
		my $tag = $tagsep . $nick->homenet()->id();
		my $i = 0;
		$given = substr($reqnick, 0, $maxlen - length $tag) . $tag;
		while (exists $nicks->{lc $given}) {
			my $itag = $tagsep.(++$i).$tag; # it will find a free nick eventually...
			$given = substr($reqnick, 0, $maxlen - length $itag) . $itag;
		}
	}
	$nicks->{lc $given} = $nick;
	return $given;
}

# Release a nick on a remote network (PART/QUIT must be sent BEFORE this)
sub release_nick {
	my($net, $req) = @_;
	my $nicks = $net->_nicks();
	delete $nicks->{lc $req};
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
 return unless $me eq 'LocalNetwork';
 &Janus::hook_add($me,
 	LINKED => check => sub {
		my $act = shift;
		my $net = $act->{net};
		$synced[$$net] = 1;
	});
}

} 1;
