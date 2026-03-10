#!/bin/bash

if [ "$#" != "3" ]
then
  echo "Error. Usage: $0 <input-video> <subtitle> <output-video>" 1>&2
  exit 1
fi

ffmpeg -i "$1" -vf "subtitles=$2" -c:a copy "$3"