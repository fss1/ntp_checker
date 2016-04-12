#!/usr/bin/perl

use strict;
use warnings;
use English qw(-no_match_vars);
use POSIX qw( strftime );
use IPC::Open2;
use Carp;
use Fcntl qw(:flock);
use Sys::Hostname;
use File::Copy;
use Net::SNMP qw(:asn1);    # For snmp
use File::Slurp;

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

our $VERSION = '0.0.60';

# *** SCRIPT TO POLL INTERNAL NTP SOURCES, CHECK RETURNED OFFSET (AGAINST NPL) AND LEAP INDICATOR ***
# *** WARN IF ANY SOURCE IS OUTSIDE OFFSET LIMIT, UNAVAILABLE OR HAS THE LI SET ***

# MAKE LIST OF NTP SERVERS IN A FILE CALLED internal_ntp_servers_list.txt ($ntplist), one IP per line

# DEFINE FILE NAME AND PATHS HERE- remember to delimit forward slashes
# e.g.  "\/home\/user\/$filename" or use single quotes if no variable involved '/home/user/';

# SMTP SERVER/RELAY - email alert relay & addresses
my $mailaddress = 'your_company_email_relay';
my $mailto      = 'alerts@domain.com';

# $mailcc will take comma separate multiple addresses.  'reports@domain.com, support@domain.com'
my $mailcc = 'support@domain.com';

# SNMP trap configuations
# SNMP HOST.  Define the snmp trap destination
my $snmp_host = '10.1.2.3';

# SNMP COMMUNITY. Set the community string to match that expected by the trap receiver
my $snmp_community = "public";

# SNMP OID. Set the object identifier.group.generic.specific, values
# This is not checked for validity and will be sent as defined here:
# e.g. snmp_oid="1.3.6.1.4.1.16924.6.6.6"
my $snmp_oid = '1.3.6.1.4.1.16924.217';
my $generic  = '6';      # type 6 corresponds to "enterpriseSpecific"
my $specific = '666';    # none negative integer as trap value

# File containing list of internal servers (one per line)
my $ntplist = 'internal_ntp_servers_list.txt';

# Restrict servers in the list above from sending emails
# File containing list of restricted internal servers (one per line)
# A pattern match from this list in the warning will prevent the warning from email alerting
# Logs will still be created. Web page will still show warning state - just no email
my $ntp_restrict = 'restricted_ntp_servers.txt';

# name for log files (as required date_stamp.txt extension will be created/appended)
my $logname   = 'ntp_test_log';
my $warn_name = 'ntp_warn_log';

# name for web link to log files
my $weblogto  = 'ntplog';
my $webwarnto = 'ntpwarnings';

# ports required for links to influx and grafana home pages
my $webinflux  = ':8083';
my $webgrafana = ':3000';

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

# Ref server needs a 'plot' name for visulisation purposes (may be either external_ref1 or 2)
my $ref_server = 'ref_server';

# Define the offset limit allowed - i.e. TIME DIFFERENCE ALLOWED BETWEEN INTERNAL AND EXTERNAL REF
my $offset_limit = 0.3;    # Offset difference in seconds

# influxDB parameters

# Database name (table name)
my $db_name = 'timewatch';

# Measurement will be, time_offset; row name for database defined here:
my $measurement = 'ntp_offset';

# Absolute offset calculation takes the absolute difference
# between ntp_offset and external reference servers offset.  Define row name for databse here:
my $abs_measurement = 'abs_offset';

# For single stat, +ve version of time_offset with exceptions 666,667; row/measurement name defined here:
my $poffset = 'poffset';

# To view exteme meausrements of offset in the server pool, row/measurement is defined as:
my $maxoffset = 'maxoffset';

# Suggested value for poffset limits in Grafana Singlestat
# 0 > Green, > 0.3 Orange, 0.5 > Red
# Not available 666, LI set 667

