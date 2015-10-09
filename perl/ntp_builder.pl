#! /usr/bin/perl
use strict;
use warnings;
use Carp;
use English qw(-no_match_vars);

# fss1138 ta liamg tod moc
# COPYRIGHT AND LICENSE
# Copyright (C) 2015, fss1138.

# This program is free software; you
# can redistribute it and/or modify it
# under the same terms as Perl 5.14.0.

# This program is distributed in the hope that it will be
# useful, but without any warranty; without even the implied
# warranty of merchantability or fitness for a particular purpose.

# This is a build script for Ubuntu 64 bit server 12.04/14.04/15.04
# intended for hosting the ntp_checker script

our $VERSION = '0.0.06';

print << "GREETINGS";
   
      *** This is the ntp_checker build script ****
         
   This script $PROGRAM_NAME V$VERSION 
   sets up an environment for ntp_checker running on Ubuntu.
     
GREETINGS

# UNIX ENVIRONMENT - UPGRADE AND ADDITIONS

# install hh command, hstr https://github.com/dvorka/hstr, bash search history on steroids
print "\n Adding repository for hh\n";
system 'add-apt-repository ppa:ultradvorka/ppa';

# to make this active, apt-get update at some point before install hh

print "\n Updating with apt-get\n";
system 'apt-get update';

print "\n Installing hh\n";
system 'apt-get install hh';

print "\n Now upgrading..... \n";
system 'apt-get upgrade';

print "\n Installing tree command\n";
system 'apt-get install tree';

print "\n Installing git-core\n";
system 'sudo apt-get install git-core';

# git-core has been renamed to just git

print "\n Installing NTP\n";
system 'apt-get install ntp';

print "\n Installing apache2\n";
system 'apt-get install apache2';

print "\n Installing PerlTidy\n";
system 'apt-get install perltidy';

# create directories

print "\n creating /var/www/ntpwarnings\n";
system 'mkdir -m 755 /var/www/ntpwarnings';

print "\n creating /var/www/ntplog\n";
system 'mkdir -m 755 /var/www/ntplog';

# chown required or permissions will not allow rename or warning log via cgi call from a browser button

print
"\n change ownership of dir to alow write via cgi\n chown www-data:www-data /var/www/ntpwarnings\n";
system 'chown www-data:www-data /var/www/ntpwarnings';

## DEV ENVIRONMENT ##

print "\n Installing cpanm\n";
system 'apt-get install cpanminus';

print "\n Installing 'make'\n";
system 'apt-get install make';

print "\n Installing rxrx\n";
system 'cpanm Regexp::Debugger';

print "\n Installing Mail::Mailer\n";
system 'cpanm Mail::Mailer';

print "\n Installing Net::NTP\n";
system 'cpanm Net::NTP';

print "\n Fetching rename cgi script\n";
system 'wget https://raw.githubusercontent.com/fss1/ntp_checker/master/perl/rename.pl';

sub old_apache {

  # For backward compatibility keep the old (Ubuntu 12) apache document root
  # Change this back to /var/www in the conf file if its /var/www/html
  # slurp conf into $new_conf, substitute /var/www/html with /var/www (if found)
  # Also enable cgi-bin as this is not on by default anymore

    my $new_conf;    # variable to hold config
    if ( !open my $DOCROOT,
        '<', '/etc/apache2/sites-available/000-default.conf' )
    {
        print
"\n /etc/apache2/sites-available/000-default.conf  would not open for reading \n";
    }
    else {
        print "\n reading /etc/apache2/sites-available/000-default.conf \n";
        $new_conf = do { local $INPUT_RECORD_SEPARATOR = undef; <$DOCROOT> };
        $new_conf =~ s!/var/www/html!/var/www!xms;
        close $DOCROOT or carp "Unable to close new_conf ";
    }

    #  Now overwrite the file
    if ( !open my $NEWROOT,
        '>', '/etc/apache2/sites-available/000-default.conf' )
    {
        print
"\n /etc/apache2/sites-available/000-default.conf  would not open for writing \n";

    }
    else {
        print
"\n writing /etc/apache2/sites-available/000-default.conf with doc root /var/www\n";
        print $NEWROOT "$new_conf";
        close $NEWROOT or carp "Unable to close new_conf ";
        return '2';
    }
    return '0';
}

# end of sub old_doc_root

print "\n Enabling cgi-bin\n";
system 'sudo a2enmod cgi';

# change the doc root to var/www and enable apache
old_apache();

print "\n taking a 5 second nap before restarting apache ...\n";
sleep 5;

# restart apache to make any changes active
print "\n Restarting Apache\n";
system 'apache2ctl restart';

# edit crontab to provide hourly execution of the checker script
print
" Editing crontab, use crontab -e to change\n 0 * * * * /root/ntp_checker.pl > /dev/null \n if required \n";

system 'crontab -l > cronaddition';
system "echo '0 * * * * /root/ntp_checker.pl > /dev/null' >> cronaddition";
system 'crontab cronaddition';

print "\n setting permissions for rename cgi script \n";
system 'chown www-data:www-data /usr/lib/cgi-bin/rename.pl';

print "\n make rename script executable\n";
system 'chmod 755 /usr/lib/cgi-bin/rename.pl';


system "dpkg-reconfigure -f noninteractive tzdata";
print
"\n Change the time zone to UTC if this is not the current setting\n with:  dpkg-reconfigure tzdata \n";

print "\n End of script \n";

exit 0;

__END__

Now add the rename script and
chown www-data:www-data /usr/lib/cgi-bin/rename.pl

ntp_check.pl has a build script ntp_check_builder.pl but also requires:

1.  internal_ntp_servers_list.txt
a file containing a line be line list of IP/Hostnames to check.
If the server list file wont open or cannot be found the script will abort.

2.  rename.pl in /usr/lib/cgi-bin
a script to rename the warnings file and as a result of this 
renaming, allows further emails to be sent on the next warning


The build script will install and configure:
Apache2 configured to run cgi with a doc root of /var/www.
crontab configured to run ntp_checker as required.  
The ntp_check_builder.pl build script sets this to every hour.

A point of note regarding cgi:
hostname/cgi-bin/  >  Not Found then cgi is probably not
hostname/cgi-bin/  >  Forbidden then cgi is probably running
Apparently cgi is not enabled by default anymore so the script enables this.
/etc/apache2/mods-enabled/ should have a symlink cgi.load added by a2enmod cgi.
man a2enmod and a2dismod for more information.

sudo a2enmod cgi
Your MPM seems to be threaded. Selecting cgid instead of cgi.
Enabling module cgid.

To activate the new configuration, you need to run:
service apache2 restart

Note that html and css files are generated on the fly, when the check script runs.

ntp_checker script has the following command line options:
-v for verbose, -h for help, -m for mail test
Although a primative web page is generated, it is possible to
simply run the check script at command line without Apache running.

For testing the checker script cleans up old files correctly,
age the log files with touch, e.g.
touch -d "2 weeks ago" /var/www/ntpwarnings/ntp_warn_log.txt
