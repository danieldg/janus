package Interface;
use base 'Network';
use Nick;
use strict;
use warnings;

my %cmds = (
	unk => sub {
		my($net, $nick, $msg) = @_;
		return +{
			type => 'MSG',
			dst => $nick,
			notice => 1,
			msg => 'Unknown command. Use "help" to see available commands',
		};
	}, unauth => sub {
		my($net, $nick, $msg) = @_;
		return +{
			type => 'MSG',
			dst => $nick,
			notice => 1,
			msg => 'You must be an IRC operator to use this service',
		};
	}, help => sub {
		my($net, $nick) = @_;
		return map +{
			type => 'MSG',
			dst => $nick,
			notice => 1,
			msg => $_,
		}, ('Janus2 Help',
			' link $localchan $network $remotechan - links a channel with a remote network',
			' delink $chan - delinks a channel from all other networks',
		);
	}, 'link' => sub {
		my($net, $nick) = @_;
		my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)/ or return;
		my $net1 = $nick->{homenet};
		my $net2 = $net->{nets}->{lc $nname2} or return;
		my $chan1 = $net1->chan($cname1, 1);
		my $chan2 = $net2->chan($cname2, 1);
		return +{
			type => 'LINK',
			src => $nick,
			chan1 => $chan1,
			chan2 => $chan2,
		};
	}, 'delink' => sub {
		my($net, $nick, $cname) = @_;
		my $snet = $nick->{homenet};
		my $chan = $snet->chan($cname);
		return +{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
		};
	}
);

sub modload {
	my $class = shift;
	my $janus = shift;
	my $inick = shift || 'janus';

	my %neth = (
		id => 'janus',
	);
	my $int = \%neth;
	bless $int, $class;

	$janus->link($int);

	my $nick = Nick->new(
		homenet => $int,
		homenick => $inick,
		nickts => 1000,
		ident => 'janus',
		host => 'services.janus',
		name => 'Janus Control Interface',
		umode => 'oS',
		_is_janus => 1,
	);
	$int->{nicks}->{lc $inick} = $nick;
	$janus->{janus} = $int->{janus} = $nick;
	
	$janus->hook_add($class, 
		NETLINK => act => sub {
			my $net = shift;
			my $id = $net->id();
			$int->{nets}->{$id} = $net;
			my @act = $int->{janus}->connect($net);
			# TODO send out GLOBOPS on all nets or something
			@act;
		}, MSG => parse => sub {
			my $act = shift;
			my $nick = $act->{src};
			my $dst = $act->{dst};
			if ($dst->{_is_janus}) {
				return () unless $nick;
				local $_ = $act->{msg};
				s/^\s*(\S+)\s*// or return;
				my $cmd = exists $cmds{lc $1} ? lc $1 : 'unk';
				$cmd = 'unauth' unless $nick->{mode}->{oper};
				return $cmds{$cmd}->($int, $nick, $_);
			} elsif ($dst->isa('Nick') && !$nick->is_on($dst->{homenet})) {
				return () if $act->{notice};
				return +{
					type => 'MSG',
					notice => 1,
					src => $int->{janus},
					dst => $dst,
					msg => 'You must join a shared channel to speak with remote users',
				}
			}
			return undef;
		}, MSG => postact => sub {
			my $act = shift;
			return undef if defined $act->{src};
			$act->{src} = $int->{janus};
			$act;
		},
	);
}

sub parse { () }
sub vhost { 'services' }
sub send { }
