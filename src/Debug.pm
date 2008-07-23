# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Debug;
use strict;
use warnings;
use Log;

our $AUTOLOAD;
sub AUTOLOAD {
	my $i = $AUTOLOAD;
	$i =~ s/Debug::/Log::/;
	$Log::AUTOLOAD = $i;
	goto &Log::AUTOLOAD;
}

1;
