
# NTP CHECKER

ntp_checker compares internal NTP sources in a .txt file list, with the National Physical Laboratory and warns if the offset between NPL and local servers exceeds a definable (fraction of) seconds. If NPL is not available, Physikalisch-Technische Bundesanstalt (PTB) is used. A log file is created each time the script runs. Logs older than 28 days are automatically deleted. ntp_checker has a build script ntp_builder.pl but evolved to use InfluxDB and Grafana.  At this point it became known as Timewatch.  Additional components are installed with the timewatch_builder.pl script. 

## How it works

ntp_checker script runs every hour via cron and creates log files and an html page. Normally there should be no warnings. If a warning event is detected, a warnings only log is created & appended to on each successive run. Servers used for offset comparison are variables in the script but by default:  
ntp2.npl.co.uk   
ptbtime3.ptb.de   
The secondary server will only be used if the primary server is not responding.   

If the difference in offsets is more than $offset_limit seconds, or a leap Indicator bit is set, or the server does not respond, a warning is logged.  

As a single source (usually NPL) is used for the comparison, a delayed response may result in an occasional warning if set too tight.  In practice .3 of a second seems a safe limit. 

A new warning will create a warning log file and send an email alert. A warning condition exists while a current warning file is present.

No further emails are sent for new warnings; these are appended to the current warning log.
The warning file is automatically renamed with a date stamp if older than 7 days. Acknowledging the warning date stamps the file name. Once date stamped, the warning file is effectively archived.  This provides the required behaviour of only sending one email a week if a persistent error (such as one of the internal servers being down).

### Run from command line 
-h Prints a help page  
-v Verbose mode  
-m Email send test  
-s snmp trap send (for Timewatch2)

### Operation 
Flocking is used to ensure only one instance of this script runs at a time. NTP uses UTC - all times are in UTC. Log files will be deleted after 28 days, warning files will be renamed with a time stamp after 7 days. Acknowledged (date stamped) warning files exist forever.  A web page is generated by the script.

### Installation
Create an instance of Ubuntu 14.04 server in your favourite VM.  From /root, download and run the ntp_builder.pl script.  It may be useful to run *script* to capture the output.  Apache and necessary perl modules/scripts will be installed along with tools such as git.  crontab will be modified to run the ntp_checker every hour.  The crontab script generated remains as /root/crontabadditon; it can be deleted along with ntp_builder once successfully run. Download and run the ntp_builder.pl script:

`wget https://raw.githubusercontent.com/fss1/ntp_checker/master/perl/ntp_builder.pl`  
`perl ntp_builder.pl`  

`dpkg-reconfigure tzdata` needs too be run manually as part of the build to set/check the UTC time zone. Select Geographic area, None of the above -> UTC and run `dpkg-reconfigure -f noninteractive tzdata` or `date` to confirm.  A prompt is generated at the end of the build script to set the time zone to UTC.  If InfuxDB and Grafana are required also run the timewatch_builder script:  

`wget https://github.com/fss1/ntp_checker/blob/master/perl/timewatch_builder.pl`  
`perl timewatch_builder.pl`
   
If using a dedicated VM specific for ntp_checker, install to /root, otherwise change the paths/crontab as required.  

Variables in ntp_chekcer for the email settings need to be modified manually:

$mailaddress = your internal email relay  
$mailto      = mail TO address  
$mailcc      = mail Cc address, will take comma separate multiple addresses  

Offset limit in seconds between external NTP reference and internal servers list is defined in:
$offset_limit

The file containing lists of internal servers (one per line) is $ntplist, internal_ntp_servers_list.txt is the default name.  
This file must exist and be in the same path as the script.  ntp_checker needs to be run at least once to create the home page.  

As the ntp_builder adds git it is now possible to git pull the project.  This was intended to run from root on a VM only running these scripts.  If continuing with 'Timewatch' copy the timewatch scripts into root and make them executable.  Edit the crontab to remove the original ntp_checker entry once timewatch has been proven.  

#### Example internal_ntp_servers_list.txt  
The internal_ntp_servers_list.txt file must be present in the same path as the checking script for the script to run.  IP or hostnames can be used - there is no validity checking of either.  A copy of this list is made each time the script runs making it visible as a link in the web page, so take care with the comments.  These may be visible to others.

`# Internal NTP servers list, internal_ntp_servers_list.txt`  
`# Please ensure each server address begins at the beginning of a new line`  
`# Lines beginning with hash or space are treated as comment lines`  

` Your internal NTP sources`
`10.0.0.1`  
`10.0.0.2`  
`10.0.0.3`  

`# Your distribution layer 'VIP' addresses`  
`192.168.0.1`  
`192.168.0.2`  
`192.168.0.3`

