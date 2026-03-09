#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

declare -a TR_ARR=()
declare -a TRDZ_ARR=()
declare -a CMD=()
declare -a FFMPEG=()

# Prefer GNU sed if available
if command -v gsed >/dev/null 2>&1; then
    SED="gsed"
else
    SED="sed"
fi



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
if ((${#required[@]})); then
  set -- "${required[@]}"
else
  set --
fi


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
		echo "  --break-on-sentence: (Experimental) Fix to ensure whisper.cpp breaks on sentence."
		echo "                       Useful on videos where the speaker is talking on without breaks"
		echo "                       and whisper doesn't break on sentences like it it normally does."
		echo "                       Code for this originally taken from this gist:"
		echo "                         https://gist.github.com/S22F5/0cb26e9bf635448ffe20041a3fb759a6"
		echo "--less-hallucinations: Use flags that theoretically produce less hallunications (beta)"
		echo "     --whisper-params: Parameters we should pass to whisper"
		echo "               --trdz: Use tiny-diarize to denote when people speak."
		echo  
	) 1>&2
	exit 0
fi


MODEL_ROOT=`getFlagValue model-root`
if [ "$MODEL_ROOT" = "null" ]
then
	MODEL_ROOT="$HOME/models/"
fi

LESS_HALLUCINATIONS=`getFlagValue less-hallucinations`

# TRDZ as array
if [[ "$(getFlagValue trdz)" == "true" ]]; then
  TRDZ_ARR=(-tdrz)
else
  TRDZ_ARR=()
fi

WHISPER_PARAMS=`getFlagValue whisper-params`

if [ "$WHISPER_PARAMS" = "null" ]
then
	WHISPER_PARAMS=""
fi


NO_EXT="${1%.*}"
WAV_FILE="$NO_EXT.wav"


if [ ! -d "$MODEL_ROOT" ]
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
elif [[ "$#" != "2" && "$#" != "3" ]]
then
	(
		echo
		echo "Error. Usage: $0 <input-wav-file> <lang-code> (<model size>)"
		echo
		LS=$(ls "$MODEL_ROOT"/ggml* 2>/dev/null | awk -F'ggml-' '{print $2}' | awk -F'.' '{print $1}' | tr '\n' ' ')
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
elif ! command -v jq >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have jq installed on your machine and in your path."
		echo "Please follow instructions at https://jqlang.org/"
		echo
	) 1>&2
	exit 3
elif [ ! -f "$1" ]
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

VAD_MODEL="$MODEL_ROOT/ggml-silero-v5.1.2.bin"

# set quite mode for apps.
if [[ `getFlagValue verbose` == "true" ]]
then
	FFMPEG=(ffmpeg)
else
	FFMPEG=(ffmpeg  -v quiet )
fi

if [ "$WAV_FILE" != "$FILE" ]
then
	if [  -f "$WAV_FILE" ]
	then
		echo "Already extracted .wav file."
	else
		#.. First, extract 16000 Hz file from video
		echo "Extracting 16000 Hz wav from video ..."
		"${FFMPEG[@]}" -i "$FILE" -ar 16000 -ac 1 -c:a pcm_s16le "$WAV_FILE"
		echo "Done."
	fi
fi 

# TR as array
if [[ "$LANG" == "en" || "$(getFlagValue no-translate)" == "true" ]]
then
  TR_ARR=(-l "$LANG")
  SUB_FILE="$NO_EXT.$LANG.srt"
else
  TR_ARR=(-tr -l "$LANG")
  SUB_FILE="$NO_EXT.en.srt"
fi


if [ "$?" = "0" ]
then
	# $WHISPER $TR --model $MODEL --max-len 40 --output-srt $WAV_FILE  
	# $WHISPER $TR --model $MODEL --split-on-word --max-len 80 --output-vtt $WAV_FILE  
	echo "Starting Whisper.cpp ..."
	echo "Confidence formating: highlighted (low confidence), underlined (medium), dim (high confidence)"
	echo "Model: $MODEL"

	# Start with required pieces
	CMD=(whisper-cli)
	CMD+=("${TR_ARR[@]}")

	# Only append TRDZ args if present
	if (( ${#TRDZ_ARR[@]} ))
	then
		CMD+=("${TRDZ_ARR[@]}")
	fi

	CMD+=(--model "$MODEL"
		  --no-prints --print-confidence -pp)

	if [[ "$LESS_HALLUCINATIONS" == "true" ]]
	then
		CMD+=(--vad -vm "$VAD_MODEL")
	else
		CMD+=(--split-on-word
				--max-len 200)
	fi

	if [ `getFlagValue break-on-sentence` = 'true' ]
	then
		CMD+=(-ojf -of "$NO_EXT" -mc 38 -bs 6 -bo 6 -tp 0.3)
	else 
		CMD+=(--output-srt)
	fi

	CMD+=( "$WAV_FILE")

	echo "Running:" ${CMD[*]}
	if [ `getFlagValue break-on-sentence` = 'true' ]
	then
		echo "******************************************************************************"
		echo "* Note: The output below will be split up by sentence in the final SRT file. *"
		echo "******************************************************************************"
	fi

	"${CMD[@]}"
	R="$?"

	if [ "$R" != "0" ]
	then
		echo "ERROR NUM: $R" 1>&2
		exit $R
	fi
	
	if [ `getFlagValue break-on-sentence` = 'true' ]
	then
		jq -r '
			.transcription[].tokens[]
			| select(.text | test("^\\[[^]]*\\]$") | not)
			| "\(.timestamps.from)|\(.timestamps.to)|\(.text)"
			' $NO_EXT.json | 
		awk -F'|' -v outfile="$SUB_FILE" '
			function flushSentence() {
				if (sentence != "") {
					printf("%d\n%s --> %s\n%s\n\n", idx, startTime, lastTime, sentence) >> outfile
					idx++
					sentence=""
				}
			}
			BEGIN { idx=1 }
			{
				from=$1; to=$2; raw=$3
				if (sentence=="") {
					startTime=from
					sub(/^ /," ",raw)
				}
				sentence = sentence raw
				lastTime=to
				if (raw ~ /[.?!]$/) {
					flushSentence()
				}
			}
			END { flushSentence() }
			'

		$SED -i 's/\[[^]]*\] //g' "$SUB_FILE"

		if [[ $? -ne 0 ]]
		then
			if [[ "$(uname)" == "Darwin" && "$SED" == "sed" ]]
			then
				echo ""
				echo "WARNING: Your system is using BSD sed (macOS default)."
				echo "This script only works with GNU sed."
				echo ""
				echo "Install it with:"
				echo "    brew install gnu-sed"
				echo "or"
				echo "    sudo port install gsed"
				echo ""
				echo "Then rerun the script."
				exit 5
			else
				echo "ERROR: sed command failed."
				exit 6
			fi
		fi

		rm $NO_EXT.json

	else
		mv -- "$WAV_FILE.srt" "$SUB_FILE"
	fi



	if [ `getFlagValue vtt` == 'true' ]
	then
		srt-vtt "$SUB_FILE"
		echo "Converted sub to vtt format"
	fi

	exit 2
fi
exit 1
