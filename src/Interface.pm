# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Interface;
use Network;
use Nick;
use Persist 'Network';
use strict;
use warnings;

=over

=item $Interface::janus - Nick

Nick object representing the janus interface bot.

=cut

our $janus;   # Janus interface bot: this module handles interactions with this bot
our $network;

sub pmsg {
	my $act = shift;
	my $src = $act->{src};
	my $dst = $act->{dst};
	my $type = $act->{msgtype};
	return 1 unless ref $src && ref $dst;

	if ($type eq '312') {
		# server whois reply message
		my $nick = $act->{msg}->[0];
		if ($src->isa('Network') && ref $nick && $nick->isa('Nick')) {
			return undef if $src->jlink();
			&Event::append(+{
				type => 'MSG',
				msgtype => 640,
				src => $src,
				dst => $dst,
				msg => [
					$nick,
					'is connected through a Janus link. Home network: '.$src->netname().
					'; Home nick: '.$nick->homenick(),
				],
			});
		} else {
			warn "Incorrect /whois reply: $src $nick";
		}
		return undef;
	} elsif ($type eq '313') {
		# remote oper - change message type
		$act->{msgtype} = 641;
		$act->{msg}->[-1] .= ' (on remote network)';
		return 0;
	}
	return 1 if $type eq '310'; # available for help

	if ($$src == 1 && ref $act->{except}) {
		my $srcj = $act->{except}->id;
		delete $act->{IJ_RAW};
		$act->{msg} = "\@$srcj $act->{msg}" unless $act->{msg} =~ /^@/;
	}

	return undef unless $src->isa('Nick') && $dst->isa('Nick');
	if ($$dst == 1) {
		if ($act->{msg} =~ /^@(\S+)\s*/) {
			my $rto = $Janus::ijnets{$1};
			if ($rto) {
				$act->{sendto} = $rto;
			} elsif ($1 eq $RemoteJanus::self->id) {
				delete $act->{sendto};
			} else {
				&Interface::jmsg($src, 'Network not found') if $act->{msgtype} eq 'PRIVMSG';
				return 1;
			}
		}
		return 0;
	}

	unless ($$src == 1 || $src->is_on($dst->homenet())) {
		&Interface::jmsg($src, 'You must join a shared channel to speak with remote users') if $act->{msgtype} eq 'PRIVMSG';
		return 1;
	}
	undef;
}

&Event::hook_add(
	'INIT' => act => sub {
		$network = Interface->new(
			id => 'janus',
			gid => 'janus',
		);
		$network->_set_netname('Janus');
		&Event::append(+{
			type => 'NETLINK',
			net => $network,
		});

		my $inick = $Conffile::netconf{set}{janus_nick} || 'janus';

		$janus = Nick->new(
			net => $network,
			gid => 'janus:1',
			nick => $inick,
			ts => ($^T - 1000000000),
			info => {
				ident => ($Conffile::netconf{set}{janus_ident} || 'janus'),
				host => ($Conffile::netconf{set}{janus_rhost} || 'services.janus'),
				vhost => ($Conffile::netconf{set}{janus_host} || 'service'),
				name => 'Janus Control Interface',
				opertype => 'Janus Service',
				noquit => 1,
			},
			mode => { oper => 1, service => 1, bot => 1 },
		);
		warn if $$janus != 1;
		&Event::append(+{
			type => 'NEWNICK',
			dst => $janus,
		});
	}, KILL => act => sub {
		my $act = shift;
		return unless $act->{dst} eq $janus;
		&Event::append(+{
			type => 'CONNECT',
			dst => $act->{dst},
			net => $act->{net},
		});
	}, KICK => 'act:-1' => sub {
		my $act = shift;
		return unless $act->{kickee} eq $janus;
		my $chan = $act->{dst};
		return unless grep { $_ == $janus } $chan->all_nicks;
		&Event::append({
			type => 'JOIN',
			dst => $chan,
			src => $janus,
		});
	},
	MSG => parse => \&pmsg,
	INVITE => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		my $chan = $act->{to};
		unless ($src->is_on($dst->homenet)) {
			&Interface::jmsg($src, 'You cannot /invite a user unless you are on a channel on their network');
			return 1;
		}
		unless ($chan->is_on($dst->homenet)) {
			&Interface::jmsg($src, 'You cannot /invite a user to a channel not on their network');
			return 1;
		}
		undef;
	},
	WHOIS => parse => sub {
		my $act = shift;
		my $src = $act->{src};
		my $dst = $act->{dst};
		return undef if $src->is_on($dst->homenet()) || $$dst == 1;
		&Interface::jmsg($src, 'You cannot use this /whois syntax unless you are on a shared channel with the user');
		return 1;
	}, CHATOPS => parse => sub {
		my $act = shift;
		if ($act->{except} && $act->{except}->isa('RemoteJanus')) {
			delete $act->{IJ_RAW};
			if ($act->{src} == $janus) {
				$act->{msg} = '['.$act->{except}->id().'] '.$act->{msg};
			}
		}
		undef;
	}, BURST => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		return if $janus->is_on($net);
		&Event::append(+{
			type => 'CONNECT',
			dst => $janus,
			net => $net,
		});
	},
);

