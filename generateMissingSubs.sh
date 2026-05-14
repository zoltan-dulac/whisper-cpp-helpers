#!/bin/bash


readSub() {
  while read line; do [ -z "$line" ] && break; echo "$line"; done
  echo " "
}

time2ms() {
  # date '+%s%N' --date="1970-01-01 $1" | sed 's/000000$//'
  $DATE_CMD -u -d "01/01/1970 $1" +"%s" 

}

trim() {
    local var="$*"
    # remove leading whitespace characters
    var="${var#"${var%%[![:space:]]*}"}"
    # remove trailing whitespace characters
    var="${var%"${var##*[![:space:]]}"}"
    printf '%s' "$var"
}

ms2time() {
  SECS=`expr $1 / 1000`
  MS=`expr $1 % 1000`

  TIME=`$DATE_CMD +%T -u -d @$1 `
  echo "$TIME"
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

# Check if gdate is available, else fallback to date
if command -v gdate >/dev/null 2>&1; then
    DATE_CMD="gdate"
else
    DATE_CMD="date"
fi


if [ "$#" -lt "3" ]
then
  echo "Error. Usage: $0 <input-srt-file> <lang-code> <model size>" 1>&2
  exit 1
elif [ ! -f "$1" ]
then 
  echo "Error. $1 is not a valid file"
  exit 2
elif ! command -v dos2unix >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have dos2unix installed on your machine and in your path."
		echo "Please follow instructions at https://dos2unix.sourceforge.io/"
		echo
	) 1>&2
	exit 10
elif ! "$DATE_CMD" -d "01/01/1970 00:00:00" +%s >/dev/null 2>&1; then
  (
    echo
    echo "Error: $DATE_CMD does not support the -d option".
    echo "If you are running this script using OSX, you will need to install"
    echo "gdate using homebrew or macports."
    echo
  ) 1>&2
   
  exit 11
elif ! command -v ffmpeg >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have ffmpeg installed on your machine and in your path."
		echo "Please follow instructions at https://ffmpeg.org"
		echo
	) 1>&2
	exit 12
elif ! command -v clipVideo.sh >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have clipVideo.sh installed on your machine and in your path."
		echo "Please follow instructions at https://github.com/zoltan-dulac/whisper-cpp-helpers"
		echo
	) 1>&2
	exit 13
elif ! command -v vid2sub.sh >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have vid2sub.sh installed on your machine and in your path."
		echo "Please follow instructions at https://github.com/zoltan-dulac/whisper-cpp-helpers"
		echo
	) 1>&2
	exit 14
fi


echo "Generating for $1"
dos2unix $1
SUB="X" 

i="$1"
NO_EXT="${i%%.*}"
NO_EXT=`echo $NO_EXT | sed "s/\.${2}//"`
NEW_SUB="$NO_EXT--new.srt"
TMP_SUB="$NO_EXT--tmp.srt"
OLD_SUB="$NO_EXT--beforeInsert.srt"
WAV="$NO_EXT.wav"
MP4="$NO_EXT.mp4"

ls $MP4 2>&1 > /dev/null


if [ "$?" -ne "0" ]
then
  MP4="$NO_EXT.mkv"
fi

if [ ! -f "$WAV" ]
then
	#.. First, extract 16000 Hz file from video
	echo "Extracting wav ..."
	ffmpeg -i $MP4 -acodec pcm_s16le -ar 16000 $WAV
fi 

READ_NEXT_SUB="1"

# Copy original srt file to TMP_SUB
cp $1 $TMP_SUB 


echo "X $i"
cat $i | (
  MISSINGSUBS=()
  while [ "$SUB" != "" ]
  do
    if [ "$READ_NEXT_SUB" = "1" ]
    then
      SUB=`readSub`
    else
      READ_NEXT_SUB="1"
    fi


    if [ "$SUB" != "" ]
    then
      INDEX=`echo "$SUB" | sed -n 1p`
      TIMINGS=`echo "$SUB" | sed -n 2p`
      TEXT=`echo "$SUB" | sed -n 3,10p`
      SUB=`trim "$SUB"`
      # echo "XXX: ~~~$INDEX~$TIMINGS~$TEXT~~~"

      if [[ "$TEXT" =~ ^"MISSING SUBS" ]]
      then          
        #.. BEGTIME is end of this sub
        BEGTIME=`echo $TIMINGS | awk '{print $3}'`
        BEGTIMEMS=`time2ms $BEGTIME`
        TOKEN=`echo $TEXT | sed "s/ /-/g"`

        #.. ENDTIME is beginning of next sub
        SUB=`readSub`
        TIMINGS=`echo "$SUB" | sed -n 2p`

        ENDTIME=`echo $TIMINGS | awk '{print $1}'`
        ENDTIMEMS=`time2ms $ENDTIME`

        DELTA=`echo "scale = 8; $ENDTIMEMS - $BEGTIMEMS + 1" | bc `
        LENGTH=`ms2time $DELTA`
        
        BEGTIMENOCOMMA=`echo $BEGTIME | awk -F',' '{print $1}'`
        MISSINGSUBS+=("$BEGTIMENOCOMMA $LENGTH $NO_EXT--$TOKEN.wav")

        echo "$BEGTIMENOCOMMA $LENGTH $NO_EXT--$TOKEN.wav"

        READ_NEXT_SUB="0"
      fi

  
    fi
  done


  #.. print out array
  for P in ${!MISSINGSUBS[@]}; do
    PARAMS=${MISSINGSUBS[$P]}

    DELAY_TIME=`echo $PARAMS | awk '{print $1}'`
    echo "DELAY_TIME: $DELAY_TIME"

    echo "Executing: clipVideo.sh $WAV $PARAMS"
    clipVideo.sh $WAV $PARAMS

    NEWFILE=`echo $PARAMS | awk '{print $3}'`

    echo "Executing: $NEWFILE ${@:2}"
    vid2sub.sh $NEWFILE "${@:2}"
  done
)

