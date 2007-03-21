package Janus;
use strict;
use warnings;
# Action levels:
#  parse - possible reparse point (/msg janus *)
#  presend - executed before Janus broadcast (add sync information)
#  --- Action broadcast to other Janus servers
#  preact - Join to all needed networks
#  act - Main processing
#  --- Action sent to ->{sendto} networks
#  postact - Reference deletion (part/quit/etc)

sub new {
	my $class = shift;
	my %j;
	bless \%j, $class;
}

sub hook_add {
	my($j, $module) = (shift, shift);
	while (@_) {
		my ($type, $level, $sub) = (shift, shift, shift);
		warn unless $sub;
		$j->{hook}->{$type}->{$level}->{$module} = $sub;
	}
}

sub hook_del {
	my($j, $module) = @_;
	for my $t (keys %{$j->{hook}}) {
		for my $l (keys %{$j->{hook}->{$t}}) {
			delete $j->{hook}->{$t}->{$l}->{$module};
		}
	}
}

sub _hook {
	my($j, $lvl, $act, $multi) = @_;
	$j->_hook_t($act->{type}, $lvl, $act, $multi);
}

sub _hook_t {
	my($j, $type, $lvl, $act, $multi) = @_;
	local $_;
	my $hook = $j->{hook}->{$type}->{$lvl};
	return $multi ? () : $act unless $hook;

	my $taken = $multi;
	my @out;
	
	for my $mod (sort keys %$hook) {
		my @r = $hook->{$mod}->($act);
		if (@r && !defined $r[0]) {
			# return undef; do nothing
		} else {
			push @out, @r;
			if (!$multi) {
				warn "Multiple modifying hooks for $type:$lvl ($taken, $mod)" if $taken;
				$taken = $mod;
			}
		}
	}
	$taken ? @out : $act;
}

sub _send {
	my($except,$act) = @_;
	my @to = 
		exists $act->{sendto} ? @{$act->{sendto}} :
		$act->{dst}->isa('Network') ? $act->{dst} :
		$act->{dst}->sendto($act, $except);
	# TODO filter out remote nets
	for my $net (@to) {
		$net->send($act);
	}
}

sub link {
	my($j,$net) = @_;
	$j->_hook_t(NETLINK => presend => $net);
	# TODO send
	$j->_hook_t(NETLINK => preact => $net);
	_send undef, $_ for $j->_hook_t(NETLINK => act => $net, 1);
	$j->_hook_t(NETLINK => postact => $net);
}

sub in_net {
	my($j,$src,@act) = @_;
	local $_;
	@act = map { $j->_hook(parse => $_) } @act;
	@act = map { $j->_hook(presend => $_) } @act;
	for (@act) {
		# TODO send to other Janus servers
	}
	@act = map { $j->_hook(preact => $_) } @act;
	@act = map { $j->_hook(act => $_) } @act;
	_send $src, $_ for @act;
	$j->_hook(postact => $_, 1) for @act;
}

sub in_janus {
	my($j,@act) = @_;
	local $_;
	@act = map { $j->_hook(preact => $_) } @act;
	@act = map { $j->_hook(act => $_) } @act;
	_send undef, $_ for @act;
	$j->_hook(postact => $_, 1) for @act;
} 

1;
