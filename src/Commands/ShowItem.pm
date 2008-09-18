# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::ShowItem;
use strict;
use warnings;
my @mode_txt = qw{owner admin op halfop voice};
my @mode_sym = qw{~ & @ % +};
&Event::command_add({
	cmd => 'shownick',
	help => 'Shows internal details on a nick',
	details => [
		"\002SHOWNICK\002 [net] nick|gid",
	],
	acl => 1,
	code => sub {
		my($src, $dst) = @_;
		my $net = @_ > 3 ? $Janus::nets{$_[2]} : $src->homenet;
		my $n = $_[-1];
		if ($n =~ /:/) {
			$n = $Janus::gnicks{$n} or return Janus::jmsg($src, 'Cannot find nick by gid');
		} elsif ($net->isa('LocalNetwork')) {
			$n = $net->nick($n, 1) or return Janus::jmsg($src, 'Cannot find nick by name');
		} else {
			return Janus::jmsg($src, 'Remote networks must be queried by gid');
		}
		Janus::jmsg($dst, join ' ', "\002Nick\002",$$n,$n->homenick,'on',$n->homenet->name,$n->gid,
			$n->ts.'='.gmtime($n->ts));
		Janus::jmsg($dst, join ' ', "\002Mode:\002", $n->umodes);
		Janus::jmsg($dst, join ' ', "\002Channels:\002", map $_->real_keyname, $n->all_chans);
		Janus::jmsg($dst, join ' ', "\002Nicks:\002", sort map { '@'.$_->name.'='.$n->str($_) } $n->netlist);
		my @ifokeys = sort keys %{$Nick::info[$$n]};
		Janus::jmsg($dst, join ' ', '', map $_.'='.$n->info($_), @ifokeys);
	},
}, {
	cmd => 'showchan',
	help => 'Shows internal details on a channel',
	details => [
		"\002SHOWCHAN\002 [net] chan|gid",
	],
	acl => 1,
	code => sub {
		my($src, $dst) = @_;
		my $hn = $src->homenet;
		my $net = @_ > 3 ? $Janus::nets{$_[2]} : $hn;
		my $c = $_[-1];
		if ($c =~ /^#/) {
			unless ($net->isa('LocalNetwork')) {
				return Janus::jmsg($src, 'Remote networks must be queried by gid');
			}
			$c = $net->chan($c, 0) or return Janus::jmsg($src, 'Cannot find channel by name');
		} else {
			$c = $Janus::gchans{$c} or return Janus::jmsg($src, 'Cannot find channel by gid');
		}
		Janus::jmsg($dst, join ' ', "\002Channel\002",$$c,$c->real_keyname,'on',$c->homenet->name,
			$c->ts.'='.gmtime($c->ts));
		Janus::jmsg($dst, join ' ', "\002Names:\002", sort map { '@'.$_->name.'='.$c->str($_) } $c->nets);
		my %nlist;
		for my $n ($c->all_nicks) {
			my $pfx = join '', map { $c->has_nmode($mode_txt[$_], $n) ? $mode_sym[$_] : '' } 0..4;
			my $nick = $n->str($hn) || $n->homenick || '#'.$$n;
			$nlist{$nick} = $pfx.$nick;
		}
		Janus::jmsg($dst, join ' ','', map $nlist{$_}, sort keys %nlist);
	},
}, {
	cmd => 'shownet',
	help => 'Shows internal details on a network',
	details => [
		"\002SHOWCHAN\002 netid|gid",
	],
	acl => 1,
	code => sub {
		my($src, $dst, $args) = @_;
		my $n = $Janus::nets{$args} || $Janus::gnets{$args};
		return Janus::jmsg($dst, 'Could not find that network') unless $n;
		Janus::jmsg($dst, join ' ', "\002Network\002",$$n, ref($n), $n->name, $n->gid, ($n->numeric ? '#'.$n->numeric : ()), $n->netname);
	},
});

1;
