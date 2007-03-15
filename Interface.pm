package Interface;
use base 'Network';
use Nick;
use strict;
use warnings;

sub new {
	my $class = shift;
	my $inick = shift || 'janus';
	my %neth = (
		id => 'janus',
	);
	my $net = \%neth;
	bless $net, $class;

	my $nick = Nick->new(
		homenet => $net,
		homenick => $inick,
		nickts => 1000,
		ident => 'janus',
		host => 'services.janus',
		name => 'Janus Control Interface',
		umode => 'oS',
	);
	$net->{nicks}->{lc $inick} = $nick;
	$net->{janus} = $nick;
	$net;
}

sub link {
	my($int, $net) = @_;
	my $id = $net->id();
	$int->{nets}->{$id} = $net;
	$int->{janus}->connect($net);
	# TODO send out GLOBOPS on all nets or something
}

my %cmds = (
	unk => sub {
		my($net, $nick, $msg) = @_;
		$nick->send(undef, +{
			type => 'MSG',
			src => $net->{janus},
			dst => $nick,
			notice => 1,
			msg => 'Unknown command. Use "help" to see available commands',
		});
	}, help => sub {
	}, 'link' => sub {
		my($net, $nick) = @_;
		my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)/ or return;
		my $net1 = $nick->{homenet};
		my $net2 = $net->{nets}->{lc $nname2} or return;
		my $chan1 = $net1->chan($cname1, 1);
		my $chan2 = $net2->chan($cname2, 1);
		my $ok = $chan1->link($chan2);
		$nick->send(undef, +{
			type => 'MSG',
			src => $net->{janus},
			dst => $nick,
			notice => 1,
			msg => $ok ? 'Channels linked' : 'Failed to link',
		});
	}
);

sub parse { (); }
sub vhost { 'services' }
sub send {
	my($net, $act) = @_;
	if ($act->{type} eq 'MSG') {
		my $nick = $act->{src};
		return unless $nick;
		local $_ = $act->{msg};
		s/^\s*(\S+)\s*// or return;
		my $cmd = exists $cmds{lc $1} ? lc $1 : 'unk';
		$cmds{$cmd}->($net, $nick, $_);
	}
}
