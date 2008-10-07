# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ShowItem;
use strict;
use warnings;
my @mode_txt = qw{owner admin op halfop voice};
my @mode_sym = qw{~ & @ % +};

&Event::hook_add(
	INFO => Nick => sub {
		my($dst, $n, $asker) = @_;
		my $all = $asker->has_mode('oper') || $asker == $n;
		&Janus::jmsg($dst, join ' ', "\002Nick\002",$$n,$n->homenick,'on',$n->homenet->name,$n->gid,
			$all ? $n->ts.'='.gmtime($n->ts) : ());
		if ($all) {
			&Janus::jmsg($dst, join ' ', "\002Mode:\002", $n->umodes);
			&Janus::jmsg($dst, join ' ', "\002Channels:\002", map $_->real_keyname, $n->all_chans);
			my @ifokeys = sort keys %{$Nick::info[$$n]};
			Janus::jmsg($dst, join ' ', '', map $_.'='.$n->info($_), @ifokeys);
		}
		&Janus::jmsg($dst, join ' ', "\002Nicks:\002", sort map { '@'.$_->name.'='.$n->str($_) } $n->netlist);
	},
	INFO => Channel => sub {
		my($dst, $c, $asker) = @_;
		my $all = $asker->has_mode('oper') || $c->has_nmode(owner => $asker);
		my $hn = $asker->homenet;

		&Janus::jmsg($dst, join ' ', "\002Channel\002",$$c,$c->real_keyname,'on',$c->homenet->name,
			$c->ts.'='.gmtime($c->ts));
		&Janus::jmsg($dst, join ' ', "\002Names:\002", sort map { '@'.$_->name.'='.$c->str($_) } $c->nets);
		&Janus::jmsg($dst, "\002Topic:\002 ".$c->topic);

		if ($all) {
			my $modeh = $c->all_modes();
			unless ($modeh && scalar %$modeh) {
				&Janus::jmsg($dst, "No modes set");
				return;
			}
			my $out = '';
			for my $mk (sort keys %$modeh) {
				my $t = $Modes::mtype{$mk} || '?';
				my $mv = $modeh->{$mk};
				if ($t eq 'r') {
					$out .= ' '.$mk.('+'x($mv - 1));
				} elsif ($t eq 'v') {
					$out .= ' '.$mk.'='.$mv;
				} elsif ($t eq 'l') {
					$out .= join ' ', '', $mk.'={', @$mv, '}';
				} else {
					&Log::err("bad mode $mk:$mv - $t?\n");
				}
			}
			&Janus::jmsg($dst, "\002Modes:\002".$out);
			if ($hn->isa('LocalNetwork')) {
				my @modes = &Modes::to_multi($hn, &Modes::delta(undef, $c), 0, 400);
				&Janus::jmsg($dst, join ' ','', @$_) for @modes;
			}
		}

		my %nlist;
		for my $n ($c->all_nicks) {
			my $pfx = join '', map { $c->has_nmode($mode_txt[$_], $n) ? $mode_sym[$_] : '' } 0..4;
			my $nick = $n->str($hn) || $n->homenick || '#'.$$n;
			$nick =~ s/(?:\002!(\d+)\002)?$/"\002!".(1 + ($1||0))."\002"/e while $nlist{$nick};
			$nlist{$nick} = $pfx.$nick;
		}
		&Janus::jmsg($dst, join ' ',"\002Nicks:\002", map $nlist{$_}, sort keys %nlist);
	},
	INFO => Network => sub {
		my($dst, $n, $asker) = @_;
		&Janus::jmsg($dst, join ' ', "\002Network\002",$$n, ref($n), $n->name, $n->gid, ($n->numeric ? '#'.$n->numeric : ()), $n->netname);
	},
);


&Event::command_add({
	cmd => 'shownick',
	help => 'Shows internal details on a nick',
	section => 'Info',
	details => [
		"\002SHOWNICK\002 [net] nick|gid",
	],
	code => sub {
		my($src, $dst) = @_;
		my $net = @_ > 3 ? $Janus::nets{$_[2]} : $src->homenet;
		my $n = $_[-1];
		if ($n =~ /:/) {
			$n = $Janus::gnicks{$n} or return Janus::jmsg($dst, 'Cannot find nick by gid');
		} elsif ($net->isa('LocalNetwork')) {
			$n = $net->nick($n, 1) or return Janus::jmsg($dst, 'Cannot find nick by name');
		} else {
			return Janus::jmsg($dst, 'Remote networks must be queried by gid');
		}
		&Event::named_hook('INFO/Nick', $dst, $n, $src);
	},
}, {
	cmd => 'showchan',
	help => 'Shows internal details on a channel',
	section => 'Info',
	details => [
		"\002SHOWCHAN\002 [net] chan|gid",
	],
	code => sub {
		my($src, $dst) = @_;
		my $hn = $src->homenet;
		my $net = @_ > 3 ? $Janus::nets{$_[2]} : $hn;
		my $c = $_[-1];
		if ($c =~ /^#/) {
			unless ($net->isa('LocalNetwork')) {
				return Janus::jmsg($dst, 'Remote networks must be queried by gid');
			}
			$c = $net->chan($c, 0) or return Janus::jmsg($dst, 'Cannot find channel by name');
		} else {
			$c = $Janus::gchans{$c} or return Janus::jmsg($dst, 'Cannot find channel by gid');
		}
		&Event::named_hook('INFO/Channel', $dst, $c, $src);
	},
}, {
	cmd => 'shownet',
	help => 'Shows internal details on a network',
	section => 'Info',
	details => [
		"\002SHOWCHAN\002 netid|gid",
	],
	code => sub {
		my($src, $dst, $args) = @_;
		my $n = $Janus::nets{$args} || $Janus::gnets{$args};
		return &Janus::jmsg($dst, 'Could not find that network') unless $n;
		&Event::named_hook('INFO/Network', $dst, $n, $src);
	},
});

1;
