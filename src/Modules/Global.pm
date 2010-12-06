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
        Event::insert_full({
          type => 'MSG',
          dst => $Janus::gchans{$_},
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

1;
