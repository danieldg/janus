# Copyright (C) 2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Log::File;
use strict;
use warnings;
use integer;
use Log::Base;
use Scalar::Util 'weaken';
use POSIX 'strftime';
use Persist 'Log::Base';

our(@name, @filename, @fh, @rotate, @closeact, @dump);
&Persist::register_vars(qw(name filename fh rotate closeact dump));
&Persist::autoinit(qw(name rotate closeact dump));

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
		&Janus::schedule($rotate);
		$rotate[$$log] = $rotate;
	}
	$log->openlog();
	$name[$$log];
}

sub _destroy {
	my $log = shift;
	$log->closelog();
	$name[$$log];
}

sub openlog {
	my $log = shift;
	my $fn = $filename[$$log] = strftime $name[$$log], gmtime $Janus::time;
	if ($dump[$$log] && &Janus::load('Commands::Debug')) {
		&Commands::Debug::dump_now("New log $fn", $log);
	}
	open my $fh, '>', $fn or die $!;
	$fh->autoflush(1);
	$fh[$$log] = $fh;
}

sub closelog {
	my $log = shift;
	my $fn = $filename[$$log];
	close $fn;
	if ($closeact[$$log] && -f $fn) {
		fork or do {
			my $run = $closeact[$$log].' '.$fn;
			$run =~ /(.*)/;
			{ exec $run; }
			POSIX::_exit(1);
		};
	}
}

sub output {
	my $log = shift;
	my $fh = $fh[$$log];
	print $fh "\e[$Log::ANSI[$_[0]]m$_[1]: $_[2]\e[m\n";
}

1;