#### Log file definitions
Server = Internal NTP server  
Ref = Reference clock (time source used by each server)  
St = Stratum  
Li = Leap Indicator, normally zero  
Precision = Clock quality measured as a power of two,  
E.g. precision=-16 is about 15 microseconds (2^-16 s)  
offset = offset of server compared to local clock  

For more information check the RFC 5905 (V4)  
https://datatracker.ietf.org/doc/rfc5905/

#### Suggested master time servers
NPL  
ntp1.npl.co.uk  139.143.5.30  
ntp2.npl.co.uk  139.143.5.31  

Physikalisch-Technische Bundesanstalt (PTB)   
ptbtime1.ptb.de  
ptbtime2.ptb.de  
ptbtime3.ptb.de  

#### What can be monitored
**Net::NTP** is used, so anything returned in the associative array based upon RFC1305 and RFC2030 is available.  A Data::Dumper example:  

    {
    'Key Identifier' => '',
    'Root Delay' => '0.0635833740234375',
    'Reference Clock Identifier' => '168.192.123.45',
    'Reference Timestamp' => '1447426807.23475',
    'Poll Interval' => '0.0000',
    'Receive Timestamp' => '1447426995.51275',
    'Offset' => '-0.0133742094039917',
    'Root Dispersion' => '0.0000',
    'Destination Timestamp' => '1447426995.52267',
    'Originate Timestamp' => '1447426995.90532',
    'Precision' => -6,
    'Stratum' => 4,
    'Leap Indicator' => 0,
    'Mode' => 4,
    'Delay' => '0.00690',
    'Message Digest' => '',
    'Transmit Timestamp' => '1447426995.51275',
    'Version Number' => 3
    };

**Net::NTP** calculates the _offset_ of an NTP Packet (from B), returning the offset to local (A) according to its xmttime(T1) and rectime(T4),   
theta = T(B) - T(A) = 1/2 * [(T2-T1) + (T3-T4)]  
**Net::NTP** returns the _delay_ from the sender (B) of $packet given known local xmttime(T1) and rectime(T4)   
delta = T(ABA) = (T4-T1) - (T3-T2) 

#### Identifying NTP services on the LAN
Use nmap to scan for port 123 responses.  To identify domain controllers & active directory forests, it is possible to use nslookup from a client on the same Windows domain.  Check the Service Location (SRV) locator resource records for your_local_domain.com with the command below.  The SRV record is a Domain Name System (DNS) resource record that is used to identify servers hosting specific services, in this case ldap and ntp  

`nslookup`  
` > set type=all`  
` >  _ldap._tcp.dc._msdcs.your_local_domain(s).com`  
and   
` > ntp._udp.your_local_domain(s).com`   
 
# Timewatch
It would be nice to visualise the data.  InfluxDB + Grafana seem to be a nice match.
ntp_checker above 0.0.37 gained influxDB integration to become Timewatch.  
An additional build script timewatch_builder.pl, will add InfluxDB and Grafan and the database 'timewatch'.  
Graphs look better over an interval of days if data points are every 15 mins. A crontab entry for timewatch has been added for this (the ntp_checker was hourly).

Interfaces:  

**InfuxDB**  
http://localhost:8083/

or the command line:  
\# /opt/influxdb/influx  
Connected to http://localhost:8086 version  
InfluxDB shell 0.9.x.x
>  

Check out the query language specificaiton https://influxdb.com/docs/v0.9/query_language/spec.html   
Be careful with keywords.  SERVER is a keyword and matches 'server' in a query if also used as a database key.  This still works but it is necessary to double quote "server" in a query string.   
 
A few influx example queries and settings:  
    
CREATE DATABASE timewatch   
DROP DATABASE timewatch   
SHOW MEASUREMENTS   
SHOW SERIES   
SHOW SERIES FROM ntp_offset WHERE "server" = '192.168.12.34'   
SHOW TAG KEYS FROM ntp_offset   
select \* from ntp_offset where "server" =~ /10.0.0.\*/   
select \* from /.\*/ limit 5   
select * from ntp_offset where "server" = '192.168.0.1' and time > '2016-01-26' and time < '2016-01-27'
select value from ntp_offset where time > now() - 1h limit 100   
SELECT last(value) FROM poffset WHERE time > now() - 1h and "server" =~ /ref_server/  
The select syntax takes the usual now() with d for day w for week.  

CREATE USER god WITH PASSWORD 'keepcalmandcodequietly' WITH ALL PRIVILEGES   
CREATE USER admin WITH PASSWORD 'admin' WITH ALL PRIVILEGES   
SHOW USERS   
Optionally, create a retention policy   
CREATE RETENTION POLICY timewatch_2years ON timewatch DURATION 104w REPLICATION 1   
Confimr retention is active with   
SHOW RETENTION POLICIES ON "timewatch" (there is always a default policy)  

