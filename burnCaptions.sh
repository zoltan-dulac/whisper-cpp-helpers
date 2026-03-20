#!/bin/bash

if [ "$#" != "3" ]
then 
    echo "Usage: $0 <input-video> <srt-file> <output-video>" 1>&2
    echo 1>&2
    exit 1
fi

ffmpeg -i $1 -vf subtitles=$2 -c:v libx264 -crf 18 -preset slow -c:a copy $3