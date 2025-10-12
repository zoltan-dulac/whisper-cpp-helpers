#!/bin/bash


# getting flag value from command line.
getFlagValue() {
  local name="$1"
  for i in "${!FLAG_KEYS[@]}"; do
    if [[ "${FLAG_KEYS[$i]}" == "$name" ]]; then
      echo "${FLAG_VALUES[$i]}"
      return
    fi
  done
  echo "null"
}

# This sets the optional parameter into variables.

# Arrays for flags
FLAG_KEYS=()
FLAG_VALUES=()

# Array for required (positional) args
required=()

# Parse arguments
for arg in "$@"; do
  if [[ "$arg" == --* ]]; then
    flag="${arg#--}"
    if [[ "$flag" == *=* ]]; then
      key="${flag%%=*}"
      value="${flag#*=}"
    else
      key="$flag"
      value="true"
    fi
    FLAG_KEYS+=("$key")
    FLAG_VALUES+=("$value")
  else
    required+=("$arg")
  fi
done

# Reset positional parameters to only required arguments
set -- "${required[@]}"


MODEL_ROOT=`getFlagValue model-root`
if [ "$MODEL_ROOT" = "null" ]
then
	MODEL_ROOT="$HOME/models/"
fi

LESS_HALLUCINATIONS=`getFlagValue less-hallucinations`
echo $LESS_HALLUCINATIONS



NO_EXT="${1%.*}"
WAV_FILE="$NO_EXT.wav"

if [ `getFlagValue help` = 'true' ]
then
	(
		echo
		echo "Here are the following valid flags:"
		echo
		echo "               --help: This message"
		echo "         --model-root: Set to directory that contains your whisper.cpp models"
		echo "       --no-translate: Do not translate non-English captions."
		echo "            --verbose: For more verbose output."
		echo "--less-hallunications: Use flags that theoretically produce less hallunications (beta)"
		echo  
	) 1>&2
	exit 0
fi

if [ ! -d $MODEL_ROOT ]
then
	(
		echo
		echo "Error: Directory for your whisper models doesn't exist." 
		echo "It is currently set to $MODEL_ROOT." 
		echo "If your models are in a different directory, please set"
		echo "them using the --model-root flag. (e.g. --model-root=dir=/my/path/models )."
		echo
	) 1>&2
	exit 4
elif [ "$#" != "2" -a "$#" != "3" ]
then
	(
		echo
		echo "Error. Usage: $0 <input-wav-file> <lang-code> (<model size>)"
		echo
		LS=`ls $MODEL_ROOT/ggml* | awk -F'ggml-' '{print $2}' | awk -F'.' '{print $1}' | tr '
	' ' '`
		echo $LS
		echo "Where mdoel size is one of: $LS"
		echo
		echo "Run with --help for a list of flags you can run the command with"
		echo
		exit 1
	) 1>&2 
	exit 1

elif ! command -v whisper-cli >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have whisper-cli installed on your machine and in your path."
		echo "Please follow instructions at https://github.com/ggml-org/whisper.cpp"
	) 1>&2
	exit 2
elif ! command -v srt-vtt >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have srt-vtt installed on your machine and in your path."
		echo "Please follow instructions at https://github.com/nwoltman/srt-to-vtt-cl"
		echo
	) 1>&2
	exit 3
elif ! command -v ffmpeg >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have ffmpeg installed on your machine and in your path."
		echo "Please follow instructions at https://ffmpeg.org"
		echo
	) 1>&2
	exit 3	
elif [ ! -f $1 ]
then
	(
		echo
		echo "Video file $1 doesn't exist"
		echo
	) 1>&2
	exit 10
fi

FILE=$1
LANG=$2
MODEL=$3

if [ "$#" = "2" ]
then
	MODEL="$MODEL_ROOT/ggml-large.bin"
else
	MODEL="$MODEL_ROOT/ggml-$MODEL.bin"
fi


# set quite mode for apps.
if [ `getFlagValue verbose` = "true" ]
then
	FFMPEG="ffmpeg"
else
	FFMPEG="ffmpeg  -v quiet "
fi

if [ "$WAV_FILE" != "$FILE" ]
then
	#.. First, extract 16000 Hz file from video
	echo "Extracting 16000 Hz wav from video ..."
	$FFMPEG -i $FILE -ar 16000 -ac 1 -c:a pcm_s16le $WAV_FILE
	# $FFMPEG -i $FILE -acodec pcm_s16le -ar 16000 $WAV_FILE
	echo "Done."
fi 

if [ "$LANG" == "en" -o `getFlagValue no-translate` == "true" ]
then
	TR=" -l $LANG"
	SUB_FILE="$NO_EXT.$LANG.srt"
else
	TR="-tr -l $LANG"
	SUB_FILE="$NO_EXT.en.srt"
fi


if [ "$?" = "0" ]
then
	# $WHISPER $TR --model $MODEL --max-len 40 --output-srt $WAV_FILE  
	# $WHISPER $TR --model $MODEL --split-on-word --max-len 80 --output-vtt $WAV_FILE  
	echo "Starting Whisper.cpp ..."
	echo "Confidence formating: highlighted (low confidence), underlined (medium), dim (high confidence)"
	echo "Model: $MODEL"

	
	if [ "$LESS_HALLUNICATIONS" != "null" ]
	then
		CMD="whisper-cli $TR --model $MODEL --split-on-word  --output-srt  $WAV_FILE --no-prints  --print-confidence --max-len 200 -mc 0	--beam-size 5 --temperature 0"
	else
		CMD="whisper-cli $TR --model $MODEL --split-on-word  --output-srt  $WAV_FILE --no-prints  --print-confidence --max-len 200 	"
	fi

	echo "Running: $CMD"
	$CMD
	echo "ERROR NUM: $?"
	# .. move the generated file to the right filename
	mv $WAV_FILE.srt $SUB_FILE

	if [ `getFlagValue vtt` == 'true' ]
	then
		srt-vtt $SUB_FILE
		echo "Converted sub to vtt format"
	fi

	exit 2
fi
exit 1
