package Commands;
use strict;

opendir my $cmd, 'src/Commands' or die;
while ($_ = readdir $cmd) {
	s/\.pm$// or next;
	next if $_ eq '*' || !$_;
	/^([0-9a-zA-Z_]+)$/ or warn "Bad name $_";
	&Janus::reload("Commands::$1");
}
closedir $cmd;

1;
