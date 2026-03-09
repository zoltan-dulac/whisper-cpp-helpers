#!/bin/bash
#this workaround script exists because Whisper.cpp doesnt currently support sentence splitting

#info output
if [[ $# -ne 2 ]]; then
	echo "$0 <input video> <model path>" >&2
	exit 0
fi

#extract audio
ffmpeg -i "$1" -ar 16000 "$1".wav
whisper-cli -ojf -of out -pp -l en -mc 38 -bs 6 -bo 6 -tp 0.3 -m "$2" "$1".wav
rm "${1%.*}.srt"

SED="gsed" 

#generate clean srt
jq -r '
  .transcription[].tokens[]
  | select(.text | test("^\\[[^]]*\\]$") | not)
  | "\(.timestamps.from)|\(.timestamps.to)|\(.text)"
' out.json | 
awk -F'|' -v outfile="${1%.*}.srt" '
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

# rm "$1".wav "out.json"                              #delete unwanted files created
echo "USING THIS SED:"
which gsed


gsed -i 's/\[[^]]*\] //g' "${1%.*}.srt"                 #remove special blocks []
# gsed -zEi 's/([^\n]*\n){3}\[.*\]\n//g' "${1%.*}.srt" #remove last special block []\n