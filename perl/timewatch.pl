#! /usr/bin/perl

use strict;
use warnings;
use English qw(-no_match_vars);
use POSIX qw( strftime );
use IPC::Open2;
use Carp;
use Fcntl qw(:flock);
use Sys::Hostname;
use File::Copy;

# Required none core modules
use Net::NTP qw(get_ntp_response);    # For NTP
use Mail::Mailer;                     # For smtp

# Enable for debug
# use Data::Dumper;
# use Regexp::Debugger;

# fss1138 ta liamg tod moc
# COPYRIGHT AND LICENSE
# Copyright (C) 2015, fss1138.

# The perl part of this program is free software; you
# can redistribute it and/or modify it
# under the same terms as Perl 5.14.0.

our $VERSION = '0.0.38';

# *** SCRIPT TO POLL INTERNAL NTP SOURCES, CHECK RETURNED OFFSET (AGAINST NPL) AND LEAP INDICATOR ***
# *** WARN IF ANY SOURCE IS OUTSIDE OFFSET LIMIT, UNAVAILABLE OR HAS THE LI SET ***

# MAKE LIST OF NTP SERVERS IN A FILE CALLED internal_ntp_servers_list.txt ($ntplist), one IP per line

# DEFINE FILE NAME AND PATHS HERE- remember to delimit forward slashes
# e.g.  "\/home\/user\/$filename" or use single quotes if no variable involved '/home/user/';

# SMTP SERVER/RELAY - email alert relay & addresses
my $mailaddress = 'your_company_email_relay';
my $mailto      = 'alerts@domain.com';
# $mailcc will take comma separate multiple addresses.  'reports@domain.com, support@domain.com'
my $mailcc      = 'support@domain.com';

# File containing list of internal servers (one per line)
my $ntplist = 'internal_ntp_servers_list.txt';

# name for log files (as required date_stamp.txt extension will be created/appended)
my $logname   = 'ntp_test_log';
my $warn_name = 'ntp_warn_log';

# name for web link to log files
my $weblogto  = 'ntplog';
my $webwarnto = 'ntpwarnings';

#  Full path to logfiles 
my $logto         = '/var/www/ntplog/';
my $warnto        = '/var/www/ntpwarnings/';
my $warn_name_txt = $warnto . $warn_name . '.txt';

# Remember to make these directories, \var\www is created by Apache

# This script will also create an HTML page using css, as named below:
# Name of index.html file for web interface
my $index = '/var/www/index.html';

# Name of help file help.txt file for web interface
my $helptxt = '/var/www/help.txt';

# Name of CSS
my $css = '/var/www/main.css';

# External sources used for comparison, intended to be the National Physical Laboratory
# ntp1.np1.co.uk sometimes fails to respond so npt2 is used
# After NPLs outage on 05 Oct 2015, the second reference chosen was PTB
my $external_ref1 = 'ntp2.npl.co.uk';

# Second choice: Physikalisch-Technische Bundesanstalt (PTB) ptbtime3.ptb.de
# As above the potentially quieter server was chosen instead of ptbtime1 or 2
my $external_ref2 = 'ptbtime3.ptb.de';

# Define the offset limit allowed - i.e. TIME DIFFERENCE ALLOWED BETWEEN INTERNAL AND EXTERNAL REF
my $offset_limit = 0.3;    # Offset difference in seconds

# influxDB parameters

# Database name (table name)
my $db_name='timewatch';

# Measurement will be, time_offset (row name)
my $measurement='ntp_offset';

my $EMPTY = qw{};
my $SPACE = " ";

# If any condition increments $warn, an email should be generated.
my $warning = 0;

# variable to hold server list as scalar used by ntpdate
my $server_list;

# variable to hold the reference offset
my $ref_offset = '0';

# variable to hold ntp packet responses
my %response;

# populate array @servers with ip list from server list
my @servers = ();

# variable to hold the result message shown on the web page
my $results;

# $host takes hostname of system running this script from Sys::hostname
my $host = hostname;

# verbosity level.  Zero is no output.
my $verbosity = '0';

# BEFORE WE BEGIN, go flock yourself ...
## ENSURE ONLY ONE VERSION OF THIS SCRIPT IS RUNING ##

open DATA, '<', $PROGRAM_NAME or croak "Couldn't open script: $OS_ERROR";
flock DATA, LOCK_EX | LOCK_NB
  or croak
