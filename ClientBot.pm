# Copyright (C) 2007 Daniel De Graaf
# Released under the Affero General Public License
# http://www.affero.org/oagpl.html
package ClientBot;
BEGIN { &Janus::load('LocalNetwork'); }
use Persist;
use Object::InsideOut 'LocalNetwork';
use strict;
use warnings;
&Janus::load('Nick');

__PERSIST__
persist @sendq     :Field;
persist @nicks     :Field;

__CODE__

my %fromirc;
my %toirc;

sub _init :Init {
	my $net = shift;
	$sendq[$$net] = [];
}

sub debug {
	print @_, "\n";
}

sub intro :Cumulative {
	my($net,$param) = @_;
	$net->send(
		'USER mirror gamma * :Janus IRC Client',
		"NICK $param->{nick}",
	);
}

sub cli_hostintro {
	my($net, $nname, $ident, $host) = @_;
	my $nick = $nicks[$$net]{$nname};
	unless ($nick) {
		$nick = Nick->new(
			net => $net,
			ts => time,
			nick => $nname,
			info => {
				host => $host,
				vhost => $host,
				ident => $ident,
				name => 'MirrorServ Client',
			},
		);
		$nicks[$$net]{$nname} = $nick;
		$net->nick_collide($nname, $nick);
	}
	my @out;
	if ($nick->info('host') ne $host) {
		push @out, +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'host',
			value => $host,
		};
	}
	if ($nick->info('ident') ne $ident) {
		push @out, +{
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'ident',
			value => $ident,
		};
	}
	@out;
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	my @out;
	debug '     IN@'.$net->id().' '. $line;
	$net->pong();
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
	if ($args[0] =~ /^:([^ !]+)!([^ @]+)@(\S+)/) {
		$args[0] = $1;
		push @out, $net->cli_hostintro($1, $2, $3);
	} elsif ($args[0] =~ /^:/) {
		$args[0] = undef;
	} else {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	$cmd = $fromirc{$cmd} || $cmd;
	unless (ref $cmd) {
		debug "Unknown command '$cmd'";
		return ();
	}
	push @out, $cmd->($net,@args);
	@out;
}

sub send {
	my $net = shift;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			next unless $toirc{$type};
			push @{$sendq[$$net]}, $toirc{$type}->($net,$act);
		} else {
			push @{$sendq[$$net]}, $act;
		}
	}
}

sub cmd1 { warn }
sub cmd2 { warn }

sub dump_sendq {
	my $net = shift;
	local $_;
	my $q = join "\n", @{$sendq[$$net]}, '';
	$q =~ s/\n+/\r\n/g;
	$sendq[$$net] = [];
	debug '    OUT@'.$net->id().' '.$_ for split /\r\n/, $q;
	$q;
}

# force tags
sub request_nick {
	my($net, $nick, $reqnick) = @_;
	&LocalNetwork::request_nick($net, $nick, $reqnick, 1);
}

sub nicklen { 40 }

%toirc = (
	LINK => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst}->str($net);
		"JOIN $chan";
	},
	MSG => sub {
		my($net,$act) = @_;
		my $type = $act->{msgtype};
		return unless $type eq 'PRIVMSG' || $type eq 'NOTICE';
		my $src = $act->{src}->str($net);
		my $dst = $act->{dst}->str($net);
		"$type $dst :<$src> $act->{msg}";
	},
);

sub pm_not {
	my $net = shift;
	my $src = $net->nick($_[0]) or return ();
	return +{
		type => 'MSG',
		src => $src,
		msgtype => $_[1],
		dst => $net->item($_[2]),
		msg => $_[3],
	};
}

%fromirc = (
	PRIVMSG => \&pm_not,
	NOTICE => \&pm_not,
	JOIN => sub {
		my $net = shift;
		my $src = $net->nick($_[0]) or return ();
		return +{
			type => 'JOIN',
			src => $src,
			dst => $net->chan($_[2], 1),
		};
	},
	PART => sub {
		my $net = shift;
		my $src = $net->nick($_[0]) or return ();
		return +{
			type => 'PART',
			src => $src,
			dst => $net->chan($_[2], 1),
			msg => $_[3],
		};
	},
	QUIT => sub {
		my $net = shift;
		my $src = $net->nick($_[0]) or return ();
		return +{
			type => 'QUIT',
			dst => $src,
			msg => $_[2],
		};
	},
	PING => sub {
		my $net = shift;
		$net->send("PONG $_[2]");
		();
	},
	'001' => sub {
		my $net = shift;
		return +{
			type => 'LINKED',
			net => $net,
			sendto => [ values %Janus::nets ],
		};
	},
);

1;
