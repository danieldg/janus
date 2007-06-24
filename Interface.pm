# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Interface; {
use Object::InsideOut qw(Network);
use Nick;
use strict;
use warnings;

sub modload {
	my $class = shift;
	my $inick = shift || 'janus';

	my $int = Interface->new(
		id => 'janus',
	);
	$int->_set_netname('Janus');
	&Janus::link($int);

	$Janus::interface = Nick->new(
		net => $int,
		nick => $inick,
		ts => 100000000,
		info => {
			ident => 'janus',
			host => 'services.janus',
			vhost => 'services',
			name => 'Janus Control Interface',
			_is_janus => 1,
		},
		mode => { oper => 1, service => 1, bot => 1 },
	);
	
	&Janus::hook_add($class, 
		LINKED => act => sub {
			my $act = shift;
			my $net = $act->{net};
			return if $net->jlink();
			&Janus::append(+{
				type => 'CONNECT',
				dst => $Janus::interface,
				net => $net,
			});
		}, NETSPLIT => act => sub {
			my $act = shift;
			$Janus::interface->_netpart($act->{net});
		}, MSG => parse => sub {
			my $act = shift;
			my $src = $act->{src};
			my $dst = $act->{dst};
			my $type = $act->{msgtype};
			
			if ($type == 312) {
				# server whois reply message
				if ($src->isa('Network')) {
					&Janus::append(+{
						type => 'MSG',
						msgtype => 640,
						src => $src,
						dst => $dst,
						msg => [
							$act->{msg}->[0],
							"is connected through a Janus link. Home network: ".$src->netname(),
						],
					});
				} else {
					warn "Source of /whois reply is not a server";
				}
				return undef;
			} elsif ($type == 313) {
				# remote oper - change message type
				$act->{msgtype} = 641;
				$act->{msg}->[-1] .= ' (on remote network)';
				return 0;
			}
			return 1 if $type == 310; # available for help

			return undef unless $src->isa('Nick') && $dst->isa('Nick');
			if ($dst->info('_is_janus')) {
				return 1 if $act->{msgtype} != 1 || !$src;
				local $_ = $act->{msg};
				my $cmd = s/^\s*(\S+)\s*// ? lc $1 : 'unk';
				&Janus::in_command($cmd, $src, $_);
				return 1;
			}
			
			unless ($src->is_on($dst->homenet())) {
				&Janus::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} == 1;
				return 1;
			}
			undef;
		}, WHOIS => parse => sub {
			my $act = shift;
			my $src = $act->{src};
			my $dst = $act->{dst};
			unless ($src->is_on($dst->homenet())) {
				&Janus::jmsg($src, 'You cannot use this /whois syntax unless you are on a shared channel with the user');
				return 1;
			}
			undef;
		}, LINKREQ => act => sub {
			my $act = shift;
			my $snet = $act->{net};
			my $dnet = $act->{dst};
			print "Link request:";
			if ($dnet->jlink()) { 
				print " dst non-local";
			} else {
				my $recip = $dnet->is_req($act->{dlink}, $snet);
				print $recip ? " dst req:$recip" : " dst new req";
				$recip = 'any' if $recip && $act->{override};
				if ($act->{linkfile}) {
					if ($dnet->is_synced()) {
						print '; linkfile: override';
						$recip = 'any';
					} else {
						$recip = '';
						print '; linkfile: not synced';
					}
				}
				if ($recip && ($recip eq 'any' || lc $recip eq lc $act->{slink})) {
					print " => LINK OK!\n";
					# there has already been a request to link this channel to that network
					# also, if it was not an override, the request was for this pair of channels
					$dnet->del_req($act->{dlink}, $snet);
					&Janus::append(+{
						type => 'LSYNC',
						src => $dnet,
						dst => $snet,
						chan => $dnet->chan($act->{dlink},1),
						linkto => $act->{slink},
					});
					# do not add it to request list now
					return;
				}
			}
			if ($snet->jlink()) {
				print "; src non-local\n";
			} else {
				$snet->add_req($act->{slink}, $dnet, $act->{dlink});
				print "; added to src requests\n";
			}
		},
	);
	&Janus::command_add({
		cmd => 'info',
		help => 'provides information about janus, including a link to the complete source code',
		code => sub {
			my $nick = shift;
			&Janus::jmsg($nick, 
				'Janus is a server that allows IRC networks to share certain channels to other',
				'linked networks without needing to share all channels and make all users visible',
				'across both networks. If configured to allow it, users can also share their own',
				'channels across any linked network.',
				'-------------------------',
				'The source code can be found at http://danieldegraaf.afraid.org/janus/trunk/',
				'This file was checked out from the $URL$ $Rev$;',
				'the rest of the project may be at a later revision within this respository.',
				'If you make any modifications to this software, you must change these URLs',
				'to one which allows downloading the version of the code you are running.'
			);
		}
	}, {
		cmd => 'list',
		help => 'shows a list of the linked networks and shared channels',
		code => sub {
			my $nick = shift;
			return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
			&Janus::jmsg($nick, 'Linked networks: '.join ' ', sort keys %Janus::nets);
			my $hnet = $nick->homenet();
			my @chans;
			for my $chan ($hnet->all_chans()) {
				my @nets = $chan->nets();
				next if @nets == 1;
				my $list = ' '.$chan->str($hnet);
				for my $net (sort @nets) {
					next if $net->id() eq $hnet->id();
					$list .= ' '.$net->id().$chan->str($net);
				}
				push @chans, $list;
			}
			&Janus::jmsg($nick, sort @chans);
		}
	}, {
		cmd => 'link',
		help => 'link $localchan $network $remotechan - links a channel with a remote network',
		code => sub {
			my $nick = shift;
			
			if ($nick->homenet()->param('oper_only_link') && !$nick->has_mode('oper')) {
				&Janus::jmsg($nick, "You must be an IRC operator to use this command");
				return;
			}

			my($cname1, $nname2, $cname2) = /(#\S+)\s+(\S+)\s*(#\S+)?/ or do {
				&Janus::jmsg($nick, 'Usage: link $localchan $network $remotechan');
				return;
			};

			my $net1 = $nick->homenet();
			my $net2 = $Janus::nets{lc $nname2} or do {
				&Janus::jmsg($nick, "Cannot find network $nname2");
				return;
			};
			my $chan1 = $net1->chan($cname1,0) or do {
				&Janus::jmsg($nick, "Cannot find channel $cname1");
				return;
			};
			unless ($chan1->has_nmode(n_owner => $nick) || $nick->has_mode('oper')) {
				&Janus::jmsg($nick, "You must be a channel owner to use this command");
				return;
			}
		
			&Janus::append(+{
				type => 'LINKREQ',
				src => $nick,
				dst => $net2,
				net => $net1,
				slink => $cname1,
				dlink => ($cname2 || 'any'),
				sendto => [ $net2 ],
				override => $nick->has_mode('oper'),
			});
			&Janus::jmsg($nick, "Link request sent");
		}
	}, {
		cmd => 'delink',
		help => 'delink $chan - delinks a channel from all other networks',
		code => sub {
			my($nick, $cname) = @_;
			my $snet = $nick->homenet();
			if ($snet->param('oper_only_link') && !$nick->has_mode('oper')) {
				Janus::jmsg($nick, "You must be an IRC operator to use this command");
				return;
			}
			my $chan = $snet->chan($cname) or do {
				Janus::jmsg($nick, "Cannot find channel $cname");
				return;
			};
			unless ($nick->has_mode('oper') || $chan->has_nmode(n_owner => $nick)) {
				Janus::jmsg($nick, "You must be a channel owner to use this command");
				return;
			}
				
			&Janus::append(+{
				type => 'DELINK',
				src => $nick,
				dst => $chan,
				net => $snet,
			});
		},
	}, {
		cmd => 'rehash',
		help => 'reload the config and attempt to reconnect to split servers',
		code => sub {
			my $nick = shift;
			return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
			&Janus::append(+{
				src => $nick,
				type => 'REHASH',
				sendto => [],
			});
		},
	}, {
		cmd => 'netsplit',
		help => 'cause a network split and automatic rehash',
		code => sub {
			my $nick = shift;
			return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
			my $net = $Janus::nets{lc $_} or return;
			&Janus::delink($net, 'Forced split by '.$nick->homenick().' on '.$nick->homenet()->id());
			&Janus::append(+{
				type => 'REHASH',
				sendto => [],
			});
		},
	});
}

sub parse { () }
sub send { }

} 1;
