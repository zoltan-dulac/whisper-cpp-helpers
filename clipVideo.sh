if [ "$#" != "4" ]
then
	echo "USAGE: $0 <input-video> <start-time> <end-time> <output-video>" 1>&2
	echo "(with start-time and end-time in hh:mm:ss format)" 1>&2
	exit 1
elif ! command -v ffmpeg >/dev/null 2>&1; then
	(
		echo
		echo "Error: You must have ffmpeg installed on your machine and in your path."
		echo "Please follow instructions at https://ffmpeg.org"
		echo
	) 1>&2
	exit 10
fi


if [ "$2" = "0:0:0" ]
then
	echo "clip from beginning"
	ffmpeg  -v quiet -i $1  -t $3 -async 1 -c copy $4
else
	ffmpeg  -v quiet -i $1 -ss $2 -t $3 -async 1 -c copy $4
fi


