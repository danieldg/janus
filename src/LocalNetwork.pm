# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package LocalNetwork;
use Network;
use Channel;
use Persist 'Network';
use strict;
use warnings;

our(@cparms, @nickseq);

sub param {
	my $net = shift;
	$Conffile::netconf{$net->name()}{$_[0]};
}

sub cparam {
	$cparms[${$_[0]}]{$_[1]};
}

sub intro {
	my $net = shift;
	$cparms[$$net] = { %{$Conffile::netconf{$net->name()}} };
	$net->_set_numeric($cparms[$$net]->{numeric});
	$net->_set_netname($cparms[$$net]->{netname});
}

sub next_nickgid {
	my $net = shift;
	$net->gid() . ':' . &EventDump::seq2gid(++$nickseq[$$net]);
}

### MODE SPLIT ###
eval($Janus::lmode eq 'Bridge' ? '#line '.__LINE__.' "'.__FILE__.'"'.q[
### BRIDGE MODE ###
&Persist::register_vars(qw(cparms nickseq));

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
	my $old = $chans[$$net]{lc $name};
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

1 ] : '#line '.__LINE__.' "'.__FILE__.'"'.q[
### LINK MODE ###
our @chans;
&Persist::register_vars(qw(cparms chans nickseq));

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

&Janus::hook_add(
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
					&Debug::err("Channel $cn=$$chan not on network $$net as it claims");
					delete $chans[$$net]{$cn};
					next;
				}
				push @clean, +{
					type => 'DELINK',
					dst => $chan,
					net => $net,
					nojlink => 1,
				};
			}
			&Janus::insert_full(@clean);
			for my $chan ($net->all_chans()) {
				$chan->unhook_destroyed();
			}
			warn "channels still remain after double delinks: ".join ',', keys %{$chans[$$net]} if %{$chans[$$net]};
			$chans[$$net] = undef;
		}
	},
);

1 ]) or die $@;

1;
