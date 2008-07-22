package Commands;
use strict;

opendir my $cmd, 'src/Commands' or die;
while ($_ = readdir $cmd) {
	s/\.pm$// or next;
	next if $_ eq '*' || !$_;
	&Janus::reload("Commands::$_");
}
closedir $cmd;

1;