Paths vary between versions, check within /etc/init.d/influxdb      
Configuration file is /etc/influxdb/influxdb.conf  
The backup (snapshot) option in 0.9.5 had issues but seems to work in 0.9.6 without modifying the conf file. 
Repeating the `influxd backup` command to the same file name results in a .0 incremental file being created.   
To restore, `service influxd stop`, then `influxd restore -config /etc/influxdb/influxdb.conf /path_to/snapshot_file`  
    
For plotting purposes, the external reference servers become a single plot with the same name defined in $ref_server.  

 
**Grafana**  
http://localhost:3000/login  
[default login admin,admin]  

The script will use curl to make http inserts to InfluxDB so curl must be present.  

In Grafana, edit the Data Source to be Type InfluxDB 0.9.x; as this is running on the same host, Http settings are url http://localhost:8086  
Data source name is used by the dashboards to idenify the database, effectively an alias. For example, Name: influxdb_timewatch, Database  timewatch, User admin.     
ADD ROW -> Add Panel -> Graph  with multiple lines such as 'SELECT mean(value) FROM ntp_offset WHERE server=ip_of_server GROUP BY time($interval) server'   

#### NTP offset for Singlestat

Within Grafana -> Add Panel -> Single stat -> Options it is possible to define colours to value ranges and a value to text mapping. 
Use last value to provide a current condition.  SELECT last(value) FROME poffset WHERE server = ref_server GROUP BY time($interval) server  
The ntp_offset is made always positive and added to the timewatch database as a separate row, poffset. 
Suggested thresholds are set as 0,0.3,0.5 Colors as Green, Orange and Red.  
Exception cases exist that can be identified by using text mapping for specific values.  
If no response from the server is found then the offset is set to 666.
If the leap indicator bit is set then the offset is set to 667.  
The value 666 is mapped to display 'Not Available'  
The value 667 is mapped to display 'LI Set'   

#### Max Positive V Negative Offset 

Another graph of max positive and negative offset was considered.  Additional entries were made in the database for measurement 'maxoffset' to provide 'maxpos_server' and 'maxneg_server' offset values each time the script is run.  
This is taken from the internal server pool and excludes external references.  

#### Grafana configuration

This is down to personal taste; a few suggestions:  

+ Row title allows the graph to be collapsed but looks cluttered if a graph title is also used.  Graph title can be blank (but remains as a hover over link to access the edit menu) 
+ Settings (the cog) -> Rows, allows title to be added. Settings -> Links are also very useful
+ The period configuration (top left) allows auto refresh to be defined (1 min seems sensible) change from default of off
+ For an offset graph, Y left set to 0.05 max and -0.05 min works well
+ Row pop out menu, Set Row height to 350px
+ Display Styles, Line Options with Line fill 0, Line Width 2, Null point mode connected; Axis and Grids, show legend right
+ Add a text row as a help menu.  As above, use the row title and leave the General options title blank
+ When done, Settings -> Export to download the configuration
+ For single statistics, span 1, height 0 works provided the pre and post description is short and provides a minimal area
+ Metrics now allow 'ALIAS BY' instead of using the tag value to label the server
+ Change admin password and create a view only user, timewatch.  Grafana Admin -> Global Users -> Create User (and Edit admin account)

#### Timewatch server administration
The timewatch script is running on a VM with only 1G of RAM.  The build script adds `sar` but this is not enabled.  
edit `/etc/default/sysstat` to enable and check `/etc/cron.d/sysstat` if monitoring required at intervals other than the default 10 minutes.     
use  `sar -r` to check memory usage.      
`service sysstat start`, `service sysstat status`, to start and check sysstat is running.   

Check influxdb and grafana are configured to run at start up with `sysv-rc-conf`  

Create backups (snapshots) of influx while the database is still running with `influxd backup snapshot_file_name`  

#### NTP configuration
It was found that a slight glitch may occur if the checking script runs while the local clock is being adjusted. 
To prevent this it is possible to synchronise the local clock at a fixed time using cron just before the checking script is run. 
It is possible to check the peers list while ntpd is running with 'ntpq -p'. If you don't want to use a 'random' pool modify the /etc/ntp.conf with your preferred time sources  

`server swisstime.ethz.ch`  
`server ntp0.pipex.net`  
`server ntp-p1.obspm.fr`  
`server ntp1.npl.co.uk`  
`server ntp1.sp.se`  
`server ntp2.ja.net`  
`server ptbtime1.ptb.de`  

UK ntp1.npl.co.uk National Physical Laboratory  
Teddington, Middlesex  

UK ntp0.pipex.net Pipex  

CH swisstime.ethz.ch  
Integrated Systems Laboratory, Swiss Fed. Inst. of Technology, Zurich  

