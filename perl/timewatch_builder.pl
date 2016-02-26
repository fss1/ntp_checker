#! /usr/bin/perl
use strict;
use warnings;
use Carp;
use English qw(-no_match_vars);
use Sys::Hostname;

# fss1138 ta liamg tod moc
# COPYRIGHT AND LICENSE
# Copyright (C) 2015, fss1138.

# This program is free software; you
# can redistribute it and/or modify it
# under the same terms as Perl 5.14.0.

# This program is distributed in the hope that it will be
# useful, but without any warranty; without even the implied
# warranty of merchantability or fitness for a particular purpose.

# This script adds InfluxDB and Grafana to Ubuntu 64 bit server 12.04/14.04/15.04
# intended for hosting  timewatch.pl script which evolved from nto_checker to support 
# Influx/Grafana and became timewatch.pl

our $VERSION = '0.0.07';

# influxdb download
my $influxdb_latest =  'https://s3.amazonaws.com/influxdb/influxdb_0.9.6.1_amd64.deb';

# grafana download
my $grafana_latest = 'https://grafanarel.s3.amazonaws.com/builds/grafana_2.6.0_amd64.deb';

print << "GREETINGS";

      *** This is the Timewatch server setup script ****

   This script $PROGRAM_NAME V$VERSION
   sets up an environment for ntp_checker running on Ubuntu.

GREETINGS

# INSTALL Net::SNMP and snmpd
print "\n Installing Net::SNMP and snmpd \n";
system 'cpanm Net::SNMP';
system 'apt-get install snmpd';

# INSTALL INFLUXDB

print "\n Create InfluxDB download directory and download \n";
system 'mkdir /root/influxdb_download';
system "wget -O /root/influxdb_download/influxdb.deb $influxdb_latest";

print "\n Installin Influx package \n";
system 'dpkg -i /root/influxdb_download/influxdb.deb';

print "\n Start InfluxDB \n";
system '/etc/init.d/influxdb start';

# wait for db to start before creating entry
# see if this fixes curl: (7) Failed to connect to localhost port 8086: Connection refused
sleep 5;

# Create the database 'timewatch'
# curl -G 'http://localhost:8086/query' --data-urlencode "q=CREATE DATABASE timewatch"
system(
"curl -G 'http://localhost:8086/query' --data-urlencode \"q=CREATE DATABASE timewatch\""
    );

# INSTALL GRAFANA

print "\n Create Grafana download directory and download \n";
system 'mkdir /root/grafana_download';
system "wget -O /root/grafana_download/grfana.deb $grafana_latest";

print "\n Add user libfontconfig required by Grafana \n";
system 'apt-get install -y adduser libfontconfig';

print "\n Install Grafan package \n";
system 'dpkg -i /root/grafana_download/grfana.deb';

print "\n Start Grafana \n";
system 'service grafana-server start';

print "\n Enable Grafana from startup \n";
system 'update-rc.d grafana-server defaults 95 10';

print "\n Installing sysv-rc-conf for easy chekcing of run levles \n";
system 'apt-get install sysv-rc-conf';

print "\n Installing sar to check system usage (sysstat package) \n";
system 'apt-get install sysstat';

# stop the ntp service (and from booting) then set the clock
print "\n Stopping ntp service and setting clock with ntpd -gqx\n";
system 'update-rc.d ntp disable';
system 'service ntp stop';
system 'ntpd -gqx';

# edit crontab to provide execution of the timewatch script every 15 minutes
print
" Editing crontab, use crontab -e to change script run if every 15 mins is not acceptable \n";

system 'crontab -l > cron_for_timewatch';

system "echo '# Run ntpd to set clock 1 min before check script runs; 14,29,44,59' >> cron_for_timewatch";
system "echo '14-59/15 * * * * /usr/sbin/ntpd -gqx  > /dev/null' >> cron_for_timewatch";
system "echo '# Run check script every 15 mins on the hour' >> cron_for_timewatch";
system "echo '*/15 * * * * /root/timewatch.pl > /dev/null' >> cron_for_timewatch";
system 'crontab cron_for_timewatch';

my $hostname = hostname();

print << "THE_END";

Influx web GUI: http://$hostname:8083/

Grafana web GUI: http://$hostname:3000/

influx daemon
/usr/bin/influxd

influx client
/usr/bin/influx

Confirm run levels and services for influxdb and grafana-serv  with sysv-rc-conf --list
from the influx client, try SHOW DATABASES, and timewatch should be available.
Once the script has run, SHOW MEASUREMENTS should become populated (ntp_offset, maxoffset, poffset)
Optionally, create a retention policy, 
CREATE RETENTION POLICY timewatch_2years ON timewatch DURATION 104w REPLICATION 1
Confimr retention is active with, 
SHOW RETENTION POLICIES ON "timewatch" (there is always a default policy) 

Check memory & system use with sar.  This was installed but needs to be enabled:
edit /etc/cron.d/sysstat to enable, sar -r to check memory used
service sysstat start, service sysstat status to check
Also check the ntp service is disabled with sysv-rc-conf,
this assumes you want to specify the run time of ntpd from cron.


Thats all folks, Share and Enjoy.

THE_END
