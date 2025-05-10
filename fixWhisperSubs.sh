#!/bin/bash

readSub() {
  while read line; do [ -z "$line" ] && break; echo "$line"; done
}

time2ms() {
  date '+%s%N' --date="2020-01-01 $1" | sed 's/000000$//'
}

ms2time() {
  SECS=`expr $1 / 1000`
  MS=`expr $1 % 1000`

  TIME=`date +%T -d @$SECS `
  echo "$TIME,$MS"
}

max () { printf '
    define x(a, b) {
        if (a > b) {
           return (a);
        }
        return (b);
     }
     x(%s, %s)
    ' $1 $2 | bc -l
}


sayLength() {
  #echo "W $1" 1>&2
  NUMWORDS=`echo "$1" | wc -w`
  NUMCOMMAS=`echo "$1" | tr -cd , | wc -c`
  #echo $NUMWORDS 1>&2
  PAUSE=`echo "scale = 8; ($NUMWORDS + $NUMCOMMAS) / 200 * 60 * 1000" | bc | awk -F'.' '{print $1}'`

  echo `max $PAUSE 1000`
}




SUB="X" 

for i in $*
do

  NO_EXT="${i%.*}"
  NEW_SUB="$NO_EXT--new.srt"
  OLD_SUB="$NO_EXT--beforeFix.srt"

  cat $i | (
    while [ "$SUB" != "" ]
    do
      SUB=`readSub`
      if [ "$SUB" != "" ]
      then
        INDEX=`echo "$SUB" | sed -n 1p`
        TIMINGS=`echo "$SUB" | sed -n 2p`
        TEXT=`echo "$SUB" | sed -n 3,10p`

        BEGTIME=`echo $TIMINGS | awk '{print $1}'`
        BEGTIMEMS=`time2ms $BEGTIME`
        ENDTIME=`echo $TIMINGS | awk '{print $3}'`
        ENDTIMEMS=`time2ms $ENDTIME`
        TIMELENGTH=`expr $ENDTIMEMS - $BEGTIMEMS`

        if [ "$TIMELENGTH" -gt "5000" ]
        then
          NEWLENGTH=`sayLength "$TEXT"`
          echo "Fixing index $INDEX. Old length: $TIMELENGTH, new length: $NEWLENGTH" 1>&2
          NEWBEGTIMEMS=`expr $ENDTIMEMS - $NEWLENGTH`
          NEWBEGTIME=`ms2time $NEWBEGTIMEMS`;

          echo "$INDEX"
          echo "$NEWBEGTIME --> $ENDTIME"
          echo "$TEXT"
          echo
        else 
          echo "$SUB"
          echo ""
        fi        
      fi
    done
  ) > $NEW_SUB

  mv $i $OLD_SUB
  mv $NEW_SUB $i
  
done
