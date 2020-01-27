#!/usr/bin/env perl

# MUST be use'd as the very first thing in the main program,
# as it clones/forks the program before it returns.
use AnyEvent::Watchdog autorestart => 1, heartbeat => 120;

use AnyEvent (); BEGIN { AnyEvent::common_sense }
use EV;
use AnyEvent::IRC::Util qw/mk_msg/;
use AnyEvent::IRC::Client;
use AnyEvent::Feed;
use Tie::File;
#use WWW::Shorten::Bitly;
#use WWW::Shorten::TinyURL;
#use WWW::Shorten 'TinyURL';
use Mojo;
use Mojo::UserAgent;
use Regexp::Common qw /URI/;
use Encode;
use HTML::Entities;
use String::Util 'trim';
use UNIVERSAL::can;

$XML::Atom::ForceUnicode = 1;
$Object::Event::DEBUG = 1;

my %http_hdrs = (
    "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:72.0) Gecko/20100101 Firefox/72.0"
);

my @colors = qw/1 2 3 4 5 6 7 12 13/;
my @Q = ();
my @sent = ();
my %feeds = ();
my %fetched = ();
my %usedtitles = ();
my %usedlinks = ();
my %colors = ();

my $feedsfile = 'PATH_TO_YOUR_FEEDS_FILE';
my $fetchinterval = 600;

my $heartbeat;

my $max_burst = 20;
my $window    = 5;

my $bitlyuser = '';
my $bitlyapikey = '';

my $nickname = "ircnick";
my $username = "ircnick";
my $realname = "ircnick";
my $serverpass = "username:password";

my @feedreaders = ();

my @allchannels = qw/ ##mychan /;

my $c = AnyEvent->condvar;

my $irc = AnyEvent::IRC::Client->new(send_initial_whois => 1);

