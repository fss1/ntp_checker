#!/usr/bin/perl

use strict;
use warnings;
use Data::Dumper;
use Carp;

# Test scipt to read permitted ref clocks (prc) file, place in a hash and print result

# File name and path for permitted reference clocks file
my $permitted_refs_file = 'permitted_ref_clocks.txt';
### send this to subroutine

## SUB TO READ PRC FILE ##
sub read_prc {
    my $permitted_refs = shift;
    my @permitted;    # Array to hold permitted refs from file

    # Log entry defining permitted reference clocks
    my $prclog =
"\n*** Permitted ref clocks: 1st entry is NTP source followed by ref addresses ***\n";

    # Permitted ref clock hash of arrays will be
    my %prc;

    open my $PERMITTED, '<', "$permitted_refs"
      or carp 
"Permitted reference file $permitted_refs wont open, check this file & patch exists: $!";

    while (<$PERMITTED>) {
        $_ =~ s/\r?\n$//xms;
        next
          if ( $_ =~ m/^\s+/xms )
          || ( $_ =~ m/^\#+/xms )
          || ( $_ =~ m/^\s*$/xms );
        @permitted = split( ',', $_ );

        #     print  "NTP source is $permitted[0]\n";
        $prclog .= "   @permitted\n";

        # shift 1st array item into $ntp_source and use as hash key
        my $ntp_src = shift @permitted;

        # syntax for hash of arrays is push(@{$hash{$key}}, $insert_val);
        push( @{ $prc{$ntp_src} }, @permitted );

    }
    close $PERMITTED or carp "restricted file list wont close: S!";

    #  Enable this section for subroutine debug
    #  print "\n$prclog\n";
    #  print Dumper ( \%prc );
    #  my $ntp_src;
    #  foreach $ntp_src ( keys %prc ) {
    #      print "NTP sorce is: $ntp_src reference clocks are:\n";
    #      foreach ( @{ $prc{$ntp_src} } ) {
    #          print "   $_\n";
    #      }
    #  }
    return ( \%prc, $prclog );
}

## READ PERMISSIVE REF CLOCKS PROGRAM ##

# Pointer to hash of permitted ref clocks
my $prc_ref;

# Pointer deref to hash
my %prcs;

# Log file entry
my $prclog_entry;

# If permitted_refs file exists, read file, retun hash and log entry
if ( -f $permitted_refs_file ) {

# Pointer to permitted ref clock hash $prc_ref; prc log file entry is $prclog_entry

    ( $prc_ref, $prclog_entry ) = read_prc($permitted_refs_file);

    # deref hash into hash for permitted ref clocks
    %prcs = %{$prc_ref};

    #    print Dumper ( \%prcs );
    print "\nAddition to log file is:\n$prclog_entry\n";
    
    foreach my $ntp_srcs ( sort ( keys %prcs ) ) {
        print "NTP sorce is: $ntp_srcs reference clocks are:\n";
        foreach ( @{ $prcs{$ntp_srcs} } ) {
            print "   $_\n";
        }
    }

}
else {
    print
"\n   $permitted_refs_file could not be found - ref clock check will be skipped\n";
}

if (%prcs) {
    print "\nThat permitted ref hash has members\n";

}
else {
    print
      "\npermitted ref hash has no memebers - file was probably was found\n\n";
}

exit 0;
