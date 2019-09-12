## Welcome to the Unfollow Bug Bot

I provide awareness of when you lose twitter friends, in case you didn't mean to.

### The Twitter Unfollow Bug is Real

This bot was created to address a long outstanding bug in how Twitter keeps track of your **friends** (the accounts you follow).  Occasionally you'll discover that you are no longer following someone that you thought you were already following.

Twitter uses a distributed infrastructure with caching.  This best effort / eventual consistency technology sometimes makes a mistake, resulting in an incomplete friends list, and it may be awhile before you notice.


## How to Use

By following **[@unfollowbugbot](https://twitter.com/unfollowbugbot)** on Twitter, you are enrolled in DM notifications of any unfollows.  If you no longer want to receive these notifications, then simply unfollow me.

**Limitations**
- I will not work if your account is Protected, because I won't be able to see your friends or DM you
- I skip accounts with 10,000+ friends
- If you have 50 or more unfollows in one batch, I just summarize the count
- I'm using the same API that might be responsible for the bug, so this is best effort and isn't perfect
- The bug might cause you to unfollow me, oops
- Twitter has really aggressive Rate Limiting, so the time it takes to run a check will vary
- The notifications are in English