"This script $PROGRAM_NAME is already running.  All those moments will be lost in time, like tears in rain. Time to die";

# Don't close the file handle until the program end. Critic will complain about file handles not closed quickly but in this case its necessary as a duplicate process check

# Create time stamp (seconds since Unix epoch):
my $now = time;

# And a variable to holding the number of seconds in a week, 86400 seconds in a day *7
my $aweek = 604800;

## CREATE LOCALTIME FORMATTED ARRAY VIA A SUB ROUTINE ##
# @tarray contains [0]date [1]time [2]dateandtime
# 07/07/2015 15:47:39 07072015154739

sub time_string {
    my $tstring = strftime( '%d/%m/%Y~%H:%M:%S~%d%m%Y%H%M%S', localtime )
      ;    # create time stamp string
    my @tarray = ( split /~/x, $tstring );
    return @tarray;
}

my @runtime = time_string();

# Check mtime of warning file is older than 7 days, rename
# with date stamp if old warning found

my $mtime;    # mtime variable for stat
my $new_name = $warnto . $warn_name . '_' . $runtime[2] . '.txt';

if ( -f $warn_name_txt ) {

    $mtime = ( stat "$warn_name_txt" )[9];

    #   print "\n  mtime for $warn_name_txt is $mtime, current time is $now\n";

    if ( $now - $aweek > $mtime ) {
        print
"\n $warn_name_txt is more than a week old \n  and will be renamed $new_name\n";
        rename $warn_name_txt, $new_name;
    }
}

## VERBOSITY PRINT STATEMENT ##
sub printv {
    my $print_v = shift;
    if ( $verbosity eq '1' ) {
        print "$print_v" or die "print function failed\n";
    }
    return;
}

## SUB TO SEND MAIL VIA SMTP SERVER/RELAY ##

sub smtp_send {

    my $the_message = shift;
    my $greeting =
"** This is an automated error message from THE NOC, hosted on $host **\n\n This report was created by $PROGRAM_NAME, version V$VERSION\n\n";
    $the_message =
      $greeting . $the_message;    # Add greeting to beginning of error text

# Outlook default has File > Options > Mail > Message Format > Remove Extra Line Breaks ON by default. This causes \n within this string to be removed!
# Changing this only works for mails received after the setting change.
# Creating an indent by adding 3 or more spaces to the beginning of each line stops Outlook stripping the \n
    $the_message =~ s/^/   /gxms;

    my $mailer = Mail::Mailer->new(
        'smtp',
        Server  => $mailaddress,
        Timeout => 20,
    );    # Net::SMTP default timeout is 120 - too long for a LAN server

# Cc will take comma separate multiple addresses.  'Cc' => 'test@domain.com, support@domain.com' Note that $mailer wont accept 'cc' must be Cc

    # eval required to trap no connection error or script will die
    eval {
        $mailer->open(
            {
                'From'    => 'THE_NOC<do_not_reply@notnownotever>',
                'To'      => $mailto,
                'Cc'      => $mailcc,
                'Subject' => "NTP warning from $host"
            }
        );
        1;
    } or ( return $ERRNO );
    print {$mailer} "$the_message\n"
      || croak 'Message send failed';
    print {$mailer} "\n   ---------- End of Message ----------\n"
      || croak 'Message end failed';
    $mailer->close();
    return 0;

}

## SUB TO WRITE TO INFLUXDB ##

sub infux_insert {
# TagKey1 = server, TagKey2 = reference, TagKey3= runtime 
# Value is the ntp offset between local clock and the polled server
# insert_array should contain, database_name, measurement, tagkey1, tagkey2, tagkey3 value

my @insert_array =@_;

# Enable print and none surpressed version of the curl system call for debug:
# print "  creating POST to db $insert_array[0], parameter $insert_array[1], server $insert_array[2], Ref $insert_array[3], script run time $insert_array[4], offset value $insert_array[5] \n";
# system ("curl -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2],ref=$insert_array[3],runtime=$insert_array[4] value=$insert_array[5]\"");	 

system ("curl -s -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2],ref=$insert_array[3],runtime=$insert_array[4] value=$insert_array[5]\" > /dev/null");

return; 
# End of influx_insert
}


die "Only one argument allowed. Verbose -v or help -h\n" if @ARGV > 1;

