package Unreal;
use base 'Network';
use Nick;

my %fromirc;
my %toirc;
my %token2cmd; # TODO actually fill when PROTOCTL TOKEN enabled

sub debug {
	print @_, "\n";
}

sub str {
	$_[1]->{linkname};
}

sub intro {
	my $net = shift;
	if ($_[0]) {
		# temporary until SERVER message handling properly set up
		WAIT: while (sysread $net, $net->{recvq}, 8192, length $net->{recvq}) {
			while ($net->{recvq} =~ /[\r\n]/) {
				(my $line, $net->{recvq}) = split /[\r\n]+/, $net->{recvq}, 2;
				$net->parse($line);
				last WAIT if $line =~ /SERVER/;
			}
		}
	}
	$net->send(
		"PASS :$net->{linkpass}",
		'PROTOCTL NICKv2 CLK NICKIP SJOIN SJOIN2 SJ3 VL UMODE2 TKLEXT',
		"SERVER $net->{linkname} 1 :U2309-hX6eE-$net->{numeric} Janus Network Link",
	);
}

# parse one line of input
sub parse {
	my ($net, $line) = @_;
	print "IN\@$net->{id} $line\n";
	my ($txt, $msg) = split /\s+:/, $line, 2;
	my @args = split /\s+/, $txt;
	push @args, $msg if defined $msg;
#	if ($args[0] =~ /^@(\S+)$/) {
#		$args[0] = $snumeric{$1};
#	} els
	if ($args[0] !~ s/^://) {
		unshift @args, undef;
	}
	my $cmd = $args[1];
	$cmd = $token2cmd{$cmd} if exists $token2cmd{$cmd};
	unless (exists $fromirc{$cmd}) {
		debug "Unknown command $cmd";
		return ();
	}
	$fromirc{$cmd}->($net,@args);
}

sub send {
	my $net = shift;
	# idea: because SSL nonblocking has some problems, and nonblocking send in
	# general requires maintinance of a sendq, have a separate thread handle send with a
	# Thread::Queue here
	my @out;
	for my $act (@_) {
		if (ref $act) {
			my $type = $act->{type};
			if (exists $toirc{$type}) {
				push @out, $toirc{$type}->($net, $act);
			} else {
				debug "Unknown action type '$type'";
			}
		} else {
			push @out, $act;
		}
	}
	print "OUT\@$net->{id} $_\n" for @out;
	$net->{sock}->print(map "$_\n", @out);
}

sub vhost {
	my $nick = $_[1];
	local $_ = $nick->{umode};
	return $nick->{vhost} if /t/;
	return $nick->{chost} if /x/;
	$nick->{host};
}

# IRC Parser
# Arguments:
# 	$_[0] = Network
# 	$_[1] = source (not including leading ':') or 'undef'
# 	$_[2] = command (for multipurpose subs)
# 	3 ... = arguments to the irc line; last element has the leading ':' stripped
# Return:
#  list of hashrefs containing the Action(s) represented (can be empty)

sub nickact {
	#(SET|CHG)(HOST|IDENT|NAME)
	my $net = shift;
	my($type, $act) = ($_[2] =~ /(SET|CHG)(HOST|IDENT|NAME)/i);

	my %a = (
		type => 'NICKINFO',
		src => $net->nick($_[0]),
		item => lc $act,
		value => $_[-1],
	);
	$a{dst} = $type eq 'SET' ? $a{src} : $net->nick($_[2]);
	\%a;
}

sub ignore {
	return ();
}

