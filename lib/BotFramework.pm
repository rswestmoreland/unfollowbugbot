#!/usr/bin/perl

#####################################
# Author:      Richard Westmoreland
# Application: Unfollow Bug Bot
# License:     GNU GPLv3
#####################################

use strict;
use warnings;

package BotFramework;
use Exporter::Auto;

use POSIX qw(strftime);
use Time::Strptime qw(strptime);
use Twitter::API;
use Twitter::API::Util 'is_twitter_api_error';

our $pid = $$;


sub set_lock {

  my ($temp_dir, $lock_file) = @_;

  # Setup a lock file
  if ( ! -d $temp_dir ) {
    unless ( mkdir $temp_dir ) {
      die "Can't create $temp_dir!\n";
    };
  }

  my $lockpath = $temp_dir . '/' . $lock_file;

  if ( -e $lockpath ) {
    open my $LOCK, "<", $lockpath or die "Can't open lock: $!\n";
    my $lockpid = <$LOCK>;
    chomp $lockpid;
    if ( kill 0, $lockpid ) {
      print "Lock exists and is valid, quitting.\n" and exit;
    }
    print "$pid: Lock file exists but is stale, resetting.\n";
    close $LOCK;
    unlink($lockpath);
  }

  open my $LOCK, ">", $lockpath or die "Can't lock: $!\n";
  print $LOCK $pid;
  close $LOCK;

  return ($lockpath);
}


## The host time needs to match twitter's time for authentication to work
sub sync_time {
  if ( my $api_date = `curl -sI 'http://search.twitter.com/' | grep -m1 "date: " | cut -d' ' -f2-` ) {
    chomp($api_date);
    `date -s "$api_date"`;
    print "$pid: Syncing date: $api_date\n";

    return 1;
  }

  die "Error syncing time from twitter's search page header, quitting.\n";
}


## Connect to Database
sub connect_db {
  my ($dbauth) = @_;

  my $dbh;

  my $dsn = 'DBI:mysql:database=' . $dbauth->{database} . ';host=' . $dbauth->{host} . ';port=' . $dbauth->{port};
  if (!($dbh = DBI->connect($dsn, $dbauth->{user}, $dbauth->{password}))) {
    die "Can't connect to database: $DBI::errstr\n";
  }
  
  return ($dbh);
}

## Connect to Twitter
sub connect_api {
  my ($tokens) = @_;

  my $api = Twitter::API->new_with_traits(
    traits              => [ qw/ApiMethods NormalizeBooleans DecodeHtmlEntities RetryOnError/ ],
    consumer_key        => $tokens->{consumer_key},
    consumer_secret     => $tokens->{consumer_secret},
    access_token        => $tokens->{access_token},
    access_token_secret => $tokens->{access_secret},
  );

  unless ( my $verify = $api->verify_credentials ) {
    die "Error verifying api access, quitting.\n";
  }

  return ($api);
}


# Retrieve current rate limits
sub check_rate_limits {
  my ($api, $resource) = @_;

  $resource //= 'application';

  ## Sometimes twitter returns blank results when looking up rate limits, have to try again until fetched
  ## Rate limit lookups also has its own rate limit, so try to intercept that too
  my $resources;
  while ( ! keys %{$resources} ) {

    eval { $resources = $api->rate_limit_status->{'resources'}; };

    if ( is_twitter_api_error($_) && $_->twitter_error_code == 429 ) {
      print "$pid: API limit reached, sleeping for 60 seconds\n" if $api->{warning};
      sleep 59;
    }

    sleep 1;

  }

  # Build a quick lookup table for all of the resources' rates
  my $rates = {
    application => {
      remain => $resources->{'application'}->{'/application/rate_limit_status'}->{'remaining'},
      reset  => $resources->{'application'}->{'/application/rate_limit_status'}->{'reset'},
    },
    friends => {
      remain => $resources->{'friends'}->{'/friends/ids'}->{'remaining'},
      reset  => $resources->{'friends'}->{'/friends/ids'}->{'reset'},
    },
    followers => {
      remain => $resources->{'followers'}->{'/followers/ids'}->{'remaining'},
      reset  => $resources->{'followers'}->{'/followers/ids'}->{'reset'},
    },
    users => {
      remain => $resources->{'users'}->{'/users/lookup'}->{'remaining'},
      reset  => $resources->{'users'}->{'/users/lookup'}->{'reset'},
    },
  };

  if ( $rates->{$resource}->{'remain'} == 0 ) {
    my $expire = $rates->{$resource}->{'reset'} - time();
    print "$pid: API limit reached, sleeping for $expire seconds\n" if $api->{warning};
    sleep ( $expire + 1 );
  }


}


## Get a list of friends
sub get_friends {
  my ($api, $user_id) = @_;
  my @friends;

  for ( my $cursor = -1, my $result; $cursor; $cursor = $result->{next_cursor} ) {

    RETRY: while ( 1 ) {

      check_rate_limits($api, 'friends');

      eval { $result = $user_id ? $api->friends_ids({ user_id => $user_id, cursor => $cursor, stringify_ids => 1 })
                                : $api->friends_ids({ cursor => $cursor, stringify_ids => 1 });
           };

      if ( is_twitter_api_error($_) ) {
         if ( $_->twitter_error_code == 429 ) {
           next RETRY;
         }
         else {
           print "$pid: Retrieval had failures: $@\n";
           return;
         }
      }

      push @friends, @{$result->{ids}};
      last RETRY;
    }

  }

  return @friends;
}


