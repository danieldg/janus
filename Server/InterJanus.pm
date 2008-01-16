# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::InterJanus;
use Persist 'EventDump';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my $IJ_PROTO = 1.4;

my @sendq :Persist('sendq');
my @id    :Persist('id')    :Arg(id) :Get(id);
my @auth  :Persist('auth')  :Get(is_linked);
my @pong  :Persist('ponged');

sub pongcheck {
	my $p = shift;
	my $ij = $p->{ij};
	if ($ij && !isweak($p->{ij})) {
		warn "Reference is strong! Weakening";
		weaken($p->{ij});
	}
	unless ($ij && defined $id[$$ij]) {
		delete $p->{repeat};
		&Conffile::connect_net(undef, $p->{id});
		return;
	}
	my $last = $pong[$$ij];
	if ($last + 90 <= $Janus::time) {
		print "PING TIMEOUT!\n";
		&Janus::delink($ij, 'Ping timeout');
		&Conffile::connect_net(undef, $p->{id});
		delete $p->{ij};
		delete $p->{repeat};
	} elsif ($last + 29 <= $Janus::time) {
		$ij->ij_send({ type => 'PING'  });
	}
}

sub str {
	warn;
	"";
}

sub intro {
	my($ij,$nconf) = @_;
	$sendq[$$ij] = '';

	$pong[$$ij] = $Janus::time;
	my $pinger = {
		repeat => 30,
		ij => $ij,
		id => $nconf->{id},
		code => \&pongcheck,
	};
	weaken($pinger->{ij});
	&Janus::schedule($pinger);

	$ij->ij_send(+{
		type => 'InterJanus',
		version => $IJ_PROTO,
		id => $Janus::name,
		rid => $nconf->{id},
		pass => $nconf->{sendpass},
		ts => $Janus::time,
	});
	# If we are the first mover (initiated connection), auth will be zero, and
	# will end up being 1 after a successful authorization. If we were listening,
	# then to get here we must have already authorized, so change it to 2.
	$auth[$$ij] = $auth[$$ij] ? 2 : 0;
}

sub _destroy {
	my $net = $_[0];
	print "  IJNET:$$net $id[$$net] deallocated\n";
}

sub jlink {
	$_[0];
}

sub ij_send {
	my $ij = shift;
	my @out = $ij->dump_act(@_);
	print "    OUT\@$id[$$ij]  $_\n" for @out;
	$sendq[$$ij] .= join '', map "$_\n", @out;
}

sub dump_sendq {
	my $ij = shift;
	my $q = $sendq[$$ij];
	$sendq[$$ij] = '';
	$q;
}

sub parse {
	my $ij = shift;
	$pong[$$ij] = $Janus::time;
	local $_ = $_[0];
	my $selfid = $id[$$ij] || 'NEW';
	print "     IN\@$selfid  $_\n";

	s/^\s*<([^ >]+)// or do {
		print "Invalid line: $_";
		return ();
	};
	my $act = { type => $1 };
	$ij->kv_pairs($act);
	warn "bad line: $_[0]" unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->ij_send({ type => 'PONG' });
	} elsif ($auth[$$ij]) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		if ($id[$$ij] && $act->{id} ne $id[$$ij]) {
			print "Unexpected ID reply $act->{id} from IJ $id[$$ij]\n"
		} else {
			$id[$$ij] = $act->{id};
		}
		my $ts_delta = abs($Janus::time - $act->{ts});
		my $id = $id[$$ij];
		my $nconf = $Conffile::netconf{$id};
		if ($act->{version} ne $IJ_PROTO) {
			print "Unsupported InterJanus version $act->{version}\n";
		} elsif ($Janus::name ne $act->{rid}) {
			print "Unexpected connection: remote was trying to connect to $act->{rid}\n";
		} elsif (!$nconf) {
			print "Unknown InterJanus server $id\n";
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			print "Failed authorization\n";
		} elsif ($Janus::ijnets{$id} && $Janus::ijnets{$id} ne $ij) {
			print "Already connected\n";
		} elsif ($ts_delta >= 20) {
			print "Clocks are too far off (delta=$ts_delta here=$Janus::time there=$act->{ts})\n";
		} else {
			$auth[$$ij] = 1;
			$act->{net} = $ij;
			$act->{type} = 'JNETLINK';
			return $act;
		}
		# TODO this might be better done by a JNETSPLIT
		delete $Janus::ijnets{$id};
	}
	return ();
}

&Janus::hook_add(
	JNETLINK => act => sub {
		my $act = shift;
		my $ij = $act->{net};
		for my $net (values %Janus::nets) {
			$ij->ij_send(+{
				type => 'NETLINK',
				net => $net,
			});
			$ij->ij_send(+{
				type => 'LINKED',
				net => $net,
			}) if $net->is_synced();
		}
		$ij->ij_send(+{
			type => 'JLINKED',
		});
	}
);

1;