# variable to hold max positive offset found, undef until first value set
undef my $maxpos;

# variable to hold max minimum offset found, undef until first value set
undef my $maxneg;

my $EMPTY = qw{};
my $SPACE = " ";

# If any condition increments $warn, an email should be generated.
my $warning = 0;

# variable to hold server list as scalar used by ntpdate
my $server_list;

# variable to hold the reference offset from external server used for absolute difference comparisons
my $ref_offset = '0';

# variable to hold ntp packet responses
my %response;

# populate array @servers with ip list from server list
my @servers = ();

# populate array @restricted with list from restricted server list
my @restricted = ();

# variable to hold the result message shown on the web page
my $results;

# $host takes hostname of system running this script from Sys::hostname
my $host = hostname;

# verbosity level.  Zero is no output.
my $verbosity = '0';

# Array to hold influxDB insert values
my @insert = ();

# BEFORE WE BEGIN, go flock yourself ...
## ENSURE ONLY ONE VERSION OF THIS SCRIPT IS RUNING ##

open DATA, '<', $PROGRAM_NAME or croak "Couldn't open script: $OS_ERROR";
flock DATA, LOCK_EX | LOCK_NB
  or croak
"This script $PROGRAM_NAME is already running.  All those moments will be lost in time, like tears in rain. Time to die";

# Don't close the file handle until the program end. Critic will complain about file handles not closed quickly but in this case its necessary as a duplicate process check

# Check for warning file from previous run
# slurp last run warning if present, then delete it
if ( -f 'warning_from_last_run.txt' ) {
    my $warn_last = read_file('warning_from_last_run.txt');
    unlink 'warning_from_last_run.txt'
      or warn "\n  warning_from_last_run.txt could not be deleted\n";

# print "\n Found warning_from_last_run.txt, read it, deleted it \n File contained: \n$warn_last \n\n";
}

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
"** This is an automated error message from TIMEWATCH, hosted on $host **\n\n This report was created by $PROGRAM_NAME, version V$VERSION\n\n";
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
                'From'    => 'Timewatch<do_not_reply@notnownotever>',
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

## SUB TO SEND SNMP ERROR TRAPS ##

# similar to:
# snmptrap -v 1 -c public <trap_destination_ip> .1.3.6.1.4.1.16924.217 "" 6 666 "" .1.3.6.1.4.1.16924.237 s "allworkandnoplay..."
# with a variation between the book and the film

sub snmp_send {
    my $message = shift;    # Text string used for trap
    chomp $message;         # Remove newline from message
    my $timeticks = time;   # Time stamp for Uptime added to the trap

    my ( $session, $error ) = Net::SNMP->session(
        -hostname  => $snmp_host,
        -community => $snmp_community,
        -version   => 'snmpv1',
        -port      => '162'
    );

    if ( !defined $session ) {
        printf "Session error: %s.\n", $error;
        exit 1;
    }

    my @oids = ( $snmp_oid, OCTET_STRING, $message )
      ; # OCTET_STRING requried for a text STRING to be sent (other types are INTEGER, INTERGER32 etc)

    my $result = $session->trap(
        -generictrap  => $generic,
        -specifictrap => $specific,
        -timestamp    => $timeticks,
        -varbindlist  => \@oids
    );

    if ( !defined $result ) {
        printf "result error: %s.\n", $session->error;
        $session->close;
        exit 1;
    }

    $session->close;
    return;

}    # End of SNMP sub.

## SUB TO WRITE TO INFLUXDB ##

sub influx_insert {

# TagKey1 = server, TagKey2 = reference, TagKey3= runtime
# Value is the ntp offset between local clock and the polled server
# insert_array should contain, database_name, measurement, tagkey1, tagkey2, tagkey3 value

    my @insert_array = @_;

# Enable print and none surpressed version of the curl system call for debug:
# print "  creating POST to db $insert_array[0], parameter $insert_array[1], server $insert_array[2], Ref $insert_array[3], offset value $insert_array[4] \n";
# system ("curl -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2],ref=$insert_array[3] value=$insert_array[4]\"");

    system(
"curl -s -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2],ref=$insert_array[3] value=$insert_array[4]\" > /dev/null"
    );

    return;

    # End of influx_insert
}

