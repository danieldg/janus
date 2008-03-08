# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Server::InterJanus;
use Persist 'EventDump';
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;

my $IJ_PROTO = 1.6;

my @sendq :Persist('sendq');
my @id    :Persist('id')    :Arg(id) :Get(id);
my @auth  :Persist('auth')  :Get(is_linked);

sub str {
	warn;
	"";
}

sub intro {
	my($ij,$nconf) = @_;
	$sendq[$$ij] = '';

	$ij->send(+{
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
	&Debug::alloc("IJNET:$$net $id[$$net] deallocated");
}

sub jlink {
	$_[0];
}

sub send {
	my $ij = shift;
	my @out = $ij->dump_act(@_);
	&Debug::netout($ij, $_) for @out;
	$sendq[$$ij] .= join '', map "$_\n", @out;
}

sub dump_sendq {
	my $ij = shift;
	my $q = $sendq[$$ij];
	$sendq[$$ij] = '';
	$q;
}

sub parse {
	&Debug::netin(@_);
	my $ij = shift;
	local $_ = $_[0];

	s/^\s*<([^ >]+)// or do {
		&Debug::err_in($ij, "Invalid IJ line\n");
		return ();
	};
	my $act = { type => $1 };
	$ij->kv_pairs($act);
	warn "bad line: $_[0]" unless /^\s*>\s*$/;
	$act->{except} = $ij;
	if ($act->{type} eq 'PING') {
		$ij->send({ type => 'PONG' });
	} elsif ($auth[$$ij]) {
		return $act;
	} elsif ($act->{type} eq 'InterJanus') {
		if ($id[$$ij] && $act->{id} ne $id[$$ij]) {
			&Janus::err_jmsg(undef, "Unexpected ID reply $act->{id} from IJ $id[$$ij]");
		} else {
			$id[$$ij] = $act->{id};
		}
		my $ts_delta = abs($Janus::time - $act->{ts});
		my $id = $id[$$ij];
		my $nconf = $Conffile::netconf{$id};
		if ($act->{version} ne $IJ_PROTO) {
			&Janus::err_jmsg(undef, "Unsupported InterJanus version $act->{version} (local $IJ_PROTO)");
		} elsif ($Janus::name ne $act->{rid}) {
			&Janus::err_jmsg(undef, "Unexpected connection: remote was trying to connect to $act->{rid}");
		} elsif (!$nconf) {
			&Janus::err_jmsg(undef, "Unknown InterJanus server $id");
		} elsif ($act->{pass} ne $nconf->{recvpass}) {
			&Janus::err_jmsg(undef, "Failed authorization");
		} elsif ($Janus::ijnets{$id} && $Janus::ijnets{$id} ne $ij) {
			&Janus::err_jmsg(undef, "Already connected");
		} elsif ($ts_delta >= 20) {
			&Janus::err_jmsg(undef, "Clocks are too far off (delta=$ts_delta here=$Janus::time there=$act->{ts})");
		} else {
			$auth[$$ij] = 1;
			$act->{net} = $ij;
			$act->{type} = 'JNETLINK';
			return $act;
		}
		if ($Janus::ijnets{$id} && $Janus::ijnets{$id} eq $ij) {
			delete $Janus::ijnets{$id};
		}
	}
	return ();
}

&Janus::hook_add(
	JNETLINK => act => sub {
		my $act = shift;
		my $ij = $act->{net};
		for my $net (values %Janus::nets) {
			$ij->send(+{
				type => 'NETLINK',
				net => $net,
			});
			$ij->send(+{
				type => 'LINKED',
				net => $net,
			}) if $net->is_synced();
		}
		$ij->send(+{
			type => 'JLINKED',
		});
	}
);

1;
