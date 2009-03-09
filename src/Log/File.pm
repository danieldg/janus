# Copyright (C) 2008-2009 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::File;
use strict;
use warnings;
use integer;
use Log::Base;
use Util::Exec;
use Scalar::Util 'weaken';
use POSIX 'strftime';
use Persist 'Log::Base';

our(@filename, @fh, @rotate, @closeact, @dump);
Persist::register_vars(qw(filename fh rotate closeact dump));
Persist::autoinit(qw(rotate closeact dump));
Janus::static(qw(fh));

for my $rot (@rotate) {
	next unless $rot;
	$rot->{code} = \&rotate;
}

sub rotate {
	my $e = shift;
	my $s = $e->{log};
	if ($s) {
		$s->closelog();
		$s->openlog();
	} else {
		delete $e->{repeat};
	}
}

sub _init {
	my($log, $ifo) = @_;
	if ($rotate[$$log]) {
		my $rotate = {
			repeat => $rotate[$$log],
			code => \&rotate,
			'log' => $log,
		};
		weaken($rotate->{log});
		Event::schedule($rotate);
		$rotate[$$log] = $rotate;
	}
	$log->openlog();
	$filename[$$log];
}

sub _destroy {
	my $log = shift;
	$log->closelog();
	$filename[$$log];
}

sub openlog {
	my $log = shift;
	my $fn = $filename[$$log] = strftime $log->name, gmtime $Janus::time;
	open my $fh, '>', $fn or die $!;
	my $ofh = select $fh; $| = 1; select $ofh;
	$fh[$$log] = $fh;
	if ($dump[$$log] && Janus::load('Snapshot')) {
		for (1..10) {
			open my $dumpto, '>', $fn . '.dump';
			eval {
				Snapshot::dump_to($dumpto);
				1;
			} and last;
		}
	}
}

sub closelog {
	my $log = shift;
	my $fn = $filename[$$log];
	close $fn;
	if ($closeact[$$log] && -f $fn) {
		my $run = $closeact[$$log].' '.$fn;
		$run =~ /(.*)/;
		Util::Exec::system($run);
	}
}

sub output {
	my $log = shift;
	my $fh = $fh[$$log];
	print $fh "\e[$Log::ANSI[$_[0]]m$_[1]: $_[2]\e[m\n";
}

1;
