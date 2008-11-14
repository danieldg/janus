# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package LocalNetwork;
use Network;
use Channel;
use Persist 'Network';
use strict;
use warnings;
use constant {
	AUTH_RECV => 1,
	AUTH_SEND => 2,
	AUTH_OK   => 3,
	AUTH_DIR_IN  => 0x4,
	AUTH_DIR_OUT => 0x8,
	AUTH_DIR     => 0xC,
};

our(@cparms, @nickseq, @auth);
Persist::register_vars(qw(cparms nickseq auth));

sub param {
	my $net = shift;
	$Conffile::netconf{$net->name()}{$_[0]};
}

sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub intro {
	my($net,$conf,$peer) = @_;
	$auth[$$net] = $peer ? AUTH_DIR_IN : AUTH_DIR_OUT;
	$cparms[$$net] = { %{$Conffile::netconf{$net->name()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
}

sub next_nickgid {
	my $net = shift;
	$net->gid() . ':' . &EventDump::seq2gid(++$nickseq[$$net]);
}

sub auth_recvd {
	my $net = shift;
	$auth[$$net] |= AUTH_RECV;
}

sub auth_sent {
	my $net = shift;
	$auth[$$net] |= AUTH_SEND;
}

sub auth_ok {
	my $net = shift;
	($auth[$$net] & AUTH_OK) == AUTH_OK;
}

sub auth_should_send {
	my $net = shift;
	return 0 unless $auth[$$net] & AUTH_DIR_OUT || $auth[$$net] & AUTH_RECV;
	return 0 if $auth[$$net] & AUTH_SEND;
	$auth[$$net] |= AUTH_SEND;
	1;
}

### MODE SPLIT ###
eval($Janus::lmode eq 'Bridge' ? '#line '.__LINE__.' "'.__FILE__.'"'.q[#[[]]
### BRIDGE MODE ###

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $Janus::chans{lc $name}) {
		return undef unless $new;
		my $chan = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
		$Janus::chans{lc $name} = $chan;
	}
	$Janus::chans{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	my $old = $Janus::chans{lc $name};
	warn "replacing nonexistant channel" unless $old;
	if (defined $new) {
		$Janus::chans{lc $name} = $new;
	} else {
		delete $Janus::chans{lc $name};
	}
	$old;
}

sub all_chans {
	values %Janus::chans;
}

1 ] : '#line '.__LINE__.' "'.__FILE__.'"'.q[#[[]]
### LINK MODE ###
our @chans;
&Persist::register_vars(qw(chans));

sub _init {
	my $net = shift;
	$chans[$$net] = {};
}

sub chan {
	my($net, $name, $new) = @_;
	unless (exists $chans[$$net]{lc $name}) {
		return undef unless $new;
		my $chan = Channel->new(
			net => $net, 
			name => $name,
			ts => $new,
		);
		$chans[$$net]{lc $name} = $chan;
	}
	$chans[$$net]{lc $name};
}

sub replace_chan {
	my($net,$name,$new) = @_;
	my $old = $chans[$$net]{lc $name};
	warn "replacing nonexistant channel" unless $old;
	if (defined $new) {
		$chans[$$net]{lc $name} = $new;
	} else {
		delete $chans[$$net]{lc $name};
	}
	$old;
}

sub all_chans {
	my $net = shift;
	values %{$chans[$$net]};
}

&Event::hook_add(
	NETSPLIT => cleanup => sub {
		my $act = shift;
		my $net = $act->{net};
		return unless $net->isa('LocalNetwork');
		if (%{$chans[$$net]}) {
			my @clean;
			warn "channels remain after a netsplit, delinking...";
			for my $cn (keys %{$chans[$$net]}) {
				my $chan = $chans[$$net]{$cn};
				unless ($chan->is_on($net)) {
					&Log::err("Channel $cn=$$chan not on network $$net as it claims");
					delete $chans[$$net]{$cn};
					next;
				}
				push @clean, +{
					type => 'DELINK',
					cause => 'split',
					dst => $chan,
					net => $net,
					nojlink => 1,
				};
			}
			&Event::insert_full(@clean);
			for my $chan ($net->all_chans()) {
				$chan->unhook_destroyed();
			}
			warn "channels still remain after double delinks: ".join ',', keys %{$chans[$$net]} if %{$chans[$$net]};
			$chans[$$net] = undef;
		}
	},
	INFO => 'Network:1' => sub {
		my($dst, $net) = @_;
		return unless $net->isa('LocalNetwork');
		my $nickc = scalar $net->all_nicks;
		my $chanc = scalar keys %{$chans[$$net]};
		my $ngid = $net->gid . ':' . &EventDump::seq2gid($nickseq[$$net]);
		&Janus::jmsg($dst, "$nickc nicks, $chanc channels; nick GID $ngid");
	},
);

1 ]) or die $@;

1;
