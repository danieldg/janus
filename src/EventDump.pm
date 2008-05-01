# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package EventDump;
use strict;
use warnings;
use integer;
use Carp;

our $INST ||= do {
	my $no;
	bless \$no;
};

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
	} elsif ($itm->isa('Nick')) {
		return 'n:'.$itm->gid();
	} elsif ($itm->isa('Channel')) {
		return 'c:'.$itm->keyname();
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
	my @out;
	for my $act (@_) {
		unless ($act->{IJ_RAW}) {
			my $thnd = $to_ij{$act->{type}};
			my $raw = $thnd ? $thnd->($INST, $act) : ssend($INST, $act);
			$act->{IJ_RAW} = $raw;
		}
		push @out, $act->{IJ_RAW};
	}
	@out;
}

my $seq_tbl = join '', 0..9, 'a'..'z', 'A'..'Z';

sub seq2gid {
	my $id = shift;
	my $o = '';
	while ($id) {
		$o .= substr $seq_tbl, ($id % 62), 1;
		$id /= 62;
	}
	$o;
}

1;
