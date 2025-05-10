#!/bin/bash

if [ "$#" -ne "2" ]
then
    echo "Usage: $(basename "$0") <input-srt> <output-srt>"
fi

#.. This sorts the srt file by time.
gawk '
BEGIN { RS=""; ORS="\n\n" }
{
  match($0, /([0-9]{2}):([0-9]{2}):([0-9]{2}),([0-9]{3})/, m)
  time = m[1]*3600000 + m[2]*60000 + m[3]*1000 + m[4]
  print time "|" $0
}
' $1 | sort -n | cut -d'|' -f2- | 

#.. This removes the "MISSING SUBS" lines.
gawk 'BEGIN { RS=""; ORS="\n\n" } !/MISSING SUBS/' |

#.. This renumbers the srt file. 
gawk '
BEGIN { RS=""; ORS="\n\n"; count = 1 }
{
  sub(/^[0-9]+/, count++)
  print
}
' > $2