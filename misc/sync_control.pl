#!perl
#
# Usage: perl sync_control.pl {reload|rerun|suspend}
#   send {HUP,USR1,QUIT} signal to all perl program.
#

if ( $#ARGV < 0 ) {
  $ARGV[0] = "reload";
}

my $signal = "HUP";
if ( $ARGV[0] eq "reload" ) {
  $signal = "HUP";
} elsif ( $ARGV[0] eq "rerun") {
  $signal = "USR1";
} elsif ( $ARGV[0] eq "suspend") {
  $signal = "QUIT";
}

system( q!/usr/bin/ps | /usr/bin/awk '/cons/ && /perl/ { print $1;}' | /usr/bin/xargs /usr/bin/kill ! . "-$signal" );
#<>;
