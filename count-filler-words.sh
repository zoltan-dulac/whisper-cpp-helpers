#!/usr/bin/env bash
# Count filler words/phrases in an SRT/VTT file.
# Env overrides:
#   FILLERS="um,uh,erm,hmm,like,so,well,actually,basically,literally"
#   PHRASES="you know,i mean,kind of,sort of"
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 subtitles.srt|.vtt" >&2
  exit 1
fi

FILE="$1"
: "${FILLERS:=um,uh,erm,ermm,er,hmm,like,so,well,actually,basically,literally,okay,right}"
: "${PHRASES:=you know,i mean,kind of,sort of}"

awk -v fillers="$FILLERS" -v phrases="$PHRASES" '
function parse_time(ts,   t,a,h,m,s) {
  gsub(/,/, ".", ts);                    # handle SRT decimals
  split(ts, a, ":");                     # HH:MM:SS(.ms)
  h = a[1]+0; m = a[2]+0; s = a[3]+0.0;
  return h*3600 + m*60 + s;
}
function tolower_str(s,   i){ for(i=1;i<=length(s);i++) s=tolower(s); return s } # POSIX awk has tolower()
BEGIN{
  IGNORECASE=1
  FS="\n"
  start_seen=0
  first_start=-1
  last_end=0
  text=""
  # build single-word filler set
  nfill=split(fillers, F, / *, */)
  for(i=1;i<=nfill;i++){
    gsub(/^ +| +$/, "", F[i]); gsub(/ +/, " ", F[i]);
    if(F[i]!="") singles[F[i]]=1
  }
  # build multi-word phrase list
  nphr=split(phrases, P, / *, */)
  for(i=1;i<=nphr;i++){
    gsub(/^ +| +$/, "", P[i]); gsub(/ +/, " ", P[i]);
    if(P[i]!="") { phrases_list[++phr_count]=P[i]; }
  }
}
# Timestamp lines: "00:00:01,200 --> 00:00:03,400"  (SRT) or VTT with dots
/-->/ {
  # extract start/end stamps
  split($0, parts, / *--> *| +|	/)
  start_ts = parts[1]
  end_ts   = parts[3]
  s = parse_time(start_ts)
  e = parse_time(end_ts)
  if(first_start<0) first_start=s
  if(e>last_end) last_end=e
  next
}
# Skip cue numbers and WEBVTT header
/^[0-9]+$/ { next }
(/^WEBVTT/ || /^Kind:/ || /^Language:/) { next }
# Accumulate subtitle text (strip tags)
{
  line=$0
  gsub(/<[^>]+>/, " ", line)       # remove HTML/italics tags
  gsub(/\[[[:alpha:] ]+\]/, " ", line)   # remove [music], [applause] etc.
  text = text " " line
}
END{
  # Normalize text: lower, keep letters/spaces only
  # Convert apostrophes/hyphens to spaces to avoid false merges
  t = tolower(text)
  gsub(/[’'\-]/, " ", t)
  gsub(/[^a-z ]+/, " ", t)
  gsub(/  +/, " ", t)
  gsub(/^ +| +$/, "", t)

  # Tokenize
  n = split(t, W, / +/)
  total_words = 0
  for(i=1;i<=n;i++){
    if(W[i]!=""){ total_words++; }
  }

  # Count single-word fillers
  for(i=1;i<=n;i++){
    w=W[i]
    if(w in singles){
      counts[w]++
      total_fillers++
    }
  }

  # Count multi-word phrases with sliding window
  # Support up to 4-word phrases (adjustable)
  maxN=4
  for(pi=1; pi<=phr_count; pi++){
    phrase = phrases_list[pi]
    split(phrase, PH, / +/)
    plen = length(PH)
    if(plen>maxN) maxN=plen
    if(plen==0) continue
    for(i=1; i<=n-plen+1; i++){
      matchOK=1
      for(k=1; k<=plen; k++){
        if(W[i+k-1] != PH[k]){ matchOK=0; break }
      }
      if(matchOK){
        pkey=phrase
        counts[pkey]++
        total_fillers++
        i += (plen-1) # advance to avoid overlapping counts like you know know
      }
    }
  }

  # Duration and rates
  duration_s = (first_start>=0 && last_end>first_start) ? (last_end-first_start) : 0
  duration_min = (duration_s>0) ? duration_s/60.0 : 0

  # Output
  printf "File: %s\n", FILENAME
  printf "Duration: %s (%.1f min)\n", (duration_s>0?duration_s" s":"unknown"), duration_min
  printf "Total words: %d\n", total_words
  printf "Total fillers: %d\n", (total_fillers+0)
  if(total_words>0){
    printf "Fillers as %% of words: %.2f%%\n", (100.0*total_fillers/total_words)
  }
  if(duration_min>0){
    printf "Fillers per minute: %.2f\n", (total_fillers/duration_min)
  }
  printf "\nBreakdown:\n"
  # Print singles first
  for(w in singles){
    if(counts[w]>0) printf "  %-12s %6d\n", w, counts[w]
  }
  # Then phrases
  for(pi=1; pi<=phr_count; pi++){
    p=phrases_list[pi]
    if(counts[p]>0) printf "  %-12s %6d\n", p, counts[p]
  }
}
' "$FILE"
