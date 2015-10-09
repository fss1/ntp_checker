#!/usr/bin/perl

use strict;
use warnings;
# use English qw(-no_match_vars);
use POSIX qw( strftime );
# use Unix::SetUser;

# use Carp;
# use File::Copy;

# rename warnings.txt file with warnings_timestamp.txt

# fss1138 ta liamg tod moc
# COPYRIGHT AND LICENSE
# Copyright (C) 2015, fss1138.

# This program is free software; you
# can redistribute it and/or modify it
# under the same terms as Perl 5.14.0.

# This program is distributed in the hope that it will be
# useful, but without any warranty; without even the implied
# warranty of merchantability or fitness for a particular purpose.

my $warnto = "\/var\/www\/ntpwarnings\/";
# my  $warnto = "\/usr\/lib\/cgi-bin\/ntpwarnings\/";
my $warn_name = "ntp_warn_log";
my $fail = 0;

our $VERSION = '0.0.29';
use CGI qw/ fatalsToBrowser /;
use CGI::Carp;

# create a warining file name with path and new name with time stamp
my $tstring = strftime( '%d%m%Y%H%M%S', localtime );
my $new_name =  $warnto . $warn_name . '_' . $tstring .'.txt';
my $warn_name_txt = $warnto . $warn_name.'.txt';

# set_user('root'); 
# this creates an operation not permitted message when run via a web call

if (-f $warn_name_txt) {
rename $warn_name_txt, $new_name or $fail = 1;

# No response is required from the browser so tried 204 No Content
# and not the more usual "Content-type: text/html\n\n"
# print "HTTP/1.0 204 No Content\n\n";
# gave the internal server error due to header so tried:
# print "Expires: 0\n";                # Expire immediately
# print "Pragma: no-cache\n";          # Work as NPH
# and that did not work.  Contente-type: text/html on its own gives a blank page

# if rename fails generate browser output with user id
if ($fail eq 1){
print "Content-type: text/html\n\n";
print "rename failed: $! running as user id: $>";
die "<br>program terminated";
}
# or rename was suuccessful, so declare success 
print "Content-type: text/html\n\n";
print "Warnings have been reset by renaming the warning log file<br><br>$warn_name_txt has been renamed to: <br>$new_name<br><br>Current NTP status will not show until the script next runs (usually on the hour)<br><br>The first new warning will send an email alert and begin a new warning log<br>Old warning logs can only be deleted by the systems administrator";
}
# else -f is false and it was not present so  
else {
print "Content-type: text/html\n\n";
print "A currently active warning log could not be found<br>There will be no warning log if warnings are not present!<br>The file $warn_name_txt does not appear to be available<br>Try reloading the previous page to reflect the current status as there is no recent warning log";
}



exit 0;

__END__

cgi bin is /usr/lib/cgi-bin
log is /var/log/apache2/error.log

chown www-data:www-data /var/www/ntpwarnings 

or the file cannot be renamed and there will be a permissions error. Using -T did not resolve.
On the test system, www-data had an id of 33

setuid by chmod 4777 or chmod a+x,s+u sets the user id but may be ignored for scripts without a helper program
suidperl via perl-suid is no longer in Ubuntu build under test.
Unix::SetUser gave an operation not permitted! when run from web page.



NOTES:

<a href="http://address/cgi-bin/myscript.cgi">Run my script</a>

#!/usr/bin/perl -wT

# ensure all fatals go to browser during debugging and set-up
# comment this BEGIN block out on production code for security
BEGIN {
    $|=1;
    print "Content-type: text/html\n\n";
    use CGI::Carp('fatalsToBrowser');

if (submission_ok) {
print "HTTP/1.0 204 No Content\n\n";
}
else {
print &error_page;
}
