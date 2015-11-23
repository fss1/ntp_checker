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

# This script adds InfluxDB and Grafana to Ubuntu 64 bit server 12.04/14.04/15.04
# intended for hosting the ntp_checker.pl which evolved to support 
# Influx/Grafana and became timewatch.pl

our $VERSION = '0.0.01';

print << "GREETINGS";

      *** This is the Timewatch server setup script ****

   This script $PROGRAM_NAME V$VERSION
   sets up an environment for ntp_checker running on Ubuntu.

GREETINGS

# INSTALL INFLUXDB

print "\n Create InfluxDB download directory and download \n";
system 'mkdir /root/influxdb_download';
system 'wget -O /root/influxdb_download/influxdb.deb https://s3.amazonaws.com/influxdb/influxdb_0.9.4.2_amd64.deb';

print "\n Installin Influx package \n";
system 'dpkg -i /root/influxdb_download/influxdb.deb';

print "\n Start InfluxDB \n";
system '/etc/init.d/influxdb start';

# Create the database 'timewatch'
# curl -G 'http://localhost:8086/query' --data-urlencode "q=CREATE DATABASE timewatch"
system(
"curl -G 'http://localhost:8086/query' --data-urlencode \"q=CREATE DATABASE timewatch\""
    );

# INSTALL GRAFANA

print "\n Create Grafana download directory and download \n";
system 'mkdir /root/grafana_download';
system 'wget -O /root/grafana_download/grfana.deb wget https://grafanarel.s3.amazonaws.com/builds/grafana_2.1.3_amd64.deb';

print "\n Add user libfontconfig required by Grafana \n";
system 'apt-get install -y adduser libfontconfig';

print "\n Install Grafan package \n";i
system 'dpkg -i /root/grafana_download/grfana.deb';

print "\n Start Grafana \n";
system 'service grafana-server start';

print "\n Enable Grafana from startup \n";
system 'update-rc.d grafana-server defaults 95 10';


print << "THE_END";

Influx web Gui interface on http://hostname:8083/

Grafana web gui interface on http://hostname:3000/

influx daemon
/opt/influxdb/influxd

influx client
/opt/influxdb/influx

now try SHOW DATABASES, and timewatch should be available

Thhats is, Share and Enjoy

THE_END
