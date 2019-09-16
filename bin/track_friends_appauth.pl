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
my $lock_file      = 'track_friends_appauth.lock';

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
my $hostname = hostname() . '.app';
my $datetime = strftime('%Y-%m-%d %H:%M:%S', localtime());

my $recipient_id = $bot->{master_id};


my $lockpath = set_lock($settings->{temp_dir}, $lock_file);

## Make sure host's time matched twitter's time
sync_time();


## Connect to Database
my $dbh = connect_db($dbauth);

## Connect to Twitter
my $api = connect_api_app($tokens);
$api->{warning} = $settings->{api_warning} if defined $settings->{api_warning};


## Poll queue and run check

my $sql_handle = $dbh->prepare("SELECT count(*) FROM accounts WHERE queued=1 AND checking=0");
$sql_handle->execute or print "$pid: Unable to get queue count: " . $sql_handle->errstr;
my ($queued) = $sql_handle->fetchrow_array();
$sql_handle->finish;

print "$pid: Queue has $queued accounts waiting to be checked\n";

while ( $queued ) {

  ## Check out 1 account from the queue, or see if there is already a stale account checked out for this host and retry
  $sql_handle = $dbh->prepare("UPDATE accounts SET checking=1, checked_by=?, date_checked=? WHERE (queued=1 AND checking=0) OR (queued=1 AND checking=1 AND checked_by=?) ORDER BY date_checked ASC, followers_count DESC LIMIT 1");
  $sql_handle->execute($hostname, $datetime, $hostname) or print "$pid: Unable to check account: " . $sql_handle->errstr;

  if ( $sql_handle->rows ) {

    my $sql_handle2 = $dbh->prepare("SELECT account_id, account_name FROM accounts WHERE checking=1 AND checked_by=?");
    $sql_handle2->execute($hostname) or print "$pid: Unable to query account: " . $sql_handle2->errstr;
    my ($account_id, $account_name) = $sql_handle2->fetchrow_array();
    $sql_handle2->finish;

    ## Refresh friends list
    print "$pid: Retrieving friend list for $account_name\n";

    my @friend_list = get_friends( $api, $account_id );
    my $friend_count = scalar @friend_list;
    if ( $friend_count > 0 ) {

      ## Default all entries to not following, then revalidate following
      $sql_handle2 = $dbh->prepare("UPDATE friends SET following=0 WHERE account_id=?");
      $sql_handle2->execute($account_id) or print "$pid: Unable to revalidate entries: " . $sql_handle2->errstr;
      $sql_handle2->finish;

      print "$pid: $friend_count retrieved for $account_name\n";

      my @all_friends;
      foreach my $friend_id (@friend_list) {
        push @all_friends, "('$account_id','$friend_id','$datetime')";
      }

      while ( @all_friends ) {
        my $count = scalar @all_friends;
        my $batch = $count < 500 ? $count : 500;
        print "$pid: -> $batch of $count being inserted into DB for $account_name\n";

        my $all_friends_list = join(',', splice( @all_friends, 0, $batch) );
        $sql_handle2 = $dbh->prepare("INSERT INTO friends (account_id, friend_id, date_created) VALUES $all_friends_list ON DUPLICATE KEY UPDATE following=1, confirmed=0, reported=0");
        $sql_handle2->execute;
        $sql_handle2->finish;
      }

    }
    else {
      print "$pid: No results for $account_name, skipping.\n";
    }

    ## Confirm any new unfollows
    my @check_unfollows = check_unfollows( $dbh, $account_id);
    my $check_count = scalar @check_unfollows;
    if ( $check_count > 0 ) {
      print "$pid: $check_count potential unfollows for $account_name, confirming...\n";

      my @friend_list = get_friends( $api, $account_id );
      foreach my $friend_id ( @friend_list ) {
        my $sql_handle2 = $dbh->prepare("UPDATE friends SET following=1, confirmed=0, reported=0 WHERE account_id=? AND friend_id=?");
        $sql_handle2->execute($account_id, $friend_id) or print "$pid: Unable to confirm entries: " . $sql_handle2->errstr;
        $sql_handle2->finish;
      }

      my $sql_handle2 = $dbh->prepare("UPDATE friends SET confirmed=1 WHERE account_id=? AND following=0 AND reported=0");
      $sql_handle2->execute($account_id) or print "$pid: Unable to confirm entries: " . $sql_handle2->errstr;

      if ( my $count = $sql_handle2->rows ) {
        print "$pid: -> confirmed $count unfollows\n";
      }

      $sql_handle2->finish;
    }
    

    ## We have finished checking the account, remove from queue
    $sql_handle2 = $dbh->prepare("UPDATE accounts SET queued=0, checking=0 WHERE account_id=?");
    $sql_handle2->execute($account_id) or print "$pid: Unable to dequeue account: " . $sql_handle2->errstr;
    $sql_handle2->finish;

  }
  else {
    $queued = 0;
  }

  $sql_handle->finish;

}




## Cleanup
print "\n";
$dbh->disconnect;
unlink($lockpath);


