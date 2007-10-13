# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::InterJanus;
use Persist 'EventDump';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my $IJ_PROTO = 1.1;

my @sendq :Persist('sendq');
my @id    :Persist('id')    :Arg(id) :Get(id);
my @auth  :Persist('auth');
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
	unless ($Janus::ijnets{$id[$$ij]} eq $ij) {
		delete $p->{repeat};
		warn "Network $ij not deallocated quickly enough!";
		return;
	}
	my $last = $pong[$$ij];
	if ($last + 90 <= time) {
		print "PING TIMEOUT!\n";
		&Janus::delink($ij, 'Ping timeout');
		&Conffile::connect_net(undef, $p->{id});
		delete $p->{ij};
		delete $p->{repeat};
	} elsif ($last + 29 <= time) {
		$ij->ij_send({ type => 'PING', sendto => [] });
	}
}

sub str {
	warn;
	"";
}

sub intro {
	my($ij,$nconf) = @_;
	$sendq[$$ij] = '';

	$pong[$$ij] = time;
	my $pinger = {
		repeat => 30,
		ij => $ij,
		id => $nconf->{id},
		code => \&pongcheck,
	};
	weaken($pinger->{ij});
	&Janus::schedule($pinger);

	$Janus::ijnets{$id[$$ij]} = $ij;

	$ij->ij_send(+{
		type => 'InterJanus',
		version => $IJ_PROTO,
		id => $nconf->{id},
		pass => $nconf->{sendpass},
	});
	for my $net (values %Janus::nets) {
		$ij->ij_send(+{
			type => 'NETLINK',
			net => $net,
		});
	}
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
	$pong[$$ij] = time;
	local $_ = $_[0];
	print "     IN\@$id[$$ij]  $_\n";

	s/^\s*<(\S+)// or do {
		print "Invalid line: $_";
		return ();
	};
	my $act = { type => $1 };
	$ij->kv_pairs($act);
	warn "bad line: $_[0]" unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->ij_send({ type => 'PONG', sendto => [] });
	} elsif ($auth[$$ij]) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		print "Unsupported InterJanus version $act->{version}\n" if $act->{version} ne $IJ_PROTO;
		if ($id[$$ij] && $act->{id} ne $id[$$ij]) {
			print "Unexpected ID reply $act->{id} from IJ $id[$$ij]\n"
		} else {
			$id[$$ij] = $act->{id};
		}
		my $id = $id[$$ij];
		my $nconf = $Conffile::netconf{$id};
		if (!$nconf) {
			print "Unknown InterJanus server $id\n";
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			print "Failed authorization\n";
		} else {
			$auth[$$ij] = 1;
			$act->{net} = $ij;
			$act->{sendto} = [];
			return $act;
		}
		delete $Janus::ijnets{$id};
		delete $Janus::netqueues{$id};
	}
	return ();
}

1;
