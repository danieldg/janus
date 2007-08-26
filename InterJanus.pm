# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package InterJanus;
use Persist;
use Scalar::Util qw(isweak weaken);
use strict;
use warnings;
BEGIN {
	&Janus::load('Nick');
}

our($VERSION) = '$Rev$' =~ /(\d+)/;

my @id    :Persist('id')    :Arg(id) :Get(id);
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

my %fromirc;
my %toirc;

my $INST_DBG = do {
	my $no;
	bless \$no;
};

sub str {
	warn;
	"";
}


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

sub jlink {
	$_[0];
}

my %esc2char = (
	e => '\\',
	g => '>',
	l => '<',
	n => "\n",
	q => '"',
);
my %char2esc; $char2esc{$esc2char{$_}} = $_ for keys %esc2char;

sub ijstr {
	my($ij, $itm) = @_;
	local $_;
	if (!defined $itm) {
		return '';
	} elsif (!ref $itm) {
		my $ch = join '', map { /\w/ ? $_ : '\\'.$_ } keys %char2esc;
		$itm =~ s/([$ch])/\\$char2esc{$1}/g;
		return '"'.$itm.'"';
	} elsif ('ARRAY' eq ref $itm) {
		my $out = '<a';
		$out .= ' '.$ij->ijstr($_) for @$itm;
		return $out.'>';
	} elsif ('HASH' eq ref $itm) {
		my $out = '<h';
		$out .= ' '.$_.'='.$ij->ijstr($itm->{$_}) for sort keys %$itm;
		return $out.'>';
	} elsif ($itm->isa('Nick')) {
		return 'n:'.$itm->gid();
	} elsif ($itm->isa('Channel')) {
		return ($$ij ? 'c:' : "c:$$itm:").$itm->keyname();
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->id();
	} elsif ($itm->isa('InterJanus')) {
		return '';
	}
	warn "Unknown object $itm";
	return '""';
}

sub send_hdr {
	my($ij, $act, @keys) = (@_,'sendto');
	my $out = "<$act->{type}";
	for my $key (@keys) {
		next unless exists $act->{$key};
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key}) 
	}
	$out;
}

sub ssend {
	my($ij, $act) = @_;
	my $out = "<$act->{type}";
	for my $key (sort keys %$act) {
		next if $key eq 'type' || $key eq 'except';
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key}) 
	}
	$out.'>';
}

sub ignore { (); }

my %to_ij = (
	NETLINK => sub {
		my($ij, $act) = @_;
		return '' if $act->{net}->isa('Interface');
		my $out = send_hdr(@_, qw/sendto/) . ' net=<s';
		$out .= $act->{net}->to_ij($ij);
		$out . '>>';
	}, LSYNC => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/dst linkto/) . ' chan=<c';
		$out .= $act->{chan}->to_ij($ij);
		$out . '>>';
	}, LINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/chan1 chan2/) . ' dst=<c';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, CONNECT => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/net/) . ' dst=<n';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, NICK => sub {
		send_hdr(@_,qw/dst nick/) . '>';
	},
	PING => \&ssend,
	PONG => \&ssend,
);

sub debug_send {
	my $ij = $INST_DBG;
	for my $act (@_) {
		my $type = $act->{type};
		print "\e[0;33m    ACTION ";
		if (exists $to_ij{$type}) {
			print $to_ij{$type}->($ij, $act);
		} else {
			print ssend($ij, $act);
		}
		print "\e[0m\n";
	}
}

	$pong[$$ij] = time;
		$ij->ij_send({ type => 'PONG', sendto => [] });
	} elsif ($auth[$$ij]) {
		my $id = $id[$$ij];
			$act->{net} = $ij;
			$act->{sendto} = [];
		delete $Janus::ijnets{$id};
	return ();
1;
