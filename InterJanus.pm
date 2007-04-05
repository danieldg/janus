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

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	print "IN\@$net->{id} $line";
	();
}

my %esc2char = (
	e => '\\',
	g => '>',
	l => '<',
	n => "\n",
	q => '"',
	s => '/',
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
		return 'n:'.$itm->id();
	} elsif ($itm->isa('Channel')) {
		return 'c:'.$itm->{keyname};
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
		ssend(@_); # TODO
	}, LSYNC => sub {
		ssend(@_); # TODO
	}, LINK => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/chan1 chan2/) . ' chan=<c';
		my $chan = $act->{dst};
		$out .= ' '.$_.'='.$ij->ijstr($chan->{$_}) for
			qw/ts topic topicts topicset mode nets names/;
		$out . '>>';
	}, CONNECT => sub {
		my($ij, $act) = @_;
		my $out = send_hdr(@_, qw/net/) . ' nick=<n';
		my $nick = $act->{dst};
		$out .= ' '.$_.'='.$ij->ijstr($nick->{$_}) for
			qw/homenet homenick nickts ident host ip name vhost mode nets/;
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
	LINKREQ => \&ssend,
	DELINK => \&ssend,
	NETSPLIT => \&ssend,
);

sub ij_send {
	my $ij = shift;
	my @out;
	for my $act (@_) {
		my $type = $act->{type};
		if (exists $to_ij{$type}) {
			push @out, $to_ij{$type}->($ij, $act);
		} else {
			next if $act->{sendto} && !@{$act->{sendto}};
			print "Unknown action type '$type'\n";
		}
	}
	print "OUT\@IJ $_\n" for @out;
#	$ij->{sock}->print(map "$_\r\n", @out);
}

1;