## Get a list of followers
sub get_followers {
  my ($api, $user_id) = @_;
  my @followers;

  for ( my $cursor = -1, my $result; $cursor; $cursor = $result->{next_cursor} ) {

    RETRY: while ( 1 ) {

      check_rate_limits($api, 'followers');

      eval { $result = $user_id ? $api->followers_ids({ user_id => $user_id, cursor => $cursor, stringify_ids => 1 })
                                : $api->followers_ids({ cursor => $cursor, stringify_ids => 1 });
           };

      if ( is_twitter_api_error($_) ) {
         if ( $_->twitter_error_code == 429 ) {
           next RETRY;
         }
         else {
           print "$pid: Retrieval had failures: $@\n";
           return;
         }
      }

      push @followers, @{$result->{ids}};
      last RETRY;
    }

  }

  return @followers;
}


# Get account names associated with account ids
sub get_names {
  my ($api, @ids) = @_;
  my @names;

  check_rate_limits($api, 'users');

  while ( scalar @ids > 0 ) {
    check_rate_limits($api);

    my @subset_ids = splice @ids, 0, 100;
    my $users;
    eval { $users = $api->lookup_users( { user_id => \@subset_ids } ); };
    if ( $@ ) {
      print "$pid: Lookup had failures: $@\n";
    }
    else {
      foreach my $user ( @{$users} ) {
        if ( $user->{'screen_name'} =~ /^@?[A-Za-z0-9_]{1,15}/ ) {
          my $screen_name = $user->{'screen_name'};
          $screen_name =~ s/^@//;
          push @names, '@' . $screen_name;
        }
      }
    }
  }

  return @names;
}


# Get full user details
sub get_user_details {
  my ($api, @ids) = @_;
  my @user_details;

  while ( scalar @ids > 0 ) {
    check_rate_limits($api, 'users');

    my @subset_ids = splice @ids, 0, 100;
    my $users;
    eval { $users = $api->lookup_users( { user_id => \@subset_ids } ); };
    if ( $@ ) {
      print "$pid: Lookup had failures: $@\n";
    }
    else {
      foreach my $user ( @{$users} ) {
        if ( $user->{'screen_name'} =~ /^@?[A-Za-z0-9_]{1,15}/ ) {
          my $screen_name = lc($user->{'screen_name'});
          $screen_name =~ s/^@//;

          my ($created_epoch) = strptime('%a %b %d %H:%M:%S +0000 %Y', $user->{'created_at'});
          my $account_created = strftime('%Y-%m-%d %H:%M:%S', localtime($created_epoch));

          push @user_details, { account_id      => $user->{'id_str'},
                                account_name    => $screen_name,
                                account_created => $account_created,
                                protected       => $user->{'protected'} ? 1 : 0,
                                verified        => $user->{'verified'} ? 1 : 0,
                                friends_count   => $user->{'friends_count'} // 0,
                                followers_count => $user->{'followers_count'} // 0,
                                statuses_count  => $user->{'statuses_count'} // 0,
                              };
        }
      }
    }
  }

  return @user_details;
}


## Determine unfollows for account by id, first pass
sub check_unfollows {
  my ($dbh, $account_id) = @_;
  my @unfollows;

  my $sql_handle = $dbh->prepare("SELECT friend_id FROM friends WHERE account_id=? AND following=0 AND confirmed=0 AND reported=0");
  $sql_handle->execute($account_id) or print "$pid: Unable to retrieve: " . $sql_handle->errstr . "\n";
  if ( $sql_handle->rows ) {
    while ( my ($unfollow_id) = $sql_handle->fetchrow_array() ) {
      if ( $unfollow_id =~ /^\d+$/ ) {
        push @unfollows, $unfollow_id;
      }
    }
  }
  $sql_handle->finish;

  return @unfollows;
}


## Determine unfollows for account by id
sub get_unfollows {
  my ($dbh, $account_id) = @_;
  my @unfollows;

  my $sql_handle = $dbh->prepare("SELECT friend_id FROM friends WHERE account_id=? AND following=0 AND confirmed=1 AND reported=0");
  $sql_handle->execute($account_id) or print "$pid: Unable to retrieve: " . $sql_handle->errstr . "\n";
  if ( $sql_handle->rows ) {
    while ( my ($unfollow_id) = $sql_handle->fetchrow_array() ) {
      if ( $unfollow_id =~ /^\d+$/ ) {
        print "$pid: -> Adding $unfollow_id for $account_id\n";
        push @unfollows, $unfollow_id;
        my $sql_handle2 = $dbh->prepare("UPDATE friends SET reported=1, date_reported=current_timestamp() WHERE account_id=? AND friend_id=?");
        $sql_handle2->execute($account_id, $unfollow_id) or print "$pid: Unable to update table: " . $sql_handle2->errstr . "\n";
        $sql_handle2->finish;
      }
    }
  }
  $sql_handle->finish;

  return @unfollows;
}


sub build_intro {
  my ($account_name) = @_;

  my @greetings = ('Hello', 'Greetings', 'Salutations', 'Hi', 'Howdy', 'Yo', 'Hey', 'FYI');
  my @statement = ('since I last checked, you have unfollowed',
                   'I happen to notice you\'re no longer following',
                   'did you know you have unfollowed',
                   'you appear to have stopped following',
                   'I wanted to let you know you\'ve unfollowed');
  my $greet = $greetings[ rand @greetings ];
  my $state = $statement[ rand @statement ];

  return "$greet $account_name, $state";
}

1;

