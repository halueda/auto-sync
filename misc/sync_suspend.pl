#!perl
system( q!/usr/bin/ps | /usr/bin/awk '/cons/ && /perl/ { print $1;}' | /usr/bin/xargs /usr/bin/kill -QUIT! );
#<>;
