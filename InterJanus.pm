package InterJanus;
use strict;
use warnings;
use Nick;

my %fromirc;
my %toirc;

sub new {
	my %j;
	bless \%j, $_[0];
}

sub str {
	$_[1]->{linkname};
}

sub intro {
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
		return 'c:'.$itm->keyname();
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->id();
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
		next if $key eq 'type';
		$out .= ' '.$key.'='.$ij->ijstr($act->{$key}) 
	}
	$out.'>';
}

sub ignore { (); }

my %to_ij = (
	NETLINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/sendto/) . ' net=<s';
		$out .= $act->{net}->to_ij($ij);
		$out .= '>>';
	}, LSYNC => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/dst linkto/) . ' chan=<c';
		$out .= $act->{chan}->to_ij($ij);
		$out . '>>';
	}, LINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/chan1 chan2/) . ' chan=<c';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, CONNECT => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/net/) . ' nick=<n';
		$out .= $act->{dst}->to_ij($ij);
		$out . '>>';
	}, NICK => sub {
		send_hdr(@_,qw/dst nick/) . '>';
	},
	QUIT => \&ssend,
	KILL => \&ssend,
	NICKINFO => \&ssend,
	UMODE => \&ssend,
	MODE => \&ssend,
	JOIN => \&ssend,
	PART => \&ssend,
	KICK => \&ssend,
	TOPIC => \&ssend,
	MSG => \&ssend,
	WHOIS => \&ssend,
	LINKREQ => \&ssend,
	DELINK => \&ssend,
	LINKED => \&ssend,
	NETSPLIT => \&ssend,

	RECONNECT => \&ssend, # should never be send over an IJ link
);

sub ij_send {
	my $ij = shift;
	my @out;
	for my $act (@_) {
		my $type = $act->{type};
		if (exists $to_ij{$type}) {
			push @out, $to_ij{$type}->($ij, $act);
		} else {
			if ($act->{sendto} && !@{$act->{sendto}}) {
				push @out, '(debug)' . ssend($ij, $act);
			} else {
				print "Unknown action type '$type'\n";
			}
		}
	}
	print "    OUT\@IJ $_\n" for @out;
#	$ij->{sock}->print(map "$_\r\n", @out);
}

sub parse {
	my $ij = shift;
	local $_ = $_[0];

	s/^\s*<(\S+)// or do {
		warn "bad line: $_";
		return ();
	};
	my $act = { type => $1 };
	$ij->_kv_pairs($act);
	warn "bad line: $_[0]" unless /^\s*>\s*$/;
	$act;
}

my %v_type; %v_type = (
	' ' => sub {
		undef;
	}, '"' => sub {
		s/^"([^"]*)"//;
		my $v = $1;
		$v =~ s/\\(.)/$esc2char{$1}/g;
		$v;
	}, 'n' => sub {
		my $ij = shift;
		s/^n:(\S+)~([^ >]+)// or return undef;
		$ij->{nets}->{$1}->nick($2);
	}, 'c' => sub {
		my $ij = shift;
		s/^c:(\S+)(#[^ >]*)// or return undef;
		$ij->{nets}->{$1}->chan($2,0);
	}, 's' => sub {
		my $ij = shift;
		s/^s:(\S+)// or return undef;
		$ij->{nets}->{$1};
	}, '<a' => sub {
		my $ij = shift;
		my @arr;
		s/^<a// or warn;
		while (s/^\s+//) {
			my $v_t = substr $_,0,1;
			$v_t = substr $_,0,2 if $v_t eq '<';
			push @arr, $v_type{$v_t}->($ij);
		}
		s/^>// or warn;
		\@arr;
	}, '<h' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		$h;
	}, '<s' => sub {
		my $ij = shift;
		my $h = {};
		s/^<s// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		RemoteNetwork->from_ij($ij, $h);
	}, '<c' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		Channel->from_ij($ij, $h);
	}, '<n' => sub {
		my $ij = shift;
		my $h = {};
		s/^<h// or warn;
		$ij->_kv_pairs($h);
		s/^>// or warn;
		Nick->from_ij($ij, $h);
	},
);


sub _kv_pairs {
	my($ij, $h) = @_;
	while (s/^\s+(\S+)=//) {
		my $k = $1;
		my $v_t = substr $_,0,1;
		$v_t = substr $_,0,2 if $v_t eq '<';
		$v_type{$v_t}->($ij);
	}
}

1;
