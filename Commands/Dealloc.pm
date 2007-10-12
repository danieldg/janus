# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package Commands::Dealloc;
use strict;
use warnings;
use Scalar::Util qw(blessed weaken);
our($VERSION) = '$Rev$' =~ /(\d+)/;

sub rweak {
	my $v = shift;
	return unless ref $v;
	if (ref $v eq 'ARRAY' || ref $v eq 'Persist::Field') {
		for my $i (@_ || 0..$#$v) {
			if (blessed $v->[$i]) {
				weaken $v->[$i];
			} else {
				rweak $v->[$i];
			}
		}
	} elsif (ref $v eq 'HASH') {
		for my $k (keys %$v) {
			if (blessed $v->{$k}) {
				weaken $v->{$k};
			} else {
				rweak $v->{$k};
			}
		}
	} else {
		warn "rweak called on object $v";
	}
}

&Janus::command_add({
	cmd => 'dealloc',
	# no help. You don't want to use this command.
	code => sub {
		my($nick,$args) = @_;
		return &Janus::jmsg($nick, "You must be an IRC operator to use this command") unless $nick->has_mode('oper');
		$args =~ /(\S+) (\S+)/ or return;
		my $pkv = $Persist::vars{$1} or return;
		my $n = $2 + 0 or return;
		for my $ar (values %$pkv) {
			rweak $ar, $n;
		}
	},
});

1;