sub parse { () }
sub send {
	my $net = shift;
	for my $act (@_) {
		if ($act->{type} eq 'MSG' && $act->{msgtype} eq 'PRIVMSG') {
			my $src = $act->{src};
			my $dst = $act->{dst};
			next if !$src || $src == $janus;
			my @args;
			if ($dst == $janus) {
				$dst = $src;
				$_ = $act->{msg};
				s/^\s*@\S+\s+//;
				@args = split /\s+/, $_;
			} elsif ($dst->isa('Channel') && $dst->get_mode('jcommand')) {
				$_ = $act->{msg};
				my $id = $RemoteJanus::self->id;
				s/^([!.]|\@$id\s+)// or next;
				next if $1 eq '.' && $src->jlink;
				@args = split /\s+/, $_;
			} else {
				next;
			}
			&Event::in_command($src, $dst, @args);
		} elsif ($act->{type} eq 'WHOIS' && $act->{dst} == $janus) {
			my $src = $act->{src} or next;
			my $net = $src->homenet();
			my @msgs = (
				[ 311, $janus->info('ident'), $janus->info('vhost'), '*', $janus->info('name') ],
				[ 312, 'janus.janus', "Janus Interface" ],
				[ 319, join ' ', map { $_->is_on($net) ? $_->str($net) : () } $janus->all_chans() ],
				[ 317, 0, $^T, 'seconds idle, signon time'],
				[ 318, 'End of /WHOIS list' ],
			);
			&Event::append(map +{
				type => 'MSG',
				src => $net,
				dst => $src,
				msgtype => $_->[0], # first part of message
				msg => [$janus, @$_[1 .. $#$_] ], # source nick, rest of message array
			}, @msgs);
		} elsif ($act->{type} eq 'TSREPORT') {
			my $src = $act->{src} or next;
			Event::append({
				type => 'MSG',
				src => $src->homenet,
				dst => $src,
				msgtype => 'NOTICE',
				msg => 'Time on '.$RemoteJanus::self->id.'.janus is '.gmtime($Janus::time)." ($Janus::time)",
			});
		}
	}
}
sub request_newnick { $_[2] }
sub request_cnick { $_[2] }
sub release_nick { }
sub is_synced { 0 }
sub all_nicks { $janus }
sub all_chans { values %Janus::gchans }

sub chan {
	$Janus::gchans{$_[1]};
}

sub replace_chan {
	my $new = $_[2];
	&Log::debug("Replace channel $_[1]");
	if ($_[2] && 2 > scalar $_[2]->nets) {
		Event::append({
			type => 'PART',
			dst => $new,
			src => $janus,
			msg => 'Unlinked',
		});
	}
	();
}

=item Interface::jmsg($dst, $msg,...)

Send the given message(s), sourced from the janus interface,
to the given destination

=cut

sub jmsg {
	my $dst = shift;
	return unless $dst && ref $dst;
	my $type =
		$dst->isa('Nick') ? 'NOTICE' :
		$dst->isa('Channel') ? 'PRIVMSG' : '';
	return unless $type;
	local $_;
	my @o;
	for my $line (@_) {
		$_ = $line;
		push @o, $1 while s/^(.{400,450})\s+/ / or s/^(.{450})/ /;
		push @o, $_;
	}
	&Event::insert_full(map +{
		type => 'MSG',
		src => $Interface::janus,
		dst => $dst,
		msgtype => $type,
		msg => $_,
	}, @o);
}

sub msgtable {
	my($dst, $table, $cols) = @_;
	$cols ||= 1;
	my @maxw = map 0, @{$table->[0]};
	for my $line (@$table) {
		for my $i (0..$#$line) {
			my $len = length $line->[$i];
			$maxw[$i] = $len if $maxw[$i] < $len;
		}
	}
	my $fmt = join ' ', map '%-'.$_.'s', @maxw;

	my $c = 1 + $#$table / $cols; # height of table
	for my $i (0..($c-1)) {
		jmsg($dst, join ' ', map $_ ? sprintf $fmt, @$_ : '',
			map $table->[$c*$_ + $i], 0 .. ($cols-1));
	}
}

1;
