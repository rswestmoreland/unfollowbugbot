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
my $lock_file      = 'notif_accounts.lock';

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

## Make sure host's time matched twitter's time
sync_time();


## Connect to Database
my $dbh = connect_db($dbauth);

## Connect to Twitter
my $api = connect_api($tokens);
$api->{warning} = $settings->{api_warning} if defined $settings->{api_warning};


## Poll confirmed and send notifications

## We want to group friend list sizes into buckets with staggering wait times
my $wait_list = '( (friends_count <= 1000 AND message_sent < DATE_SUB(NOW(), INTERVAL 5 DAY))'
              . ' OR (friends_count <= 2500 AND message_sent < DATE_SUB(NOW(), INTERVAL 10 DAY))'
              . ' OR (friends_count <= 10000 AND message_sent < DATE_SUB(NOW(), INTERVAL 15 DAY)) )';

my $sql_handle = $dbh->prepare("SELECT count(*) FROM accounts a INNER JOIN friends f ON a.account_id=f.account_id WHERE confirmed=1 AND reported=0 AND $wait_list");
$sql_handle->execute or print "$pid: Unable to get confirmed count: " . $sql_handle->errstr;
my ($confirmed) = $sql_handle->fetchrow_array();
$sql_handle->finish;

if ( $confirmed ) {

  my $status = "$pid: Confirmed has $confirmed accounts waiting to be notified\n";
  print $status;

  ## Send DM to bot master for status
  send_message($api, $recipient_id, $status);

  ## We only want to process a batch of 250 accounts at a time, oldest queued accounts first
  $sql_handle = $dbh->prepare("SELECT a.account_id, account_name FROM accounts a INNER JOIN friends f ON a.account_id=f.account_id WHERE confirmed=1 AND reported=0 AND $wait_list GROUP BY a.account_id, account_name ORDER BY date_queued, account_name LIMIT 250");
  $sql_handle->execute or print "$pid: Unable to query account: " . $sql_handle->errstr;

  my @summary;

  while ( my ($account_id, $account_name) = $sql_handle->fetchrow_array() ) {

    ## Determine unfollows and let account know
    print "$pid: Retrieving unfollows for $account_name...\n";
    my @all_unfollows = get_unfollows( $dbh, $account_id );
    my $all_unfollows_count = scalar @all_unfollows;
    print "$pid: Total unfollows for $account_name is $all_unfollows_count\n";

    if ( $all_unfollows_count > 0 ) {

      my $intro = build_intro($account_name);

      my $message;
      if ( $all_unfollows_count <= 50 ) {
        my @all_names = get_names($api, @all_unfollows);
        if ( scalar @all_names > 0 ) {
          $message = "$intro:  " . join (' ', @all_names);
        }
        else {
          print "$pid: Unfollows may be deleted accounts\n";
          foreach my $friend ( @all_unfollows ) {
            print "$pid: -> Removing $friend for $account_id\n";
          }

          my $friends = join(',', map { "'" . $_ . "'" } @all_unfollows);
          my $sql_handle2 = $dbh->prepare("DELETE FROM friends WHERE account_id=? AND friend_id IN ($friends)");
          foreach my $deleted ( @all_unfollows ) {
            
          }
        }
      }
      else {
        $message = "$intro $all_unfollows_count friends";
      }

      ## Send DM to affected account
      my $sent;
      if ( $message ) {
        $sent = send_message($api, $account_id, $message) // 0;
      }

      if ( $sent ) {
        my $friends = join(',', map { "'" . $_ . "'" } @all_unfollows);

        ## We have finished notifying the account, set reported flag
        my $sql_handle2 = $dbh->prepare("UPDATE friends SET reported=1, date_reported=? WHERE account_id=? AND friend_id IN ($friends)");
        $sql_handle2->execute($account_id, $datetime) or print "$pid: Unable to set reported: " . $sql_handle2->errstr;
        $sql_handle2->finish;

        ## Update account so we know when the last message was sent
        $sql_handle2 = $dbh->prepare("UPDATE accounts SET message_sent=? WHERE account_id=?");
        $sql_handle2->execute($datetime, $account_id) or print "$pid: Unable to set message sent: " . $sql_handle2->errstr;
        $sql_handle2->finish;

        print "$pid: Sent message at $datetime:\n$message\n";
        push(@summary, "$account_name: $all_unfollows_count");
      }

    }

  }


  ## Send DM to bot master for metrics
  send_message($api, $recipient_id, join("\n", "$pid: Unfollows notified: \n", @summary));

  $sql_handle->finish;

}
else {
  print "$pid: No unfollows confirmed to be notified, skipping.\n";
}



## Cleanup
print "\n";
$dbh->disconnect;
unlink($lockpath);


