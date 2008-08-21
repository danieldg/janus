# Copyright (C) 2007-2008 Daniel De Graaf
# Released under the GNU Affero General Public License v3
package Commands::Upgrade;
use strict;
use warnings;
use POSIX;

sub fexec {
	do { exec @_; };
	POSIX::_exit(1);
}

&Janus::command_add({
	cmd => 'upgrade',
	help => 'Upgrades all modules loaded by janus',
	acl => 1,
	code => sub {
		my($nick,$arg) = @_;
		my @mods = sort keys %Janus::modinfo;
		my $force = ($arg && $arg eq 'force');
		&Log::audit(($force ? 'Full module reload' : 'Upgrade') .
			' started by '.$nick->netnick);
		my @done;
		for my $mod (@mods) {
			next unless $Janus::modinfo{$mod}{active};
			unless ($force) {
				my $fn = 'src/'.$mod.'.pm';
				$fn =~ s#::#/#g;
				my $sha1 = $Janus::new_sha1->();
				open my $fh, '<', $fn or next;
				$sha1->addfile($fh);
				close $fh;
				my $csum = $sha1->hexdigest();
				next if $Janus::modinfo{$mod}{sha} eq $csum;
			}
			if (&Janus::reload($mod)) {
				push @done, $mod;
			} else {
				push @done, "\00304$mod\017";
			}
		}
		&Log::info('Upgrade finished');
		&Janus::jmsg($nick, join ' ', 'Modules reloaded:', sort @done);
	}
}, {
	cmd => 'up-tar',
	help => 'Downloads and extracts an updated version of janus via gitweb',
	acl => 1,
	code => sub {
		my $nick = shift;
		&Log::audit('Up-tar started by '.$nick->netnick);
		my $p = fork;
		return &Janus::jmsg($nick, 'Failed') unless defined $p && $p >= 0;
		return if $p;

		$SIG{CHLD} = 'DEFAULT';
		$p = fork;
		if ($p == 0) {
			fexec 'wget', '--output-document', 'janus.tgz', 'http://dd.qc.to/gitweb?p=janus.git;a=snapshot;h=refs/heads/master;sf=tgz';
		}
		waitpid $p, 0;
		fexec 'tar', '--extract', '--gzip', '--strip', 1, '--file', 'janus.tgz';
	}
}, {
	cmd => 'up-git',
	help => 'Runs "git pull"',
	acl => 1,
	code => sub {
		my $nick = shift;
		&Log::audit('Up-git started by '.$nick->netnick);
		my $p = fork;
		return &Janus::jmsg($nick, 'Failed') unless defined $p && $p >= 0;
		return if $p;
		fexec 'git-pull';
	}
});

1;
