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
	} elsif ('HASH' eq ref $itm || 'ARRAY' eq ref $itm) {
		return 'i:'.$itm;
	} elsif ($itm->isa('Nick')) {
		return 'n:'.$itm->id();
	} elsif ($itm->isa('Channel')) {
		return 'c:'.$itm->{keyname};
	} elsif ($itm->isa('Network')) {
		return 's:'.$itm->id();
	} else {
		warn "Unknown object $itm";
		return '""';
	}
}

sub ssend {
	my($ij, $act) = @_;
	local $_;
	my $out = "<$act->{type}";
	for (sort keys %$act) {
		next if $_ eq 'sendto' || $_ eq 'type';
		$out .= ' '.$_.'='.$ij->ijstr($act->{$_}) 
	}
	$out.'/>';
}

sub ignore { (); }

my %to_ij = (
	NETLINK => sub {
		ssend(@_); # TODO
	}, LINK => sub {
		ssend(@_); # TODO
	}, CONNECT => sub {
		my($ij, $act) = @_;
		my $nick = $act->{dst};
		my $out = '<CONNECT net='.$ij->ijstr($act->{net}).'><N:INFO';
		$out .= ' '.$_.'='.$ij->ijstr($nick->{$_}) for
			qw/homenet homenick nickts ident host ip name vhost/;
		$out .= '/><N:MODE';
		$out .= ' '.$_ for sort keys %{$nick->{mode}};
		$out .= '/><N:NETS';
		$out .= ' '.$ij->ijstr($_) for sort values %{$nick->{nets}};
		$out .= '/></CONNECT>';
		$out;
	}, NICK => sub {
		my($ij, $act) = @_;
		'<NICK dst='.$ij->ijstr($act->{dst}).' nick='.$ij->ijstr($act->{nick}).'/>';
	}, UMODE => sub {
		my($ij, $act) = @_;
		my $out = '<UMODE dst='.$ij->ijstr($act->{dst}).'><N:MODES';
		$out .= ' '.$_ for @{$act->{mode}};
		$out .= '/></UMODE>';
		$out;
	}, MODE => sub {
		my($ij, $act) = @_;
		my $out = '<MODE';
		$out .= ' '.$_.'='.$ij->ijstr($act->{$_}) for qw/src dst/;
		$out .= '><C:MODES';
		$out .= ' '.$_ for @{$act->{mode}};
		$out .= '/><C:MARGS';
		$out .= ' '.$ij->ijstr($_) for @{$act->{args}};
		$out .= '/></MODE>';
		$out;
	}, JOIN => sub {
		my($ij, $act) = @_;
		my $out = '<JOIN';
		$out .= ' '.$_.'='.$ij->ijstr($act->{$_}) for qw/src dst/;
		if ($act->{mode}) {
			$out .= '><C:MODES';
			$out .= ' '.$_ for sort keys %{$act->{mode}};
			$out .= '/></JOIN>';
		} else {
			$out .= '/>';
		}
		$out;
	},
	QUIT => \&ssend,
	KILL => \&ssend,
	NICKINFO => \&ssend,
	PART => \&ssend,
	KICK => \&ssend,
	TOPIC => \&ssend,
	MSG => \&ssend,
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
