# whisper-cpp-helpers
A suite of shell scripts I use to make captioning and subtitling with Whisper.cpp easier.

This repository will include the following tools:

1. `vid2sub.sh`: A tool that will take a video that `ffmpeg` can read, convert the audio to a format Whisper.cpp understands and captions/subtitles it.
2. `generateMissingSubs.sh`: Since Whisper.cpp can produce hallucinations if the video is very long and has a lot of background music or noise along with spoken word, I created this shell script to generate captions in only certain parts of a video.
3. `fixWhisperSubs.sh`: Another tool that will take subtitles that appear on the screen a lot longer than they are spoken normally.  This will prevent captions and subtitles appearing prematurely (which is something that happens with Whisper.cpp generated content sometimes).

This repository will be populated before the AccessU 2025 Accessibility conference in May. 