$irc->reg_cb (

    connect => sub {
        my ($irc, $err) = @_;
        if (defined $err) {
            print "Couldn't connect to server: $err\n";
            use AnyEvent::Watchdog::Util;
            AnyEvent::Watchdog::Util::restart;
        }
    },

    publicmsg => sub {
        my ($self,$chan,$msg) = @_;

        my $body = ${$msg->{params}}[1];
        my $mask = $msg->{prefix};
        my $pre_at = (split /@/, $mask, 2)[0];
        my ($nick,$user) = (split /!/, $pre_at, 2);

    },

    registered => sub {
        my ($self) = @_;
        print "registered!\n";
        $irc->enable_ping(30);

        $heartbeat = AnyEvent->timer (after => 2, interval => 1, cb => sub {
            my $num_queued = scalar @Q;

            return unless $num_queued > 0;
            my $curtime = AnyEvent->now;
            my $threshold = $curtime - $window;
            my $ctr;

            foreach my $i (0..$#sent) {            #check for messages sent recently and count them
                if ($sent[$i] < $threshold) {
                    splice(@sent, $i, 1);
                } else {
                    $ctr++;
                }
            }

            if ($ctr > $max_burst) {             #bail on this iteration if we're over the limit
                return;
            }

            push @sent, $curtime;                    #for the recent messages check
            my $tosend = shift @Q;
            $irc->send_srv($tosend);
        });

        loadfeeds();

        for my $chan (@allchannels) {
            qsend('JOIN', $chan);
        }

        for my $key (keys %feeds) {
            my $feedurl = $feeds{$key};
            my $feedtitle = $key;

            my $fr = AnyEvent->condvar;

            push @feedreaders, AnyEvent::Feed->new (
                url      => $feedurl,

                interval => $fetchinterval,

                on_fetch => sub {
                    my ($feed_reader, $new_entries, $feed, $error) = @_;

                    #print "Checking...";
                    #print $new_entries;

                    if (defined $error) {
                        warn "ERROR: $key -- $error\n";
                        return;
                    }

                    for (@$new_entries) {
                        my ($hash, $entry) = @$_;

                        my $title = $entry->title;
                        my $url = $entry->link;

                        if ($url =~ /reddit.com/) {
                            my $reddit_content_body = $entry->content->body;
                            my @reddit_parts = $reddit_content_body =~ m/<a href="(\S+)">\[link\]/;
                            $url = $reddit_parts[0];
                        }

                        if ($url =~ /yahoo.com/) {
                            $url =~ s/http:/https:/g;
                        }

                        if ($url =~ /hisz.rsoe.hu/) {
                            $url =~ s/event_summary/event_desc/;
                        }

                        # actual news link: http://www.presstv.ir/detail/139946.html
                        # rss feed: http://www.presstv.ir/detail.aspx?id=139946&sectionid=351020403

                        if ($url =~ m|presstv.ir/detail.aspx\?id=(\d+)|i) {
                            $url = "http://www.presstv.ir/detail/$1.html";                #PRESSTV HACK
                        }

                        $url =~ s/https:\/\/via.hypothes.is\///g;

                        my $location = $url;

                        if (($url =~ /^https?:\/\/news\.google\.com\//) || ($url =~ /https?:\/\/feedproxy\.google\.com/) || ($url =~ /https?:\/\/feeds\.reuters\.com/)) {
                            my $ua       = Mojo::UserAgent->new;
                            $location = $ua->get( $url )->res->headers->header( "location" );
                        }

                        $url = $location;

                        my $hashkey = $key . $title;
                        next if ($usedtitles{$hashkey});
                        $usedtitles{$hashkey}++;
                        next if ($usedlinks{$url});
                        $usedlinks{$url}++;

                        unless ($fetched{$key}) {
                            next;
                        }

                        #my $shortened = makeashorterlink($url, $bitlyuser, $bitlyapikey);
                        #$shortened =~ s/http:/https:/g;

                        my $dt_c = $entry->issued;
                        my $dt_m = $entry->modified;
                        my $date = undef;

                        if ($dt_m) {
                            $date = $dt_m->iso8601();
                        } elsif ($dt_c) {
                            $date = $dt_c->iso8601();
                        }

                        decode_entities($title);             #GET RID OF &amp; etc

                        for ($feedtitle, $title) {
                            s/\s+/ /g;                      #NORMALIZE WHITE SPACE
                            s/^\s+//;
                        }

                        my $col = $colors{$feedtitle};
                        for my $sendchan (@allchannels) {
                            my $msg;
                            $msg .= ($col == 'N') ? "[" : "[\002\003$col";
                            $msg .= $feedtitle;
                            $msg .= ($col == 'N') ? "] " : "\003\002] ";

                            $msg .= "\002";
                            $msg .= trim($title);
                            $msg .= "\002";
                            $msg .= " ";
                            
                            #$msg .= "\002";
                            #$msg .= $shortened;
                            
                            $msg .= $url;
                            
                            #$msg .= "\002";
                            
                            $msg .= " $date";
                            $msg = encode("utf8", $msg);
                            
                            qsend('PRIVMSG', $msg , $sendchan);
                        }
                    }
                    $fetched{$key}++;
                }
            );
        }
    },

    disconnect => sub {
        print "disconnected: $_[1]!\n";
        use AnyEvent::Watchdog::Util;
        AnyEvent::Watchdog::Util::restart;
    },
);

$irc->connect (
   "irc.freenode.net", 6667, { nick => $nickname, user => $username, real => $realname, password => $serverpass }
);

$c->wait;

sub raw {
    my $command = shift;
    my $curtime = time;

    push @sent, $curtime;
    $irc->send_raw($command);
}

sub qsend {
    my ($command,$msg,$target) = @_;

    if ($target) {
        my $ircmsg = mk_msg(undef, uc($command), $target, $msg);
        push @Q, $ircmsg;
        return;
    } else {
        my $ircmsg = mk_msg(undef, uc($command), $msg);
        push @Q, $ircmsg;
    }
}

sub is_array {
    my ($ref) = @_;
    return 0 unless ref $ref;

    eval {
        my $a = @$ref;
    };
    if ($@=~/^Not an ARRAY reference/) {
        return 0;
    } elsif ($@) {
        die "Unexpected error in eval: $@\n";
    } else {
        return 1;
    }
}

sub loadfeeds {
    my @tied;

    {
        my $o = tie @tied, "Tie::File", $feedsfile;
        $o->flock;
        for (@tied) {
            next if /^#/;
            next if /^\s$/;
            next unless $_;
            my ($color,$name,$url) = (split /\|/, $_, 3);
            $colors{$name} = $color;
            $feeds{$name} = $url;
        }
    }

    untie @tied;
}

sub savefeeds {
    my @tied;

    {
        my @temp = ();
        my $o = tie @tied, "Tie::File", $feedsfile;
        $o->flock;
        for my $key (keys %feeds) {
            my $item = $colors{$key} . '|' . $key . '|' . $feeds{$key};
            push @temp, $item;
        }
        @tied = @temp;
    }

    untie @tied;
}