## SUB TO WRITE SINGLE STAT TO INFLUX FOR GRAFANA ##

sub influx_single {

# TagKey1 = server,
# Value is the positive ntp offset
# insert_array should contain; database_name, measurement(positive offset, $poffset), tagkey1, value

    my @insert_array = @_;

    # Make value always positive
    if ( $insert_array[3] < 0 ) {
        $insert_array[3] = $insert_array[3] * -1;
    }

# Enable print and none surpressed version of the curl system call for debug:
# print "  creating POST to db $insert_array[0], parameter $insert_array[1], server $insert_array[2], positive offset value $insert_array[3] \n";
# system ("curl -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2] value=$insert_array[3]\"");

    system(
"curl -s -i -X POST \"http://localhost:8086/write?db=$insert_array[0]\" --data-binary \"$insert_array[1],server=$insert_array[2] value=$insert_array[3]\" > /dev/null"
    );

    return;

    # End of influx_single
}

## SUB TO CREATE A MAX POSITIVE AND MAX NEGATIVE OFFSET VALUE ##

sub max_offset {
    my $max = shift;
    if ( !$maxpos ) {

        # print "\n maxpos was not defined so takes the first value of $max\n";
        $maxpos = $max;
    }
    if ( $max > $maxpos ) {
        $maxpos = $max;

        # print "\n new max pos is $maxpos\n";
    }
    if ( !$maxneg ) {

       #   print "\n maxneg was not defined so takes the first value of $max\n";
        $maxneg = $max;
    }
    if ( $max < $maxneg ) {
        $maxneg = $max;

        # print "\n new max neg is $maxneg\n";
    }
    return;
}

# end of max_ offset sub

# Check command line arguments

die "Only one argument allowed. Use -h to see options\n" if @ARGV > 1;

