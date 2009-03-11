# Copyright (C) 2007-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ShowItem;
use strict;
use warnings;

Event::hook_add(
	INFO => Nick => sub {
		my($dst, $n, $asker) = @_;
		my $all = Account::acl_check($asker, 'info/nick') || $asker == $n;
		Janus::jmsg($dst, join ' ', "\002Nick\002",$$n,$n->homenick,'on',$n->homenet->name,$n->gid);
		if ($all) {
			Janus::jmsg($dst, join ' ', "\002Mode:\002", $n->umodes);
			Janus::jmsg($dst, join ' ', "\002Channels:\002", map $_->netname, $n->all_chans);
			my @ifokeys = sort keys %{$Nick::info[$$n]};
			Janus::jmsg($dst, join ' ', '', map $_.'='.$n->info($_), @ifokeys);
		}
		Janus::jmsg($dst, join ' ', "\002Nicks:\002",
			sort map { "\002".$_->name.":\002".$n->str($_).($all ? '@'.$n->ts($_) : '') }
				grep { $_->isa('LocalNetwork') }
				$n->netlist);
	},
	INFO => Channel => sub {
		my($dst, $c, $asker) = @_;
		my $all = Account::chan_access_chk($asker, $c, 'info', undef);
		my $any = $all || scalar grep { $_ == $c } $asker->all_chans;
		my $hn = $asker->homenet;

		Janus::jmsg($dst, join ' ', "\002Channel\002",$$c,$c->real_keyname,'on',$c->homenet->name,
			$c->ts.'='.gmtime($c->ts));
		Janus::jmsg($dst, join ' ', "\002Names:\002", sort map { '@'.$_->name.'='.$c->str($_) } $c->nets);
		return unless $any;
		Janus::jmsg($dst, "\002Topic:\002 ".$c->topic) if defined $c->topic;

		if ($all) {
			my $modeh = $c->all_modes();
			unless ($modeh && scalar %$modeh) {
				Janus::jmsg($dst, "No modes set");
				return;
			}
			my $out = '';
			for my $mk (sort keys %$modeh) {
				my $t = Modes::mtype($mk);
				my $mv = $modeh->{$mk};
				if ($t eq 'r') {
					$out .= ' '.$mk.('+'x($mv - 1));
				} elsif ($t eq 'v') {
					$out .= ' '.$mk.'='.$mv;
				} elsif ($t eq 'l') {
					$out .= join ' ', '', $mk.'={', @$mv, '}';
				} else {
					Log::err("bad mode $mk:$mv - $t?\n");
				}
			}
			Janus::jmsg($dst, "\002Modes:\002".$out);
			if ($hn->isa('LocalNetwork')) {
				my @modes = Modes::to_multi($hn, Modes::delta(undef, $c), 0, 400);
				Janus::jmsg($dst, join ' ','', @$_) for @modes;
			}
		}

		my %nlist;
		for my $n ($c->all_nicks) {
			my $pfx = Modes::chan_pfx($c, $n);
			my $nick = $n->str($hn) || $n->homenick || '#'.$$n;
			$nick =~ s/(?:\002!(\d+)\002)?$/"\002!".(1 + ($1||0))."\002"/e while $nlist{$nick};
			$nlist{$nick} = $pfx.$nick;
		}
		Janus::jmsg($dst, join ' ',"\002Nicks:\002", map $nlist{$_}, sort keys %nlist);
	},
	INFO => Network => sub {
		my($dst, $n, $asker) = @_;
		Janus::jmsg($dst, join ' ', "\002Network\002",$$n, ref($n), $n->name, $n->gid, $n->netname);
		my @sets;
		for my $set (values %Event::settings) {
			next unless $n->isa($set->{type});
			my $acl = $set->{acl_r};
			next if $acl && !Account::acl_check($asker, $acl);
			my $name = $set->{name};
			my $val = Setting::get($name, $n);
			push @sets, qq{\002$name\002: "$val"};
		}
		Janus::jmsg($dst, join ' ', sort @sets) if @sets;
	},
);


Event::command_add({
	cmd => 'shownick',
	help => 'Shows internal details on a nick',
	section => 'Info',
	aclchk => 'info/nick',
	syntax => '<nick|gid>',
	api => '=src =replyto ?nick ?$',
	code => sub {
		my($src, $dst, $nick, $gid) = @_;
		if ($gid && !$nick) {
			$nick = $Janus::gnicks{$gid} or return Janus::jmsg($dst, 'Cannot find nick by gid');
		}
		if (!$nick) {
			Janus::jmsg($dst, 'Not enough arguments');
			return;
		}
		Event::named_hook('INFO/Nick', $dst, $nick, $src);
	},
}, {
	cmd => 'showchan',
	help => 'Shows internal details on a channel',
	section => 'Info',
	syntax => '<chan|gid>',
	api => '=src =replyto ?chan ?$',
	code => sub {
		my($src, $dst, $chan, $gid) = @_;
		if ($gid && !$chan) {
			$chan = $Janus::gchans{$gid} or return Janus::jmsg($dst, 'Cannot find channel by gid');
		}
		if (!$chan) {
			Janus::jmsg($dst, 'Not enough arguments');
			return;
		}
		Event::named_hook('INFO/Channel', $dst, $chan, $src);
	},
}, {
	cmd => 'shownet',
	help => 'Shows internal details on a network',
	section => 'Info',
	syntax => '<network|gid>',
	code => sub {
		my($src, $dst, $args) = @_;
		my $n = $Janus::nets{$args} || $Janus::gnets{$args};
		return Janus::jmsg($dst, 'Could not find that network') unless $n;
		Event::named_hook('INFO/Network', $dst, $n, $src);
	},
});

1;
