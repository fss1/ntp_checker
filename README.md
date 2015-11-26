
# NTP CHECKER

ntp_checker compares internal NTP sources in a .txt file list, with the National Physical Laboratory and warns if the offset between NPL and local servers exceeds a definable (fraction of) seconds. If NPL is not available, Physikalisch-Technische Bundesanstalt (PTB) is used. A log file is created each time the script runs. Logs older than 28 days are automatically deleted. 

## How it works

This script runs every hour. Normally there should be no warnings. If a warning event is detected, a warnings only log is created & appended to on each successive run. Servers used for offset comparison are variables in the script but by default:  
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

### Operation 
Flocking is used to ensure only one instance of this script runs at a time. NTP uses UTC - all times are in UTC. Log files will be deleted after 28 days, warning files will be renamed with a time stamp after 7 days. Acknowledged (date stamped) warning files exist forever.  A web page is generated by the script.

### Installation
Create an instance of Ubuntu 14.04 server in your favourite VM.  From /root, download and run the ntp_builder.pl script.  It may be useful to run *script* to capture the output.  Apache and necessary perl modules/scripts will be installed along with some tools.  crontab will be modified to run the ntp_checker every hour.  The crontab script generated remains as /root/crontabadditon; it can be deleted along with ntp_builder once successfully run. Download and run the ntp_builder.pl script:

`wget https://raw.githubusercontent.com/fss1/ntp_checker/master/perl/ntp_builder.pl`  
`perl ntp_builder.pl`  

`dpkg-reconfigure -f noninteractive tzdata` needs too be run manually as part of the build to set/check the time zone.  A prompt is generated at the end of the build script to set the time zone (should be UTC).  If InfuxDB and Grafan are required also run the timewatch_builder script:  

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
This file must exist and be in the same path as the script.

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


## Timewatch
It would be nice to visualise the data.  InfluxDB + Grafana seem to be a nice match.
ntp_checker above 0.0.37 will gained influxDB integration to become Timewatch.  
An additional build script timewatch_builder.pl, will add InfluxDB and Grafan and the database 'timewatch'.  

Interfaces:  

**InfuxDB**  
http://localhost:8083/

or the command line:  
\# /opt/influxdb/influx  
Connected to http://localhost:8086 version  
InfluxDB shell 0.9.4.2  
>  
 
A few example queries:  
    
CREATE DATABASE timewatch   
DROP DATABASE timewatch   
SHOW SERIES FROM ntp_offset WHERE server = '192.168.12.34'   
SHOW TAG KEYS FROM ntp_offset   
select \* from ntp_offset where server =~ /10.0.0.\*/   
select \* from /.\*/ limit 5   
select value from ntp_offset where time > now() - 1h limit 100   
SELECT last(value) FROM poffset WHERE time > now() - 1h and server =~ /ref_server/  
   
The select syntax takes the usual now() with d for day w for week.  
    
For plotting purposes, the external reference servers become a single plot with the same name defined in $ref_server.  

 
**Grafana**  
http://localhost:3000/login  
[default login admin,admin]  

The script will use curl to make http inserts to InfluxDB so curl must be present.  

In Grafana, edit the Data Source to be Type InfluxDB 0.9.x, url http://localhost:8086, influxDB Details Database, timewatch etc.   
ADD ROW -> Add Panel -> Graph  with multiple lines such as 'SELECT mean(value) FROM ntp_offset WHERE server=ip_of_server GROUP BY time($interval) server 

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

#### Grafan configuration

This is down to personal taste; a few suggestions:  

+ Row title allows the graph to be collapsed but looks cluttered if a graph title is also used.  Graph title can be blank (but remains as a hover over link to access the edit menu) 
+ Settings (the cog) -> Rows, allows title to be added. Settings -> Links are also very useful
+ The period configuration (top left) allows auto refresh to be defined (1 min seems sensible) change from default of off
+ For an offset graph, Y left set to 0.05 max and -0.05 min works well
+ Row pop out menu, Set Row height to 350px
+ Display Styles, Line Options with Line fill 0, Line Width 2, Null point mode connected; Axis and Grids, show legend right
+ Add a text row as a help menu.  As above, use the row title and leave the General options title blank
+ When done, Settings -> Export to download the configuration
+ For single statistics, span 1, height 0 works provided the pre and post description is short and provides a minimal area.