if ( !defined $ARGV[0] ) {
    $verbosity = '0';
    print
"\n  $PROGRAM_NAME V$VERSION running at: $runtime[0] $runtime[1] \n  use -v for verbose, -h for help, -m for mail test -s for snmp test\n\n";
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
       -s SNMP send test
       
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
       Offset = offset of server compared to local clock 
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

# If ARGV -h print the help page

if ( defined( $ARGV[0] ) && $ARGV[0] eq '-h' ) {
    print "$help";
    exit 0;
}

# if -v, set verbosity flag
elsif ( defined( $ARGV[0] ) && $ARGV[0] eq '-v' ) { $verbosity = '1'; }

# If ARGV -m send a test mail

elsif ( defined( $ARGV[0] ) && $ARGV[0] eq '-m' ) {
    print "\n Sending test email to $mailto\n\n";
    my $testmessage =
"This is a test message sent to $mailto via smtp relay at $mailaddress\n\nFor more detail check:\nTIMEWATCH homepage http://$host\nWarning log http://$host/ntpwarnings/\nLog files http://$host/ntplog/";
    smtp_send($testmessage);
    exit 0;
}

# If ARGV -s send a test trap

elsif ( defined( $ARGV[0] ) && $ARGV[0] eq '-s' ) {
    print "\n Sending test trap to $snmp_host\n\n";
    my $snmp_warning =
"This is a test trap from $PROGRAM_NAME version $VERSION sent to $snmp_host. Visit http://$host for more details";
    snmp_send($snmp_warning);
    exit 0;
}

# If ARGV defined but none of the above, dont run and print the unrecognised switch

elsif ( defined( $ARGV[0] ) ) {
    print "\n That option was not recognised, use -h for vaid options\n\n";
    exit 0;
}

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

# write the HELPHTML content to the $index file
open my $HELPTXT, '>', $helptxt
  or carp "$helptxt file could not be found or opened\n";
exit 2 if !print {$HELPTXT} "$help";
close $HELPTXT or carp "Unable to close $help\n";

# Read the ntp source servers list into the array @servers
# skip empty or lines begginging space or #
# chomp; only removes current input record separator but if originated from Windows ...

open my $SERVERS, '<', "$ntplist"
  or croak
"server list file wont open, check $ntplist path and filename are correct: $!";
while (<$SERVERS>) {
    $_ =~ s/\r?\n$//xms;
    next
      if ( $_ =~ m/^\s+/xms ) || ( $_ =~ m/^\#+/xms ) || ( $_ =~ m/^\s*$/xms );
    push( @servers, $_ );
}
close $SERVERS or croak "server list file wont close: S!";

# Read restricted servers into @restricted
# A pattern match in the warning string prevents the warning from logging
# or raising an email alert.  Empty lines or lines beginning # are skipped

open my $RESTRICTIONS, '<', "$ntp_restrict"
  or warn
"Restrected server list file wont open, check $ntp_restrict path and filename are correct: $!";
while (<$RESTRICTIONS>) {
    $_ =~ s/\r?\n$//xms;
    next
      if ( $_ =~ m/^\s+/xms ) || ( $_ =~ m/^\#+/xms ) || ( $_ =~ m/^\s*$/xms );
    push( @restricted, $_ );
}
close $RESTRICTIONS or warn "restricted file list wont close: S!";

# print join (", ", @servers); # debug line to print servers array

# copy ntplist to www root, to make it visible to web gui
copy( "$ntplist", "/var/www/$ntplist" ) or carp("copy of $ntplist failed");

# copy restriction list to www root, for access via web gui
copy( "$ntp_restrict", "/var/www/$ntp_restrict" )
  or carp("no restrict file found $ntp_restrict");

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

    # read warning string passed to sub into add_warning
    my $add_warning = shift;

    # Add this warning to the last_warning file
    last_warning($add_warning);

    # if warning log does not exist, create it, include the header
    if ( !-f $warn_name_txt ) {

        # print "\n $warn_name_txt did not exist so adding header\n";
        # Open log file for write - print an opening header to the file:
        open( my $WARN, '>', "$warn_name_txt" )
          || carp "can't open file $warn_name_txt\n";
        print $WARN
"\n  --- START OF WARNINGS LOG from $PROGRAM_NAME V$VERSION ---\n  --- first written at: $runtime[0] $runtime[1] ---\n  --- Offset limit used between reference and internal server = $offset_limit seconds ---\n  --- External reference used is $external_ref1 or $external_ref2 ---\n  --- For the full log check $logto ---\n  --- This script was run from host: $host ---\n\n";

        # now add the warning to the header
        exit 2 if !print {$WARN} "$add_warning";
        close $WARN || warn "Cannot close $warn_name_txt\n";

# email this warning here so it is only sent when the warning log file is first created
# check warning does not contain any servers (or other matching patterns) from the restricted servers list
# retrun if match is found, without sending email
        foreach (@restricted) {
            my $restrict = $_;
            if ( $add_warning =~ /\Q$restrict\E/ ) {
                print
"  *** $restrict is in the restricted list - no email was sent\n";
                return;
            }
        }
        my $mail_warning =
"$add_warning\nTHIS IS THE FIRST WARNING OF POSSIBLY MANY - ONLY A SINGLE EMAIL IS SENT UNTIL THE WARNING(S) ARE ACKNOWLEDGED\n\nFor more detail check:\nTIMEWATCH hompage http://$host\nWarning log http://$host/ntpwarnings/\nLog files http://$host/ntplog/";
        print "\n  emailing warning $mail_warning\n";
        smtp_send($mail_warning);

        # snmp trap sends $add_warning as the trap string
        snmp_send($add_warning);
        return;
    }

    # else append to warning log if it already exists (and dont email)

    else {
        open my $WARN, '>>', "$warn_name_txt"
          || carp "can't open file $warn_name_txt\n";

        exit 2 if !print {$WARN} "$add_warning";
        close $WARN or carp "Unable to close $warn_name_txt\n";
        return;
    }
}

## sub to create or append to warning_from_last_run.txt ##

sub last_warning {

    my $last_warn = shift;

    #  If this existed before the script ran it was deleted earlier

# Open log last warning file for create or append
# print "\n  about to create or append to warning_from_last_run file ....  \n\n";
    open( my $LASTWARN, '>>', 'warning_from_last_run.txt' )
      || carp "  can't open warning_from_last_run.txt file\n";

    # now add the warning warning
    exit 2 if !print {$LASTWARN} "$last_warn";
    close $LASTWARN || warn "  Cannot close warning_from_last_run.txt \n";
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

# display local host peer information using ntpq NOT used as ntpd is run on demand for timewatch2 to prevent clock being set while comparison in progress

#print
#"\n*** List of peers used by host $host to set the local clock, via ntpq -p ***\n";
#log_append(
#"\n*** List of peers used by host $host to set the local clock, using ntpq -p ***\n"
#      . "Offset for ntpq is in milliseconds.  Peer offsets are not analysed\n\n"
#);

my $pid;    # process id used for waitpid check

# system("ntpq -p") request peers from local machine if ntpd was running

# eval {
#     $pid = open2( \*READ, 0, '/usr/bin/ntpq -p' );
#    1;
# }
#  or die "ntpq command failed, check path to this command\n";

# Ensures process is finished (requires use POSIX)
# waitpid $pid, 0;

# while (<READ>) {
#    print "$_";
#    log_append("$_");
# }

# Fetch reference time and store offset in $ref_offset
# If referecne clock cannot be identified, WARN and try the second external reference

print
"\nFetching comparison time offset from National Physical Laboratory $external_ref1\n";

# Ensure ntpd is not currently synchronizing - wait until its synchronised with ntp-wait
# ntp-wait will continue if ntpd is not running.  -v is used here to print output to terminal
system 'ntp-wait -v';

print
"\nFetching comparison time offset from National Physical Laboratory $external_ref1\n";
eval { %response = get_ntp_response($external_ref1) }
  or warn "Could not access $external_ref1\n";

# test Leap Indication by forcing LI bit here
# $response{'Leap Indicator'} = 1;

if ( defined $response{'Reference Clock Identifier'} ) {
    print
"Server $external_ref1: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay}\n";
    log_append(
"\n*** Results from $host polling $external_ref1, using Net::NTP, offset used for comparison ***\n"
          . "Server $external_ref1: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay}\n"
    );

    # Insert selected values to influxDB
    @insert = (
        $db_name, $measurement, $ref_server,
        $response{'Reference Clock Identifier'},
        $response{Offset}
    );

    # insert to influxdb
    influx_insert(@insert);

    # no check for  largest offset for external ref

    # creeate single stat value to influxDB for Grafana

    @insert = ( $db_name, $poffset, $ref_server, $response{Offset} );

    influx_single(@insert);

    $ref_offset = $response{Offset};
    if ( $response{'Leap Indicator'} > 0 ) {
        print
"  *** WARNING External reference is showing leap indicator bit is none zero = $response{'Leap Indicator'} *** \n";
        log_append(
"  *** WARNING Note that external reference $external_ref1 is showing none zero LI = $response{'Leap Indicator'}***\n"
        );

# For Grafana Singlestat, 667 is used to create a value to text mapping for LI set
        @insert = ( $db_name, $poffset, $ref_server, 667 );

        influx_single(@insert);
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
"Server $external_ref2: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay} \n";
        log_append(
"\n*** Results from $host polling $external_ref2, using Net::NTP, offset used for comparison ***\n"
              . "Server $external_ref2: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay}\n"
        );

        # Insert selected values to influxDB
        @insert = (
            $db_name, $measurement, $ref_server,
            $response{'Reference Clock Identifier'},
            $response{Offset}
        );

        # insert to influxdb
        influx_insert(@insert);

        # no check for largest offset with external ref

        # For Grafana Singlestat, a positive offset is created
        @insert = ( $db_name, $poffset, $ref_server, $response{Offset} );

        influx_single(@insert);

        $ref_offset = $response{Offset};
        if ( $response{'Leap Indicator'} > 0 ) {
            print
"  *** WARNING External reference is showing leap indicator bit is none zero = $response{'Leap Indicator'} *** \n";
            log_append(
"  *** WARNING Note that external reference $external_ref2 is showing none zero LI = $response{'Leap Indicator'} ***\n"
            );

# For Grafana Singlestat, 667 is used to create a value to text mapping for LI set
            @insert = ( $db_name, $poffset, $ref_server, 667 );

            influx_single(@insert);
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

# For Grafana Singlestat, 666 is used to create a value to text mapping for Not Available, N/A
        @insert = ( $db_name, $poffset, $ref_server, 666 );

        influx_single(@insert);

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

# To prevent use of uninit value, first server is added to $server list, then additonal servers concat with additional space
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

# Ensure ntpd is not currently synchronizing - wait until its synchronised with ntp-wait
    system 'ntp-wait';

    eval { %response = get_ntp_response($server) }
      or warn "No response from $server\n";

    # enable for debug
    #       print Dumper(\%response);
    if ( defined $response{'Reference Clock Identifier'} ) {
        my $ntp_info =
"Server $server: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay}";
        print "$ntp_info\n";

# print
# "Server $server: Ref $response{'Reference Clock Identifier'}, St $response{Stratum}, Li $response{'Leap Indicator'}, Precision $response{Precision}, Offset $response{Offset}, Delay $response{Delay}\n";
        log_append("$ntp_info\n");

        # Log offset with influxDB.  Create array for influx insert:
        # database_name, measurement, tagkey1, tagkey2, tagkey3 value

        @insert = (
            $db_name, $measurement, $server,
            $response{'Reference Clock Identifier'},
            $response{Offset}
        );

        # insert to influxdb
        influx_insert(@insert);

        # check if this is the largest offset so far
        max_offset( $response{Offset} );

        # create a single stat insert with positive only offset/666,667 status
        @insert = ( $db_name, $poffset, $server, $response{Offset} );

        influx_single(@insert);

        if ( $response{'Leap Indicator'} > 0 ) {
            print
"  *** WARNING Leap indicator for $server = $response{'Leap Indicator'} *** \n";
            log_append(
"  *** WARNING Leap indicator for $server = $response{'Leap Indicator'} was detected *** \n"
            );

# For Grafana Singlestat, 667 is used to create a value to text mapping for LI set
            @insert = ( $db_name, $poffset, $ref_server, 667 );

            influx_single(@insert);
            warn_append(
"$runtime[0] $runtime[1] Leap indicator for $server = $response{'Leap Indicator'} was detected\n"
            );
            $warning++;
        }

# For comparison with the limit, the offset difference is made positive by taking the absolute value
        my $abs_diff = 0;

# calcutale absolute (always positive difference) between offset response and reference offset
        $abs_diff = abs( $response{Offset} - $ref_offset );

# timewatch2 adds the second plot for absolute difference from external reference
# create an entry for $abs_measurement

        @insert = (
            $db_name, $abs_measurement, $server,
            $response{'Reference Clock Identifier'}, $abs_diff
        );

  # print " \n $abs_measurement being added to $db_name, value is $abs_diff \n";
  # insert to influxdb
        influx_insert(@insert);

# print "\n ref offset is: $ref_offset, response is $response{Offset}, absolute difference is $abs_diff\n";
        if ( $abs_diff > $offset_limit ) {

            print
"  *** WARNING absolute offset difference for $server from external ref is $abs_diff and > $offset_limit limit setting *** \n";
            log_append(
"  *** WARNING absolute offset difference for $server from external ref is $abs_diff and > $offset_limit limit setting ***\n"
            );
            warn_append(
"$runtime[0] $runtime[1] absolute offset difference for $server from external ref is $abs_diff and >  $offset_limit limit setting ***\n"
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

        # If no ref clock, set offset value to 666 (no reponse indicator)

        @insert = ( $db_name, $poffset, $server, 666 );

        influx_single(@insert);

        warn_append(
"$runtime[0] $runtime[1] Server $server did not respond with a reference clock\n"
        );
        $warning++;
    }
}

# End of foreach @severs

## Further database additions

## Write max_positive and max_negative offset values found (with sub max_offset) from all servers to database
# print "\n max offsets (+,-) found are: $maxpos,$maxneg \n";
system(
"curl -s -i -X POST \"http://localhost:8086/write?db=$db_name\" --data-binary \"$maxoffset,server=maxpos_server value=$maxpos\" > /dev/null"
);
system(
"curl -s -i -X POST \"http://localhost:8086/write?db=$db_name\" --data-binary \"$maxoffset,server=maxneg_server value=$maxneg\" > /dev/null"
);

# To TEST influx/grafana exception cases, force $poffset value here:
# @insert = ( $db_name, $poffset, '192.168.41.2', 667 );
#        influx_single(@insert);

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

<body onload="javascript:setTimeout(function(){ location.reload(); },5000);">
<header>
<hgroup>
<br>
<h1>TIMEWATCH</h1>
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
        <p>This script runs every 15 minutes.  Normally there should be no warnings.  If a warning event is detected, a warnings only log is created &amp appended to on each successive run.  Servers used for offset comparison are:
            <br>EXTERNALREF1
            <br>EXTERNALREF2
            <br>The secondary server will only be used if the primary server is not responding.</p>
            </section>
            <section>
            <header>
            <h1>In the event of alerts and warnings</h1>
            </header>
            <p class="next-to-aside">
            Alerting can be prevented for <a href="RESTRICTEDLIST" target="_blank">selected servers</a>.   
            A new warning will create a warning log file and send an email/SNMP alert. A warning condition exists while a current warning file is present.<br>
            No alerts are sent for further warnings but these are appended to the current warning log.<br>
            The warning file is automatically renamed with a date stamp if older than 7 days. Acknowledging the warning date stamps the file name. Once date stamped, the warning file is effectively archived.
            <br>For a graphical view, log into Grafana (port 3000) with user and password 'timewatch' 
            </p>
                <form> <p class="next-to-aside">
	        <input TYPE="button" VALUE="Graphical View"
	        onclick="window.open('http://HOST:3000','_blank')"> </p>
                </form>
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
                    <p>This page reloads every 5 seconds but only shows the status when Timewatch last ran</p>
</footer>
</body>
<head>
<link rel="stylesheet" href="main.css" type="text/css" media="screen"/>
</head>
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
$index_content =~ s/RESTRICTEDLIST/$ntp_restrict/;
$index_content =~ s/LOGTO/$weblogto/g;
$index_content =~ s/WARNTO/$webwarnto/g;
$index_content =~ s/EXTERNALREF1/$external_ref1/;
$index_content =~ s/EXTERNALREF2/$external_ref2/;
$index_content =~ s/OFFSETLIMIT/$offset_limit/;
$index_content =~ s/RUNTIME0/$runtime[0]/;
$index_content =~ s/RUNTIME1/$runtime[1]/;
$index_content =~ s/HOST/$host/;

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

    # Dont use the x option here as # is not a comment its a value to be matched
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

Note that the write data box automatically adds the INSERT command.

