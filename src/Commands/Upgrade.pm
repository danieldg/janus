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
		my @mods = sort grep { $Janus::modinfo{$_}{active} } keys %Janus::modinfo;
		&Log::audit('Full upgrade started by '.$nick->netnick);
		for my $mod (@mods) {
			&Janus::reload($mod);
		}
		&Log::info('Upgrade finished');
		&Janus::jmsg($nick, 'All modules reloaded');
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
