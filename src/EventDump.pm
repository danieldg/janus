# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package EventDump;
use strict;
use warnings;
use SocketHandler;
use Persist 'SocketHandler';
use Nick;
use Channel;
use RemoteNetwork;
use Carp;

my %toirc;

our $INST ||= do {
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
my $chlist = join '', map { /\w/ ? $_ : '\\'.$_ } keys %char2esc;

sub ijstr {
	my($ij, $itm) = @_;
	local $_;
	my $ref = ref $itm;
	if (!defined $itm) {
		return '';
	} elsif (!$ref) {
		$itm =~ s/([$chlist])/\\$char2esc{$1}/g;
		return '"'.$itm.'"';
	} elsif ($ref eq 'ARRAY') {
		my $out = '<a';
		$out .= ' '.$ij->ijstr($_) for @$itm;
		return $out.'>';
	} elsif ($ref eq 'HASH') {
		my $out = '<h';
		$out .= ' '.$_.'='.$ij->ijstr($itm->{$_}) for sort keys %$itm;
		return $out.'>';
	} elsif ($ref eq 'Nick') {
		return 'n:'.$itm->gid();
	} elsif ($ref eq 'Channel') {
		return 'c:'.$itm->keyname();
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->gid();
	} elsif ($itm->isa('RemoteJanus')) {
		return 'j:'.$itm->id();
	} elsif ($itm->isa('Janus')) {
		return 'j:*';
	}
	&Debug::err("Unknown object $itm of type $ref");
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
		next if $key eq 'type' || $key eq 'except' || $key eq 'IJ_RAW';
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
	}, JNETLINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_) . ' net=<j';
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
);

sub debug_send {
	for my $act (@_) {
		my $thnd = $to_ij{$act->{type}};
		if ($thnd) {
			&Debug::action($INST->ssend($act));
		} else {
			$act->{IJ_RAW} ||= $INST->ssend($act);
			&Debug::action($act->{IJ_RAW});
		}
	}
}

sub dump_act {
	my $ij = shift;
	unless ($$ij) {
		carp "Don't use dump_act on \$INST";
		return ();
	}
	my @out;
	for my $act (@_) {
		unless ($act->{IJ_RAW}) {
			my $thnd = $to_ij{$act->{type}};
			my $raw = $thnd ? $thnd->($ij, $act) : $ij->ssend($act);
			$act->{IJ_RAW} = $raw;
		}
		push @out, $act->{IJ_RAW};
	}
	@out;
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
		while (s/^ //) {
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
		unless ($ij->jparent($h->{jlink})) {
			&Janus::delink($ij, "Network misintroduction: $h->{jlink} invalid");
			return undef;
		}
		RemoteNetwork->new(%$h);
	}, '<j' => sub {
		my $ij = shift;
		my $h = {};
		s/^<j// or warn;
		$ij->kv_pairs($h);
		s/^>// or warn;
		my $id = $h->{id};
		my $parent = $h->{parent};
		if ($Janus::ijnets{$id}) {
			&Janus::delink($ij, "InterJanus network name collision: IJ network $h->{id} already exists");
			return undef;
		}
		unless ($ij->jparent($parent)) {
			&Janus::delink($ij, "InterJanus network misintroduction: Parent $parent invalid");
			return undef;
		}
		RemoteJanus->new(parent => $parent, id => $id);
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
		return undef unless ref $h->{net} && $ij->jparent($h->{net}->jlink());
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
