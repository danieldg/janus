# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Links;
use strict;
use warnings;
use Persist;

our($VERSION) = '$Rev$' =~ /(\d+)/;

our %reqs;
# {requestor}{destination}{src-channel} = dst-channel

&Janus::save_vars('reqs', \%reqs);

&Janus::hook_add(
	LINKED => act => sub {
		my $act = shift;
		my $net = $act->{net};
		return if $net->jlink();
		my $bynet = $reqs{$net->name()} or return;
		keys %$bynet; # reset iterator
		my @acts;
		while (my($nname,$bychan) = each %$bynet) {
			next unless $bychan;
			my $dnet = $Janus::nets{$nname} or next;
			keys %$bychan;
			while (my($src,$dst) = each %$bychan) {
				push @acts, +{
					type => 'LINKREQ',
					net => $net,
					dst => $dnet,
					slink => $src,
					dlink => $dst,
					sendto => [ $dnet ],
					linkfile => 1,
				};
			}
		}
		&Janus::append(@acts);
	}, LINKREQ => act => sub {
		my $act = shift;
		my $snet = $act->{net};
		my $dnet = $act->{dst};
		print "Link request: ";
		$reqs{$snet->name()}{$dnet->name()}{$act->{slink}} = $act->{dlink};
		if ($dnet->jlink() || $dnet->isa('Interface')) {
			print "dst non-local\n";
			return;
		}
		my $recip = $reqs{$dnet->name()}{$snet->name()}{$act->{dlink}};
		unless ($recip) {
			print "saved in list\n";
			return;
		}
		if ($act->{override} || $recip eq 'any' || lc $recip eq lc $act->{slink}) {
			print "linking!\n";
			&Janus::append(+{
				type => 'LSYNC',
				src => $dnet,
				dst => $snet,
				chan => $dnet->chan($act->{dlink},1),
				linkto => $act->{slink},
				linkfile => $act->{linkfile},
			});
		} else {
			print "request not matched\n";
		}
	},
);

1;