sub pm_notice {
	my $net = shift;
	my $notice = $_[1] eq 'NOTICE' || $_[1] eq 'B';
	my $src = $net->nick($_[0]);
	if ($_[2] =~ /^\$/) {
		# server broadcast message. No action; these are confined to source net
		return ();
	} elsif ($_[2] =~ /([~&@%+]?)(#\S*)/) {
		# channel message, possibly to a mode prefix
		return {
			type => 'MSG',
			src => $src,
			prefix => $1,
			dst => $net->chan($2),
			msg => $_[3],
			notice => $notice,
		};
	} elsif ($_[2] =~ /(\S+?)(@\S+)?/) {
		# nick message, possibly with a server mask
		# server mask is ignored as the server is going to be wrong anyway
		return {
			type => 'MSG',
			src => $src,
			dst => $net->nick($1),
			msg => $_[3],
			notice => $notice,
		};
	}
}

sub sjb64 { return $_[1]; } # TODO PROTOCTL SJB64
sub srvname { return $_[1]; } # TODO PROTOCTL NS

%fromirc = (
# User Operations
	NICK => sub {
		my $net = shift;
		if (@_ < 10) {
			# Nick Change
			my $nick = $net->nick($_[0]);
			my %a = (
				type => 'NICK',
				src => $nick,
				dst => $nick,
				nick => $_[2],
			);
			$a{nickts} = $net->sjb64($_[3]) if @_ == 4;
			return \%a;
		}
		# NICKv2 introduction
		my $nick = Nick->new(
			homenet => $net,
			homenick => $_[2],
		#	hopcount => $_[3],
			nickts => $net->sjb64($_[4]),
			ident => $_[5],
			host => $_[6],
			home_server => $net->srvname($_[7]),
			servicests => $net->sjb64($_[8]),
			name => $_[-1],
		);
		if (@_ >= 12) {
			$nick->umode($_[9]);
			$nick->{vhost} = $_[10];
		}
		if (@_ >= 14) {
			$nick->{chost} = $_[11];
			$nick->{ip_64} = $_[12];
			local $_ = $_[12];
			s/=+//;
			my $textip_table = join '', 'A'..'Z','a'..'z', 0 .. 9, '+/';
			if (length == 6) {
				my $binaddr = 0;
				for (split //, $_[12]) {
					$binaddr = $binaddr*64 + index $textip_table, $_;
				}
				$binaddr /= 16;
				$nick->{ip} = join '.', unpack 'C4', pack 'N', $binaddr;
			} elsif (length == 22) {
				s/(.)/sprintf '%06b', index $textip_table, $1/eg;
				s/(.{16})/sprintf '%x:', oct "0b$1"/eg;
				s/:[^:]*$//;
				$nick->{ip} = $_;
			}
		}
		$net->{nicks}->{lc $_[2]} = $nick;
		return (); #not transmitted to remote nets or acted upon until joins
	}, QUIT => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]);
		return {
			type => 'QUIT',
			src => $nick,
			dst => $nick,
			msg => $_[2],
		};
	}, KILL => sub {
		my $net = shift;
		my $src = $net->nick($_[0]);
		my $dst = $net->nick($_[2]);

		if ($dst->{homenet}->id() eq $net->id()) {
			return {
				type => 'QUIT',
				src => $src,
				dst => $dst,
				msg => "Killed ($_[3])",
			};
		}
		return {
			type => 'KILL',
			src => $src,
			dst => $dst,
			msg => $_[3],
		};
	}, UMODE2 => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]),
		return {
			type => 'NICKINFO',
			src => $nick,
			dst => $nick,
			item => 'mode',
			value => $_[2],
		}
	},
	SETIDENT => \&nickact,
	CHGIDENT => \&nickact,
	SETHOST => \&nickact,
	CHGHOST => \&nickact,
	SETNAME => \&nickact,
	CHGNAME => \&nickact,
	SWHOIS => \&ignore,
	SVSKILL => \&ignore, # the client sends a quit message when this is recieved

