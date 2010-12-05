# Copyright (c) 2010 Samuel Hoffman
package Modules::Global;
use strict;
use warnings;
use Persist;

Event::command_add({
  cmd => 'global',
  help => 'Send a global message to all channels/users.',
  section => 'Network managment',
  details => [
    " \002NOTICE\002  Send a global NOTICE to all users Janus can see.",
    " \002CHANMSG\002 Send a global PRIVMSG to all channels Janus is in."
  ],
  acl => 'netop',
  syntax => '<option> <message>',
  code => sub {
    my ($src, $dst, $opt, @global) = @_;
    if (!defined $opt || !defined $global[0])
    {
      Janus::jmsg($dst, "Not enough arguments. See \002HELP GLOBAL\002 for usage.");
      return;
    }
    my $msg = (join ' ', @global);

    $msg = "Network Notice - [".$dst->homenick."] $msg";
    $opt = lc $opt;

    if ($opt eq 'notice')
    {
      
      foreach (keys %Janus::gnicks)
      {
        my $nick = $Janus::gnicks{$_};
        Event::insert_full({
          type => 'MSG',
          dst => $nick,
          msgtype => 'NOTICE',
          src => $Interface::janus,
          msg => $msg
        });
      }
    }
    elsif ($opt eq 'chanmsg')
    {
      foreach (keys %Janus::gchans)
      {
        my $chan = $Janus::gchans{$_};
        Event::insert_full({
          type => 'MSG',
          dst => $chan,
          msgtype => 'PRIVMSG',
          src => $Interface::janus,
          msg => $msg
        });
      }
    } else {
      Janus::jmsg($dst, "Invalid option \002".uc($opt)."\002. See HELP GLOBAL for usage.");
    }

    Janus::jmsg($dst, "Successfully sent.");
  }
});

sub gmsg {
  return unless @_;
  my ($type, $msg);
  foreach (@_)
  {
    $type = $_->{type};
    $msg = $_->{msg};
  }
  my @out;
  if ($type eq 'notice')
  {
    $type = 'NOTICE';
    foreach my $nick (keys %Janus::gnicks)
    {
      push @out, $nick; 
    }
  } elsif ($type eq 'chanmsg')
  {
    $type = 'PRIVMSG';
    foreach my $chan (keys %Janus::gchans)
    {
      push @out, $chan;
    }
  } else {
    return;
  }

  

  Event::insert_full(map +{
    type => 'MSG',
    src => $Interface::janus,
    dst => $_,
    msgtype => $type,
    msg => $msg
  }, @out);
}
1;
