# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package EventDump;
use strict;
use warnings;
use Persist 'SocketHandler';
use Nick;
use Channel;
use RemoteNetwork;

our($VERSION) = '$Rev$' =~ /(\d+)/;

my %toirc;

my $INST = do {
	my $no;
	bless \$no;
};

sub str {
	warn;
	"";
}

my %esc2char = (
	e => '\\',
	g => '>',
	l => '<',
	z => '=',
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
		return ($$ij ? 'c:' : "c($$itm):").$itm->keyname();
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->gid();
	} elsif ($itm->isa('Server::InterJanus')) {
		return 'j:'.$itm->id();
	} elsif ($itm->isa('Janus')) {
		return 'j:'.$itm->gid();
	}
	warn "Unknown object $itm";
	return '""';
}

sub send_hdr {
	my($ij, $act, @keys) = (@_,'sendto');
	my $out = "<$act->{type}";
	for my $key (@keys) {
		next unless exists $act->{$key};
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key});
	}
	$out;
}

sub ssend {
	my($ij, $act) = @_;
	my $out = "<$act->{type}";
	for my $key (sort keys %$act) {
		next if $key eq 'type' || $key eq 'except';
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key});
	}
	$out.'>';
}

sub ignore { (); }

my %to_ij = (
	NETLINK => sub {
		my($ij, $act) = @_;
		return '' if !$act->{net} || $act->{net}->isa('Interface');
		my $out = send_hdr(@_) . ' net=<s';
		$out .= $act->{net}->to_ij($ij);
		$out . '>>';
	}, LOCKACK => sub {
		my($ij, $act) = @_;
		if ($act->{chan}) {
			my $out = send_hdr(@_, qw/src dst expire lockid/) . ' chan=<c';
			$out .= $act->{chan}->to_ij($ij);
			$out . '>>';
		} else {
			&ssend;
		}
	}, LINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_) . ' dst=<c';
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
	InterJanus => \&ssend,
	CHATOPS => \&ssend,
	DELINK => \&ssend,
	JLINKED => \&ssend,
	JNETLINK => \&ssend,
	JNETSPLIT => \&ssend,
	JOIN => \&ssend,
	KICK => \&ssend,
	KILL => \&ssend,
	LINKED => \&ssend,
	LINKREQ => \&ssend,
	LOCKREQ => \&ssend,
	MODE => \&ssend,
	MSG => \&ssend,
	NETSPLIT => \&ssend,
	NICKINFO => \&ssend,
	PART => \&ssend,
	PING => \&ssend,
	PONG => \&ssend,
	QUIT => \&ssend,
	TIMESYNC => \&ssend,
	TOPIC => \&ssend,
	TSREPORT => \&ssend,
	UMODE => \&ssend,
	UNLOCK => \&ssend,
	WHOIS => \&ssend,
);

sub debug_send {
	my $ij = $INST;
	for my $act (@_) {
		my $type = $act->{type};
		print "\e[0;33m    ACTION ";
		print ssend($ij, $act);
		print "\e[0m\n";
	}
}

sub dump_act {
	my $ij = shift;
	my @out;
	for my $act (@_) {
		my $type = $act->{type};
		if (exists $to_ij{$type}) {
			push @out, $to_ij{$type}->($ij, $act);
		} else {
			print "EventDump: unknown action type '$type'\n";
		}
	}
	grep $_, @out; #remove blank lines
}

my %v_type; %v_type = (
	' ' => sub {
		undef;
	}, '>' => sub {
		undef;
	}, '"' => sub {
		s/^"([^"]*)"//;
		my $v = $1;
		$v =~ s/\\(.)/$esc2char{$1}/g;
		$v;
	}, 'n' => sub {
		s/^n:([^ >]+)(:\d+)// or return undef;
		$Janus::gnicks{$1.$2} || $Janus::gnets{$1};
	}, 'c' => sub {
		s/^c:([^ >]+)// or return undef;
		$Janus::gchans{$1};
	}, 's' => sub {
		s/^s:([^ >]+)// or return undef;
		$Janus::gnets{$1};
	}, 'j' => sub {
		s/^j:([^ >]+)// or return undef;
		return $Janus::global if $1 eq '*';
		$Janus::ijnets{$1};
	}, '<a' => sub {
		my @arr;
		s/^<a// or warn;
		while (s/^\s+//) {
			my $v_t = substr $_,0,1;
			$v_t = substr $_,0,2 if $v_t eq '<';
			push @arr, $v_type{$v_t}->(@_);
		}
		s/^>// or warn;
		\@arr;
	}, '<h' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		$h;
	}, '<s' => sub {
		my $ij = shift;
		my $h = {};
		s/^<s// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		if ($Janus::gnets{$h->{gid}} || $Janus::nets{$h->{id}}) {
			# this is a NETLINK of a network we already know about.
			# We either have a loop or a name collision. Either way, the IJ link
			# cannot continue
			&Janus::delink($ij, "InterJanus network name collision: network $h->{id} already exists");
			return undef;
		}
		delete $h->{jlink};
		RemoteNetwork->new(jlink => $ij, %$h);
	}, '<c' => sub {
		my $ij = shift;
		my $h = {};
		s/^<c// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		# this creates a new object every time because LINK will fail if we
		# give it a cached item, and LSYNC needs to create a lot of the time
		Channel->new(%$h);
	}, '<n' => sub {
		my $ij = shift;
		my $h = {};
		s/^<n// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		return undef unless ref $h->{net} &&
			$h->{net}->isa('RemoteNetwork') && $h->{net}->jlink() eq $ij;
		$Janus::gnicks{$h->{gid}} || Nick->new(%$h);
	},
);

sub kv_pairs {
	my($ij, $h) = @_;
	while (s/^\s+(\S+)=//) {
		my $k = $1;
		my $v_t = substr $_,0,1;
		$v_t = substr $_,0,2 if $v_t eq '<';
		return warn "Cannot find v_t for: $_" unless $v_type{$v_t};
		return warn "Duplicate key $k" if $h->{$k};
		$h->{$k} = $v_type{$v_t}->($ij);
	}
}

1;