if ( !defined $ARGV[0] ) {
    $verbosity = '0';
    print
"\n  $PROGRAM_NAME V$VERSION running at: $runtime[0] $runtime[1] \n  use -v for verbose, -h for help, -m for mail test\n\n";
}

if ( defined( $ARGV[0] ) && $ARGV[0] eq '-v' ) { $verbosity = '1'; }

if ( $verbosity eq '1' ) {
    print << "HELLO";

    ------------------------------------------------------------
       $PROGRAM_NAME V$VERSION run at: $runtime[0] $runtime[1]
    ------------------------------------------------------------
       This script compares NTP sources listed in:
             $ntplist
       with:
             $external_ref1 or $external_ref2
       If the difference in offsets is more than $offset_limit seconds,
       or a leap Indicator bit is set,
       or the server does not repond, a WARNING is flagged.
    ------------------------------------------------------------

HELLO
}

# Create a help page

my $help = << "HELP";

    --------------------------------------------------------------
       $PROGRAM_NAME V $VERSION last run $runtime[0] $runtime[1]
    --------------------------------------------------------------
       $PROGRAM_NAME,
       is a script to compare NTP offsets between servers.
       It is running on host: $host
       When run at command line, there are three options:
       -h This help page
       -v Verbose mode
       -m Email send test
       
       Servers to be polled are in:
       ./$ntplist
       Logs are saved to:
       $logto
       Warnings are saved to:
       $warnto
       
       This script compares NTP sources listed in:
             $ntplist
       with:
             $external_ref1 or $external_ref2
       When run, this script generates a log file.
       If the difference in offsets is more than $offset_limit seconds,
       or a leap Indicator bit is set,
       or the server does not respond, a WARNING is logged.
       
       Definitions:
       Server = Internal NTP server
       Ref = Reference clock (time source used by each server)
       St = Stratum
       Li = Leap Indicator, normally zero
       Precision = Clock quality measured as a power of two,  
       E.g. precision=-16 is about 15 microseconds (2^-16 s)
       offset = offset of server compared to local clock 
       For more information check the RFC 5905 (V4)
       https://datatracker.ietf.org/doc/rfc5905/ 
       
       Operation:
       Flocking is used to ensure only one instance of this 
       script runs at a time.
       NTP uses UTC - all times are in UTC.
       Log files will be deleted after 28 days, 
       warning files will be renamed with a date stamp after 7 days.
       Acknowledged (date stamped) warning files exist forever.
       The first warning sends an email and starts a warning log,
       the warning file is appended to with no further email sent.
       Renaming the warning file allows the next warning to
       send an email and begin a new file.  
 
    --------------------------------------------------------------

HELP

# If ARGV -h pring the help page

if ( defined( $ARGV[0] ) && $ARGV[0] eq '-h' ) {
    print "$help";
    exit 0;
}

# If ARGV -m sent a test mail

if ( defined( $ARGV[0] ) && $ARGV[0] eq '-m' ) {
    print "\n Sending test email to $mailto\n";
    my $testmessage =
"This is a test message sent to $mailto via smtp relay at $mailaddress\n\nFor more detail check:\nNOC homepage http://$host\nWarning log http://$host/ntpwarnings/\nLog files http://$host/ntplog/";
    smtp_send($testmessage);
    exit 0;
}

# write the HELPHTML content to the $index file
open my $HELPTXT, '>', $helptxt
  or carp "$helptxt file could not be found or opened\n";
exit 2 if !print {$HELPTXT} "$help";
close $HELPTXT or carp "Unable to close $help\n";

# Read the ntp source servers list into the array @servers
# skip emply or lines begginging space or #
open my $SERVERS, '<', "$ntplist"
  or croak