# Channel Actions
	JOIN => sub {
		my $net = shift;
		my $nick = $net->nick($_[0]);
		my @act;
		for (split /,/, $_[2]) {
			my $chan = $net->chan($_, 1);
			if ($chan->try_join($nick)) {
				push @act, +{
					type => 'JOIN',
					src => $nick,
					dst => $chan,
				}
			}
		}
		@act;
	}, SJOIN => sub {
		my $net = shift;
		my $chan = $net->chan($_[3], 1);
		$chan->timesync($net->sjb64($_[2])); # TODO actually sync
		my $joins = pop;

		my @acts = ();
		my $mode = shift || '+';

		for (split /\s+/, $joins) {
			if (/^([&"'])(.+)/) {
				$mode .= $1;
				push @_, $2;
			} else {
				/^([*~@%+]*)(.+)/ or warn;
				my $mode = $1;
				my $nick = $net->nick($2);
				$mode =~ tr/*~@%+/qaohv/;
				if ($chan->try_join($nick)) {
					push @acts, +{
						type => 'JOIN',
						src => $nick,
						dst => $chan,
						mode => $mode,
					};
				}
			}
		}
		$mode =~ tr/&"'/beI/;
		push @acts, +{
			type => 'MODE',
			src => $net,
			dst => $chan,
			mode => $mode,
			args => join ' ', @_[4 .. $#_],
		} unless $mode eq '+';
		return @acts;
	}, PART => sub {
		my $net = shift;
		return {
			type => 'PART',
			src => $net->nick($_[0]),
			dst => $net->chan($_[2]),
			msg => @_ ==4 ? $_[3] : '',
		};
	},
	TOPIC => \&ignore, # TODO
# Server actions
	SERVER => \&ignore, # TODO PROTOCTL NOQUIT
	SQUIT => \&ignore,  # TODO PROTOCTL NOQUIT
	PING => sub {
		my $net = shift;
		my $from = $_[3] || $net->{linkname};
		$net->send("PONG $from $_[2]");
		();
	},
	PONG => \&ignore,
	NETINFO => \&ignore,
	EOS => \&ignore,

# Messages
	PRIVMSG => \&pm_notice,
	NOTICE => \&pm_notice,
	SMO => \&ignore,
	SENDSNO => \&ignore,
	GLOBOPS => \&ignore,
	WALLOPS => \&ignore,
);

%toirc = (
	CONNECT => sub {
		my($net,$act) = @_;
		my $nick = $act->{src};
		my $mode = '+'.$nick->{umode};
		my $vhost = $nick->vhost();
		$mode =~ s/[xt]//g;
		$mode .= 'xt';
		join ' ', 'NICK', $nick->str($net), 1, $nick->{nickts}, $nick->{ident}, $nick->{host},
			$net->{linkname}, 0, $mode, $vhost, ($nick->{ip_64} || '*'), ':'.$nick->{name};
	}, JOIN => sub {
		my($net,$act) = @_;
		my $chan = $act->{dst};
		my $mode = $act->{mode} || '';
		$mode =~ tr/qaohv/*~@%+/;
		join ' ', 'SJOIN', $chan->{ts}, $chan->str($net), ":$mode".$act->{src}->str($net);
	}, PART => sub {
		my($net,$act) = @_;
		':'.$act->{src}->str($net).' PART '.$act->{dst}->str($net).' :'.$act->{msg};
	}, KICK => sub {
		my($net,$act) = @_;
		join ' ', ':'.$act->{src}->str($net), 'KICK', $act->{dst}->str($net),
			$act->{kickee}->str($net), ':'.$act->{msg};
	}, MSG => sub {
		my($net,$act) = @_;
		join ' ', ':'.$act->{src}->str($net), ($act->{notice} ? 'NOTICE' : 'PRIVMSG'), 
			$act->{dst}->str($net), ':'.$act->{msg};
	}, NICK => sub {
		my($net,$act) = @_;
		my $id = $net->id();
		":$act->{from}->{$id} NICK $act->{to}->{$id} $act->{dst}->{nickts}";
	}, QUIT => sub {
		my($net,$act) = @_;
		':'.$act->{src}->str($net).' QUIT :'.$act->{msg};
	},
);

1;