FR ntp-p1.obspm.fr  
LPTF - Observatoire de Paris, France  

SE ntp1.sp.se (62.119.40.98)
SP Swedish National Testing and Research Institute, BORAS, SWEDEN

UK ntp2.ja.net (193.63.94.26)  
University of London Computer Centre, UK  

DE ptbtime1.ptb.de (192.53.103.103)  
Physikalisch-Technische Bundesanstalt (PTB), Braunschweig, Germany  

also add the usual restrictions  

`restrict swisstime.ethz.ch noquery nomodify notrap`  
`restrict ntp0.pipex.net noquery nomodify notrap`  
`restrict ntp-p1.obspm.fr noquery nomodify notrap`  
`restrict ntp1.npl.co.uk noquery nomodify notrap`  
`restrict ntp1.sp.se noquery nomodify notrap`  
`restrict ntp2.ja.net noquery nomodify notrap`  
`restrict ptbtime1.ptb.de noquery nomodify notrap`    

noquery - deny ntpq and ntpdc requests  
nomodify - deny modification requests from these servers (query ok)  
notrap - Decline to provide mode 6 control message trap service to matching hosts  

Make the new ntp.conf active `service ntp restart` and check with ntpq -p  

Manually sync with 'ntpd -gqx' (ntpdate is deprecated)  

-g This option allows the time to  be  set  to  any value without restriction  
-q Exit  the ntpd just after the first time the clock is set  

add ntpd to cron so it runs a minute or so before the check script, redirect stderr to stderr 2>&1 to prevent default email from cron (stdout > dev/null does not catch stderr)

`*/15 * * * * /root/timewatch.pl >/dev/null 2>&1`  
`14-59/15 * * * * /usr/sbin/ntpd -gqx >/dev/null 2>&1`  
`# or this for debug`    
`# 14-59/15 * * * * /usr/sbin/ntpd -gqx >> /root/ntpd_log.txt && date >> /root/ntpd_log.txt`    

`service ntp stop`

Stop the ntp service running on reboot with `sysv-rc-conf` (chkconfig is getting old). 
Remove the logging from cron once it has been proven.
The build scipt will stop ntpd and run this from cron but the suggested /etc/ntp.conf configuration change above is manual but can be left with the Ubuntu default.

#### Finding NTP distribution via Active Directory

From a Windows terminal run `nslookup` and try these example commands:   
`> set type=all`    
`> _ldap._tcp.dc._msdcs.yourdomain.com`  
and   
`_ntp._udp.yourdomain.com`   
`exit` to quit.  To check an identified address responds to a time request   
`w32tm /monitor /computers:192.168.0.1`

# Timewatch 2

More features were requested.  These will be added to 0.0.50 and higher:
+ Ability to restrict alerting (email/snmp) for selected servers while still maintaining checking/logging
+ Capture and plot the absolute offset compared to the external reference (NPL/PTB)
+ SNMP trap to be sent along with the existing email alert

A restricted servers list, restricted_ntp_servers.txt can be placed in the same directory as the timewatch script. 
Matching items in this list will prevent alerting (but not logging).
This list is pattern matched with the warning string. The server is still tested and logged.
A match in the list below prevents an alert being sent. 
To be excluded from an alert, the server IP or hostname must match that in the servers list.  
Partial matches such as 192.168 can be used to disable alerts for a subnet.
Lines beginning with # or space or a new line are ignored.  This feature allows legacy devices to still be monitored while only raising alerts for current high priority services.

An additonal series, abs_offset has been added to the timewatch database.  This is the absolute (always positive) difference between the internal server and the external server (NPL or PTB).  

#### SNMP Testing

To recieve a trap on a Mac:   
create /etc/snmp/snmptrapd.conf and add`disableAuthorization yes`  
`sudo snmptrapd -f -Lo`   

To send a test trap from timewatch.pl set the destination parameters in the variables at the top of the script   
`perl timewatch.pl -s`   

To send a trap from Ubuntu:    
`snmptrap -v 1 -c public <trap_destination_ip> .1.3.6.1.4.1.16924.217 "" 6 666 "" .1.3.6.1.4.1.16924.237 s "allworkandnoplay..."`   
A null `""` applies the default value to firstly the agent address and secondly the timestamp in the above command.   

To trap to syslog on Ubuntu:  

`sudo apt-get install snmpd`  
`vi /etc/default/snmpd`  

Change, `TRAPDRUN= yes`  

snmptrapd now starts automatically  

Check with,  `sudo service snmpd status`  
 
snmptrapd, needs some access control defined, for example /etc/snmpsnmptrapd.conf line: `authCommunity log public` 
will let any incoming notification with a community name of public be logged to syslog 
 
`sudo service snmpd restart` to restart services after the configuration change.           

Now tail the log to see the output `tail -f /var/log/syslog`