"server list file wont open, check $ntplist path and filename are correct: $!";
while (<$SERVERS>) {

# chomp; only removes current input record separator but if originated from Windows ...
    $_ =~ s/\r?\n$//xms;
    next
      if ( $_ =~ m/^\s+/xms ) || ( $_ =~ m/^\#+/xms ) || ( $_ =~ m/^\s*$/xms );
    push( @servers, $_ );
}
close $SERVERS or croak "server list file wont close: S!";

# print join (", ", @servers); # debug line to print servers array

# copy ntplist to www root, to make it visible to web gui
copy( "$ntplist", "/var/www/$ntplist" ) or carp("copy of $ntplist failed");

# Create a log name with the path and time stamp
$logname = $logto . $logname . '_' . $runtime[2] . '.txt';

# Open log file for write - print an opening header to the file:
open( my $LOG, '>', "$logname" )
  || die "can't open file $logname\n";
print $LOG
"\n  --- START OF LOG created by $PROGRAM_NAME V$VERSION from host $host ---\n  --- $runtime[0] $runtime[1] ---\n  --- External reference used is $external_ref1 or $external_ref2 ---\n  --- Warning flagged if offset difference is > $offset_limit sec between external ref and internal server query ---  \n";

close $LOG || die "Cannot close $logname\n";

## sub routing to create a single warning log, email only the first  and append (but no email) if the log already exists ##
sub warn_append {

    # if warning log does not exist, create it, include the header
    if ( !-f $warn_name_txt ) {

        # print "\n $warn_name_txt did not exist so adding header\n";
        # Open log file for write - print an opening header to the file:
        open( my $WARN, '>', "$warn_name_txt" )
          || carp "can't open file $warn_name_txt\n";
        print $WARN
"\n  --- START OF WARNINGS LOG from $PROGRAM_NAME V$VERSION ---\n  --- first written at: $runtime[0] $runtime[1] ---\n  --- Offset limit used between reference and internal server = $offset_limit seconds ---\n  --- External reference used is $external_ref1 or $external_ref2 ---\n  --- For the full log check $logto ---\n  --- This script was run from host: $host ---\n\n";

        # now add the warning to the header
        my $add_warning = shift;
        exit 2 if !print {$WARN} "$add_warning";
        close $WARN || warn "Cannot close $warn_name_txt\n";

 # email this warning here so it is only sent when the log file is first created
        my $mail_warning =
"$add_warning\nTHIS IS THE FIRST WARNING OF POSSIBLY MANY - ONLY A SINGLE EMAIL IS SENT UNTIL THE WARNING(S) ARE ACKNOWLEDGED\n\nFor more detail check:\nNOC hompage http://$host\nWarning log http://$host/ntpwarnings/\nLog files http://$host/ntplog/";
        print "\n  emailing warning $mail_warning\n";
        smtp_send($mail_warning);
        return;
    }

    # else append to warning log if it already exists (and dont email)

    else {
        open my $WARN, '>>', "$warn_name_txt"
          || carp "can't open file $warn_name_txt\n";
        my $append_warning = shift;

        exit 2 if !print {$WARN} "$append_warning";
        close $WARN or carp "Unable to close $warn_name_txt\n";
        return;
    }
}

## sub to append to log file ##

sub log_append {
    my $append = shift;
    open my $LOG, '>>', $logname
      or carp "log could not be found or opened\n";
    exit 2 if !print {$LOG} "$append";
    close $LOG or carp "Unable to close $logname\n";
    return;
}

# display local host peer information using ntpq
print
"\n*** List of peers used by host $host to set the local clock, via ntpq -p ***\n";
log_append(
"\n*** List of peers used by host $host to set the local clock, using ntpq -p ***\n"
      . "Offset for ntpq is in milliseconds.  Peer offsets are not analysed\n\n"
);

my $pid;    # process id used for waitpid check
eval {
    $pid = open2( \*READ, 0, '/usr/bin/ntpq -p' );
    1;
}
  or die "ntpq command failed, check path to this command\n";

# Ensures process is finished (requires use POSIX)
waitpid $pid, 0;

while (<READ>) {
    print "$_";
    log_append("$_");
}

# system("ntpq -p");    # request peers from local machine

# Fetch reference time and store offset in $ref_offset
# If referecne clock cannot be identified, WARN and try the second external reference
print
"\nFetching comparison time offset from National Physical Laboratory $external_ref1\n";
eval { %response = get_ntp_response($external_ref1) }
  or warn "Could not access $external_ref1\n";
if ( defined $response{'Reference Clock Identifier'} ) {
    print
"Server $external_ref1: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset} \n";
    log_append(
"\n*** Results from $host polling $external_ref1, using Net::NTP, offset used for comparison ***\n"
          . "Server $external_ref1: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}\n"
    );
    $ref_offset = $response{Offset};
    if ( $response{'Leap Indicator'} > 0 ) {
        print
"  *** WARNING External reference is showing leap indicator bit is none zero = $response{'Leap Indicator'} *** \n";
        log_append(
"  *** WARNING Note that external reference $external_ref1 is showing none zero LI = $response{'Leap Indicator'}***\n"
        );
        warn_append(
"$runtime[0] $runtime[1] external reference $external_ref1 is showing none zero LI = $response{'Leap Indicator'}\n"
        );
        $warning++;
    }

}
else {
    print
"  *** WARNING Server $external_ref1 did not respond with a reference clock, trying $external_ref2 ***\n";
    log_append(
"\n*** INFORMATION Server $external_ref1 did not respond with a reference clock, trying $external_ref2 ***\n"
    );

    # If ref1 fails its not a warning ... unless ref 2 also fails so check ref2

    eval { %response = get_ntp_response($external_ref2) }
      or warn "Could not access $external_ref2 either\n";
    if ( defined $response{'Reference Clock Identifier'} ) {
        print
"Server $external_ref2: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset} \n";
        log_append(
"\n*** Results from $host polling $external_ref2, using Net::NTP, offset used for comparison ***\n"
              . "Server $external_ref2: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}\n"
        );
        $ref_offset = $response{Offset};
        if ( $response{'Leap Indicator'} > 0 ) {
            print
"  *** WARNING External reference is showing leap indicator bit is none zero = $response{'Leap Indicator'} *** \n";
            log_append(
"  *** WARNING Note that external reference $external_ref2 is showing none zero LI = $response{'Leap Indicator'} ***\n"
            );
            warn_append(
"$runtime[0] $runtime[1] external reference $external_ref2 is showing none zero LI = $response{'Leap Indicator'}\n"
            );
            $warning++;
        }

    }
    else {
        print
"  *** WARNING Server $external_ref2 did not respond with a reference clock ***\n";
        log_append(
"\n  *** WARNING Server $external_ref2 did not respond with a reference clock either ***\n"
              . "  *** Offset from external reference cannot be found, continuing but using offset: $ref_offset ***\n\n"
        );
        warn_append(
"$runtime[0] $runtime[1] External server $external_ref1 & $external_ref2 did not respond with a reference clock\n"
        );
        $warning++;
    }

}

# poll ntp_servers

print "\nPolling internal servers listed in $ntplist\n";
log_append(
    "\n*** Results from $host polling servers in $ntplist, using Net::NTP ***\n"
      . "Server = Internal NTP server, Ref = Reference clock (time source used by each server)\n"
      . "St = Stratum, Li = Leap Indicator (normally zero)\n"
      . "Precision = Clock quality measured as a power of two e.g. precision=-16 is about 15 microseconds (2^-16 s)\n"
      . "Offset = Offset in secs to $host clock; \n         when compared with offset to external ref, if > $offset_limit secs a warning is flagged\n\n"
);

# Examin internal servers found in @servers list

foreach (@servers) {
    my $server = $_;

    chomp $server;

# To prevent use of uninit value, first server is added to $server list, then additonal servers conct with additional space
    if ( !defined $server_list ) { $server_list = $server; }

# add to server list, to build a space separated variable from the @servers array to be used by ntpdate.
    else {

        $server_list = $server_list . $SPACE . $server;

        # print "server list is $server_list\n";
    }

# system ("time ntpdate -q $server");
#    print "\nTrying to access sysinfo (some servers will not respond to ntpdc):\n";
#    system ("time ntpdc -c sysinfo $server");

    # Clear hash of any previous content before testing next server
    undef %response;
    eval { %response = get_ntp_response($server) }
      or warn "No response from $server\n";

    # enable for debug
    #        print Dumper(\%response);
    if ( defined $response{'Reference Clock Identifier'} ) {
        my $ntp_info =
"Server $server: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}";
        print "$ntp_info\n";

# print
# "Server $server: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset} \n";
        log_append("$ntp_info\n");

# Log offset with influxDB.  Create array for influx insert: 
# database_name, measurement, tagkey1, tagkey2, tagkey3 value

my @insert = (
	$db_name,
	$measurement,
	$server,
	$response{'Reference Clock Identifier'},
	$runtime[2],
	$response{Offset}
	);


infux_insert (@insert);




        if ( $response{'Leap Indicator'} > 0 ) {
            print
"  *** WARNING Leap indicator for $server = $response{'Leap Indicator'} *** \n";
            log_append(
"  *** WARNING Leap indicator for $server = $response{'Leap Indicator'} was detected *** \n"
            );
            warn_append(
"$runtime[0] $runtime[1] Leap indicator for $server = $response{'Leap Indicator'} was detected\n"
            );
            $warning++;
        }

        my $offset_diff = ( $response{Offset} - $ref_offset );
        if ( $offset_diff < 0 ) {
            $offset_diff = $offset_diff * -1;
        }    # Always make diff positive
        if ( $offset_diff > $offset_limit ) {

            print
"  *** WARNING offset difference for $server is $offset_diff and > $offset_limit *** \n";
            log_append(
"  *** WARNING offset difference for $server is $offset_diff and > $offset_limit ***\n"
            );
            warn_append(
"$runtime[0] $runtime[1] offset difference for $server is $offset_diff and > $offset_limit ***\n"
            );
            $warning++;
        }

    }
    else {
        print
"  *** WARNING Server $server did not respond with a reference clock ***\n";
        log_append(
"  *** WARNING Server $server did not respond with a reference clock ***\n"
        );
        warn_append(
"$runtime[0] $runtime[1] Server $server did not respond with a reference clock\n"
        );
        $warning++;
    }
}

# End of foreach @severs

# print "\nServer list is: $server_list\n"; # Enable for debug

# Make a system call using ntpdate as a sanity check against the Net::NTP output
# Enable for debug:
# print
# "\nSanity check local sources with ntpdate -q (query only, don't set clock):\n";
# system("/usr/sbin/ntpdate -q $server_list");

# add results from external internet servers for comparison
print
"\nCompare with results from europe.pool.ntp.org using ntpdate -q (query only, don't set clock):\n";

log_append(
"\n*** Results from europe.pool.ntp.org using ntpdate -q ***\nThese results are not analysed and included for comparison\n\n"
);

eval {
    $pid = open2( \*READ, 0, '/usr/sbin/ntpdate -q europe.pool.ntp.org' );
    1;
}
  or die "ntpdate command failed, check path to this command\n";

# Ensures process is finished (requires use POSIX)
waitpid $pid, 0;

while (<READ>) {
    print "$_";
    log_append("$_");
}

# If warnings present, append count to end of log and change result in web page
if ( $warning > 0 ) {
    print "   \n*** $warning WARNING(S) DETECTED *** \n\n";
    log_append(
"\n\n --- END OF LOG $runtime[0] $runtime[1], $warning WARNING(S) DETECTED ---  \n"
    );
    $results = "WARNINGS FOUND on $runtime[0] at $runtime[1]";
}

# If $warning 0 BUT a historic warning file exists then result is still a warning
# until the warning file is deleted - otherwise result is no warnings on this run
if ( $warning == 0 ) {
    if ( -f $warn_name_txt ) {
        $results = "PREVIOUS WARNINGS PRESENT";
    }
    else {
        $results = "No warnings on $runtime[0] at $runtime[1]";
    }
    print "   \n*** End of test, no warnings detected *** \n\n";
    log_append(
"\n\n --- End of log $runtime[0] $runtime[1], no warnings detected ---  \n"
    );
}

sub create_index {
    my $index_html = << 'HTMLINDEX';
<!doctype html>
<html lang="en">
<head>
<title>NTP offset comparison check</title>
<link rel="stylesheet" href="main.css" type="text/css" media="screen"/>
</head>

<body >
<header>
<hgroup>
<br>
<h1>THE NOC</h1>
<h2>NTP Offset Comparison &amp monitoring script, last run RUNTIME0 RUNTIME1 ...</h2>
<br>
</hgroup>
</header>

<nav>
<ul>
<li><a href="LOGTO" target="_blank">Log Files</a></li>
<li><a href="WARNTO" target="_blank">Warning Files</a></li>
<li>&nbsp &nbsp &nbsp</li>
<li><a href="help.txt" target="_blank">Help</a></li>
<li>&nbsp &nbsp &nbsp</li>
<li><a href="javascript:window.location.reload(true)">Reload page </a></li>


    </ul>
    </nav>
    <article>
    <header>
    <br>
    <h1>RESULTS</h1>
    </header>
    <p> &nbsp </p>
    <p>This script compares <a href="SERVERLIST" target="_blank">internal NTP sources</a> with the National Physical Laboratory and warns if the offset between NPL and local servers exceeds OFFSETLIMIT seconds.  If NPL is not available, Physikalisch-Technische Bundesanstalt (PTB) is used.  A log file is created each time the script runs.  Logs older than 28 days are automatically deleted. View the Log or Warning Files directory by clicking on the navigation bar above or below. Times shown are in UTC.</p>
       <section>
        <header>
        <h1>How it works</h1>
        </header>
        <p>This script runs every hour.  Normally there should be no warnings.  If a warning event is detected, a warnings only log is created &amp appended to on each successive run.  Servers used for offset comparison are:
            <br>EXTERNALREF1
            <br>EXTERNALREF2
            <br>The secondary server will only be used if the primary server is not responding.</p>
            </section>
            <section>
            <header>
            <h1>In the event of warnings</h1>
            </header>
            <p class="next-to-aside">
            A new warning will create a warning log file and send an email alert. A warning condition exists while a current warning file is present.<br>
            No further emails are sent for new warnings; these are appended to the current warning log.<br>
            The warning file is automatically renamed with a date stamp if older than 7 days. Acknowledging the warning date stamps the file name. Once date stamped, the warning file is effectively archived.<br><br>
            <mark>This page will not be updated until the script next runs<br></mark>
                </p>
                <aside>
                <p>
                Clicking 'Acknowledge Warning' archives the current warning file and enables further email alerts</p>
                <FORM ACTION=/cgi-bin/rename.pl target="_blank" METHOD=POST><p>
                <button type="submit">Acknowledge Warning</button></p>
                </aside>
                </section>
                </article>
                <nav>
                <ul>
                <li><a href="LOGTO" target="_blank">Log Files</a></li>
                <li><a href="WARNTO" target="_blank">Warning Files</a></li>
                <li>&nbsp &nbsp &nbsp</li>
                <li><a href="help.txt" target="_blank">Help</a></li>
                <li>&nbsp &nbsp &nbsp</li>
                <li><a href="javascript:window.location.reload(true)">Reload page </a></li>
                    </ul>
                    </nav>
                    <footer>
                    <p>This is a static page and needs to be reloaded after the script next runs to present the latest results.</p>
</footer>
</body>
</html>
HTMLINDEX
    return $index_html;
}

sub create_style {
    my $style_sheet = << 'STYLESHEET';
main.css

* {
    font-family: Arial, Helvetica, sans-serif;
}

mark { 
    background-color: pink;
    color: black;
}

body {
width: 800px;
margin: 0em auto;
font-family: Arial, Helvetica, sans-serif;
}

header h1 {
font-size: 40px;
margin: 0px;
color: #555;
}

header h2 {
    font-size: 15px;
margin: 0px;
color: #777;
    font-style: italic;
}

nav ul {
    list-style: none;
padding: 0px;
display: block;
clear: right;
background-color: #999;
    padding-left: 4px;
height: 22px;
}
nav ul li {
display: inline;
padding: 0px 19px 5px 10px;
height: 22px;
    border-right: 1px solid #ccc;
}

nav ul li a {
color: #009;
    text-decoration: none;
    font-size: 13px;
    font-weight: bold;
}

nav ul li a:hover {
color: #fff;
}


article > header h1 {
    font-size: 30px;
float: left;
    margin-left: 14px;
}

article > header h1 a {
color: #444;
    text-decoration: none;
}

article > section header h1 {
    font-size: 20px;
    margin-left: 25px;
}

article p {
clear: both;
    margin-top: 0px;
    margin-left: 50px;
}

article p.next-to-aside {
width: 500px;
}

article >  section figure {
    margin-left: 180px;
    margin-bottom: 10px;
}

article > section > menu {
    margin-left: 120px;
}

aside p {
position:relative;
left:0px;
top: -50px;
    z-index: 1;
width: 200px;
float: right;
    font-style: italic;
color: #009;
}

footer p {
    text-align: center;
    font-size: 12px;
color: #888;
    margin-top: 24px;
}
STYLESHEET
    return $style_sheet;
}

# CREATE HTML INDEX AND SUBSTITUTE VARIBALES

my $index_content = create_index();

# Replace variable HTML content
$index_content =~ s/RESULTS/$results/;
$index_content =~ s/SERVERLIST/$ntplist/;
$index_content =~ s/LOGTO/$weblogto/g;
$index_content =~ s/WARNTO/$webwarnto/g;
$index_content =~ s/EXTERNALREF1/$external_ref1/;
$index_content =~ s/EXTERNALREF2/$external_ref2/;
$index_content =~ s/OFFSETLIMIT/$offset_limit/;
$index_content =~ s/RUNTIME0/$runtime[0]/;
$index_content =~ s/RUNTIME1/$runtime[1]/;

# write the HTMLINDEX content to the $index file
open my $INDEX, '>', $index
  or carp "$index file could not be found or opened\n";
exit 2 if !print {$INDEX} "$index_content";
close $INDEX or carp "Unable to close $index\n";

# CREATE CSS AND SUBSTUTUTE VARIABLES
my $style = create_style();

# If warnings found, change the grey headings to red (555 is reserved for default headings) OR if a previous warning file exists
if ( ( $warning > 0 ) or ( -f $warn_name_txt ) ) {
    $style =~ s/#555/#F00/g;
}

# write the CSS to the $css file
open my $STYLE, '>', $css
  or carp "$css file could not be found or opened\n";
exit 2 if !print {$STYLE} "$style";
close $STYLE or carp "Unable to close $css\n";

# Check if file exists before find to prevent warning
# Delete log files older than 28 days with a system call

if ( -f $logname ) {

    # print "$logname exists, if other files in $logto older than 28 days delete them\n";
    system("find $logto -mtime +28 -type f -delete");
}

# Optionally delete warning files older than 90 days with a system call
# Warning files are only small - it was decided to keep them indefinitely
# if ( -f $warn_name_txt ) {
# print "\n Deleting old warning file $warn_name_txt if older than 90 days\n";
#    system("find $warnto -mtime +90 -type f -delete");
#}
# else {
# print "\n No warning file $warn_name_txt present\n";
# }

# Throttle the script just in case it ends up in a loop or is repeatedly called
# Together with the flock check this guards agains unintentional DOS to the ntp sources
sleep '1';

exit 0;

__DATA__
DATA is used as the file handle by flock to check if the script is already running.
So dont remove the __data__ token.  There is no spoon.

__END__

Notes:

Check the time zone on the server running this script.

Later Ubuntu server builds
cat /etc/timezone
Europe/London

Earlier builds
cat /etc/timezone
Etc/UTC

Simplest way to change the time zone is by running:
dpkg-reconfigure tzdata

Further reading, National Physical Laboratory its user guide:
http://www.npl.co.uk/upload/pdf/its_user_guide.pdf

SUGGESTED TIME SERVERS

NPL
ntp1.npl.co.uk  139.143.5.30
ntp2.npl.co.uk  139.143.5.31

Physikalisch-Technische Bundesanstalt (PTB) 
ptbtime1.ptb.de
ptbtime2.ptb.de
ptbtime3.ptb.de

To dump the whole NTP packet with Net::NTP
# my %response = get_ntp_response();
# get_ntp_response(<server>, <port>);
  my %response=get_ntp_response("139.143.5.31");
  print Dumper(\%response);

It may be necessary to install nptd
sudo apt-get install ntp

It will be necessary to install Net::NTP
sudo cpanm Net::NTP

SERVER BUILD

Check the build script but it is necessary to:

apt-get update
apt-get upgrade
apt-get install ntp
apt-get install apache2
apt-get install vim
apt-get install perltidy

cpan App::cpanminus
cpanm Net::NTP
cpanm Mail::Mailer
cpanm Regexp::Debugger

mkdir -m 755 /var/www/ntpwarnings
mkdir -m 755 /var/www/ntplog
chown www-data:www-data /var/www/ntpwarnings
# chown required or permissions will not allow rename via cgi

Check document root in:
/etc/apache2/sites-available/000-default.conf
Here we use /var/www/ and not /var/www/html as in later builds

Enable cgi (later Ubuntu)
a2enmod cgi
apache2ctl restart

check paths to /usr/sbin/ntpdate and /usr/bin/ntpq
as these are called via cron

And edit crontab:
0 * * * * /root/ntp_checker.pl > /dev/null

CHECK LOG FILES ARE DELETED

Age files with touch:
touch -d "30 days ago" /var/www/ntp_test_log_30

CHECK INFLUXDB

InfluxDB admin can be found at:
http://hostname:8083/

A few example queries:
CREATE DATABASE timewatch
DROP DATABASE timewatch
SHOW SERIES FROM ntp_offset WHERE server = '192.168.0.1'
SHOW TAG KEYS FROM ntp_offset
select * from ntp_offset where server =~ /10.0.0.*/
select * from /.*/ limit 1  (show first of any series in db)
show stats
Note that the write data box automatically adds the INSERT command.
If influxDB stops, sudo service influxdb restart
