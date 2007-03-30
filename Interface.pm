package Interface;
use base 'Network';
use Nick;
use strict;
use warnings;

my %cmds = (
	unk => sub {
		my($j, $nick) = @_;
		$j->append(+{
			type => 'MSG',
			src => $j->{janus},
			dst => $nick,
			notice => 1,
			msg => 'Unknown command. Use "help" to see available commands',
		});
	}, unauth => sub {
		my($j, $nick) = @_;
		$j->append(+{
			type => 'MSG',
			src => $j->{janus},
			dst => $nick,
			notice => 1,
			msg => 'You must be an IRC operator to use this service',
		});
	}, help => sub {
		my($j, $nick) = @_;
		$j->jmsg($nick, 'Janus2 Help',
			' link $localchan $network $remotechan - links a channel with a remote network',
			' delink $chan - delinks a channel from all other networks',
		);
	}, list => sub {
		my($j, $nick) = @_;
		$j->jmsg($nick, 'Linked networks: '.join ' ', sort keys %{$j->{nets}});
		# TODO display available channels when that is set up
	}, 'link' => sub {
		# TODO evaluate for jlink nets
		my($j, $nick) = @_;
		my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)/ or do {
			$j->jmsg($nick, 'Usage: link $localchan $network $remotechan');
			return;
		};
		my $net1 = $nick->{homenet};
		my $net2 = $j->{nets}->{lc $nname2} or do {
			$j->jmsg($nick, "Cannot find network $nname2");
			return;
		};
		my $chan1 = $net1->chan($cname1, 1);
		my $chan2 = $net2->chan($cname2, 1);
		$j->append(+{
			type => 'LINK',
			src => $nick,
			chan1 => $chan1,
			chan2 => $chan2,
		});
	}, 'delink' => sub {
		my($j, $nick, $cname) = @_;
		my $snet = $nick->{homenet};
		my $chan = $snet->chan($cname);
		$j->append(+{
			type => 'DELINK',
			src => $nick,
			dst => $chan,
			net => $snet,
		});
	}, 'die' => sub { exit 0 },
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
		nickts => 100000000,
		ident => 'janus',
		host => 'services.janus',
		name => 'Janus Control Interface',
		mode => { oper => 1, service => 1 },
		_is_janus => 1,
	);
	$int->{nicks}->{lc $inick} = $nick;
	$janus->{janus} = $nick;
	
	$janus->hook_add($class, 
		NETLINK => act => sub {
			my($j,$net) = @_;
			my $id = $net->id();
			$j->{nets}->{$id} = $net;
			$j->append(+{
				type => 'CONNECT',
				dst => $j->{janus},
				net => $net,
			});
			# TODO send out GLOBOPS on all nets or something
		}, MSG => parse => sub {
			my($j,$act) = @_;
			my $nick = $act->{src};
			my $dst = $act->{dst};
			if ($dst->{_is_janus}) {
				return 1 unless $nick;
				local $_ = $act->{msg};
				s/^\s*(\S+)\s*// or return;
				my $cmd = exists $cmds{lc $1} ? lc $1 : 'unk';
				$cmd = 'unauth' unless $nick->{mode}->{oper};
				$cmds{$cmd}->($j, $nick, $_);
				return 1;
			} elsif ($dst->isa('Nick') && !$nick->is_on($dst->{homenet})) {
				$j->append(+{
					type => 'MSG',
					notice => 1,
					src => $j->{janus},
					dst => $nick,
					msg => 'You must join a shared channel to speak with remote users',
				}) unless $act->{notice};
				return 1;
			}
			undef;
		},
	);
}

sub parse { () }
sub vhost { 'services' }
sub send { }
