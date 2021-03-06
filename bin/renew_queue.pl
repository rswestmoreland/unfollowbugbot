#!/usr/bin/perl

#####################################
# Author:      Richard Westmoreland
# Application: Unfollow Bug Bot
# License:     GNU GPLv3
#####################################

use strict;
use warnings;

use POSIX;
use YAML::Tiny;
use Sys::Hostname qw(hostname);
use Time::Strptime qw(strptime);
use DBI;
use DBD::mysql;
use Twitter::API;

use lib '/opt/twitter/lib';
use BotFramework;

#####################################################

my $config_file    = '/etc/unfollowbug/bot.config';
my $lock_file      = 'renew_queue.lock';

#####################################################

# Autoflush every print
BEGIN { $| = 1; };

our $pid = $$;

# Get config
my $config   = YAML::Tiny->read( $config_file ) or die "Can't open $config_file: $!\n";
my $settings = $config->[0]->{settings}         or die "Config is missing settings\n";
my $dbauth   = $config->[0]->{db}               or die "Config is missing database params\n";
my $tokens   = $config->[0]->{tokens}           or die "Config is missing API tokens\n";
my $bot      = $config->[0]->{bot}              or die "Config is missing bot info\n";
my $hostname = hostname();
my $datetime = strftime('%Y-%m-%d %H:%M:%S', localtime());

my $recipient_id = $bot->{master_id};


my $lockpath = set_lock($settings->{temp_dir}, $lock_file);

## Make sure host's time matches twitter's time
sync_time();


## Connect to Database
my $dbh = connect_db($dbauth);

## Connect to Twitter
my $api = connect_api($tokens);
$api->{warning} = $settings->{api_warning} if defined $settings->{api_warning};


## If there are any remaining checks in the queue, then skip refreshing queue
my $sql_handle = $dbh->prepare("SELECT count(*) FROM accounts WHERE queued=1");
$sql_handle->execute or print "$pid: Unable to query users: " . $sql_handle->errstr;
my ($remaining) = $sql_handle->fetchrow_array();
$sql_handle->finish;

if ( $remaining ) {
  ## Let me know how many are remaining
  my $note = "Queue has $remaining pending entries";
  $api->new_direct_messages_event($note, $recipient_id);

  print "$pid: $note, skipping.\n";
}
else {
  ## Let me know I'm starting
  my $note = "Starting new batch with pid " . $pid;
  $api->new_direct_messages_event($note, $recipient_id);


  my @queue_accounts;

  # Get a list of accounts
  # Retrieve followers from the bot's account
  print "$pid: Getting followers for " . $bot->{account} . "\n";

  my @bot_followers = get_followers( $api, $bot->{account_id} );
  my $bot_followers_count = scalar @bot_followers;
 
  if ( $bot_followers_count ) {
    print "$pid: Retrieved $bot_followers_count followers, loading into queue...\n";

    push (@queue_accounts, get_user_details( $api, @bot_followers ));

    foreach my $account (@queue_accounts) {

      ## Dequeue any protected accounts or accounts with 10000 or more friends
      my $queued = 1;
      if ( $account->{'protected'} == 1 || $account->{'friends_count'} >= 10000 ) {
        $queued = 0;
      }

      $sql_handle = $dbh->prepare("INSERT INTO accounts (account_id, account_name, account_created, description, protected, verified, friends_count, followers_count, statuses_count, queued, date_queued) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON DUPLICATE KEY UPDATE account_name=?, description=?, protected=?, verified=?, friends_count=?, followers_count=?, statuses_count=?, queued=?, date_queued=?");
      $sql_handle->execute( $account->{'account_id'},
                            $account->{'account_name'},
                            $account->{'account_created'},
                            $account->{'description'},
                            $account->{'protected'},
                            $account->{'verified'},
                            $account->{'friends_count'},
                            $account->{'followers_count'},
                            $account->{'statuses_count'},
                            $queued,
                            $datetime,

                            $account->{'account_name'},
                            $account->{'description'},
                            $account->{'protected'},
                            $account->{'verified'},
                            $account->{'friends_count'},
                            $account->{'followers_count'},
                            $account->{'statuses_count'},
                            $queued,
                            $datetime,
                          );
      $sql_handle->finish;
    }

    ## Dequeue new accounts less than a month old
    $sql_handle = $dbh->prepare("UPDATE accounts SET queued=0 WHERE account_created >= DATE_SUB(NOW(), INTERVAL 30 DAY)");
    $sql_handle->execute;
    $sql_handle->finish;

    print "$pid: Finished reloading queue.\n";

    $sql_handle = $dbh->prepare("SELECT count(*) FROM accounts WHERE queued=1");
    $sql_handle->execute or print "$pid: Unable to query users: " . $sql_handle->errstr;
    my ($new_queue) = $sql_handle->fetchrow_array();
    $sql_handle->finish;

    ## Let me know how many are to be processed
    my $note = "The queue has been reloaded with $new_queue accounts";
    $api->new_direct_messages_event($note, $recipient_id);

  }
  else {
    die "Can't retrieve followers for " . $bot->{account} . ", quitting.\n";
  }

}


## Cleanup
print "\n";
$dbh->disconnect;
unlink($lockpath);


