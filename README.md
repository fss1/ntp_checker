
# NTP CHECKER

ntp_checker compares internal NTP sources with the National Physical Laboratory and warns if the offset between NPL and local servers exceeds a definable (fraction of) seconds. If NPL is not available, Physikalisch-Technische Bundesanstalt (PTB) is used. A log file is created each time the script runs. Logs older than 28 days are automatically deleted. 

## How it works

This script runs every hour. Normally there should be no warnings. If a warning event is detected, a warnings only log is created & appended to on each successive run. Servers used for offset comparison are variables in the script but by default:  
ntp2.npl.co.uk   
ptbtime3.ptb.de   
The secondary server will only be used if the primary server is not responding.   

If the difference in offsets is more than $offset_limit seconds, or a leap Indicator bit is set, or the server does not respond, a WARNING is logged.

A new warning will create a warning log file and send an email alert. A warning condition exists while a current warning file is present.

No further emails are sent for new warnings; these are appended to the current warning log.
The warning file is automatically renamed with a date stamp if older than 7 days. Acknowledging the warning date stamps the file name. Once date stamped, the warning file is effectively archived.  This provides the required behaviour of only sending one email a week if a persistent error (such as one of the internal servers being down).

### Run from command line 
-h Prints a help page  
-v Verbose mode  
-m Email send test  

### Definitions  
Server = Internal NTP server  
Ref = Reference clock (time source used by each server)  
St = Stratum  
Li = Leap Indicator, normally zero  
Precision = Clock quality measured as a power of two,  
E.g. precision=-16 is about 15 microseconds (2^-16 s)
offset = offset of server compared to local clock 

For more information check the RFC 5905 (V4)
https://datatracker.ietf.org/doc/rfc5905/ 

### Operation 
Flocking is used to ensure only one instance of this script runs at a time. NTP uses UTC - all times are in UTC. Log files will be deleted after 28 days, warning files will be renamed with a time stamp after 7 days. Acknowledged (date stamped) warning files exist forever.

## Example internal_servers_list.txt  

`# Internal servers list`  
`# Please ensure each server begins as the beginning of a new line`  
`# Lines beginning with hash or space are treated as comment lines`  
``
`10.1.2.4`  
`10.3.4.5`  
`10.6.7.8`  
 ``
`# Distribution layer 'VIP' addresses`  
`192.168.1.2`  
`192.168.3.4`  
`192.168.5.6`
`
