# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Eval;
use strict;
use warnings;
use Data::Dumper;

&Janus::command_add({
	cmd => 'eval',
	help => "Evaluates a perl expression. \002DANGEROUS\002",
	section => 'Admin',
	acl => 'eval',
	code => sub {
		my($src, $dst, @expr) = @_;
		my $expr = join ' ', @expr;
		print "EVAL: $expr\n";
		&Log::audit('EVAL by '.$src->netnick.': '.$expr);
		$expr =~ /(.*)/; # go around taint mode
		$expr = $1;
		my @r = eval $expr;
		@r = $@ if $@ && !@r;
		if (@r) {
			$_ = eval { Data::Dumper::Dumper(\@r); };
			s/\n//g;
			&Janus::jmsg($dst, $_);
		}
	},
});

1;
