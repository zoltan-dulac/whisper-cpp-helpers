#!/usr/bin/env python3
"""
Split SRT cues at sentence boundaries and re-time each sentence
to avoid overlaps by dividing the original cue duration.

Usage:
  python3 srt_sentence_split_timed.py input.srt output.srt
Options:
  --by {words,chars}        weighting basis (default: words)
  --min-dur SECONDS         minimum duration per sentence (default: 0.80)
  --max-dur SECONDS         maximum duration per sentence (default: 8.00)
  --gap SECONDS             tiny gap between new cues (default: 0.02)
"""

import argparse, re, os, sys
from typing import List, Tuple

# --- time helpers -------------------------------------------------------------

def parse_ts(ts: str) -> float:
    # SRT supports comma decimals; accept dot as well
    ts = ts.strip().replace(',', '.')
    h, m, s = ts.split(':')
    return int(h)*3600 + int(m)*60 + float(s)

def fmt_ts(t: float) -> str:
    if t < 0: t = 0.0
    ms = int(round((t - int(t)) * 1000))
    s  = int(t) % 60
    m  = (int(t)//60) % 60
    h  = int(t)//3600
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

# --- SRT parsing/writing ------------------------------------------------------

Cue = Tuple[int, float, float, str]  # (index, start_s, end_s, text)

TIMELINE = re.compile(r'^\s*(\d{2}:\d{2}:\d{2}[,.]\d{3})\s*-->\s*(\d{2}:\d{2}:\d{2}[,.]\d{3})')

def read_srt(path: str) -> List[Cue]:
    with open(path, 'r', encoding='utf-8', errors='replace') as f:
        data = f.read().strip()
    parts = re.split(r'\r?\n\s*\r?\n', data)
    cues = []
    idx_counter = 1
    for block in parts:
        lines = block.splitlines()
        if not lines: continue
        # allow optional numeric index line
        line0 = 0
        if re.fullmatch(r'\d+', lines[0].strip() or ''):
            line0 = 1
        if line0 >= len(lines): continue
        m = TIMELINE.match(lines[line0])
        if not m: continue
        start, end = parse_ts(m.group(1)), parse_ts(m.group(2))
        text = "\n".join(lines[line0+1:]).strip()
        cues.append((idx_counter, start, end, text))
        idx_counter += 1
    return cues

def write_srt(cues: List[Cue], path: str) -> None:
    with open(path, 'w', encoding='utf-8') as f:
        for i, (_, s, e, text) in enumerate(cues, start=1):
            f.write(f"{i}\n{fmt_ts(s)} --> {fmt_ts(e)}\n{text.strip()}\n\n")

# --- sentence splitting -------------------------------------------------------

# Basic sentence splitter: cuts at ., !, ? followed by space/end or closing quote/bracket
SENTENCE_RE = re.compile(
    r"""              # minimal, practical splitter
    (                 # capture a sentence
      .*?             # non-greedy up to...
      [\.\?\!]+       # terminal punctuation
      (?:["'\)\]]+)?  # optional closing quote/bracket
    )
    (?=\s+|$)         # followed by whitespace or end
    """,
    re.VERBOSE | re.DOTALL
)

def split_sentences(text: str) -> List[str]:
    # Preserve original line breaks/tags in output; only use a "plain" copy to detect ends
    plain = re.sub(r'<[^>]+>', ' ', text)         # strip HTML-ish tags for detection
    plain = re.sub(r'\s+', ' ', plain).strip()
    pieces = [m.group(1).strip() for m in SENTENCE_RE.finditer(plain)]
    if not pieces:
        return [text.strip()] if text.strip() else []
    # If there is a trailing fragment without terminal punctuation, append it as last piece
    consumed = " ".join(pieces)
    tail = plain[len(consumed):].strip()
    if tail:
        pieces.append(tail)
    # Now, map these pieces back into the original text roughly by splitting on the same punctuation boundaries.
    # Simple approach: split original on sentence regex too.
    orig_pieces = [m.group(1).strip() for m in SENTENCE_RE.finditer(text)]
    if orig_pieces:
        # Append tail from original too, if any
        consumed_o = "".join(orig_pieces)
        tail_o = text[len(consumed_o):].strip()
        if tail_o:
            orig_pieces.append(tail_o)
        return [p for p in orig_pieces if p]
    return pieces

# --- duration allocation ------------------------------------------------------

def weights(sentences: List[str], mode: str) -> List[int]:
    if mode == 'chars':
        return [max(1, len(re.sub(r'\s+', '', s))) for s in sentences]
    # default words
    return [max(1, len(re.findall(r"\w+", s))) for s in sentences]

def allocate_durations(total: float, n: int, w: List[int],
                       min_dur: float, max_dur: float) -> List[float]:
    if n == 1:
        return [max(min_dur, min(max_dur, total))]
    S = sum(w) if sum(w) > 0 else n
    # initial proportional allocation
    dur = [total * wi / S for wi in w]
    # enforce min
    for i in range(n):
        if dur[i] < min_dur: dur[i] = min_dur
    # if we exceed total, scale back the excess from items above min_dur
    def total_d(d): return sum(d)
    if total_d(dur) > total:
        # iterative shrink until fit
        for _ in range(10):
            excess = total_d(dur) - total
            if excess <= 1e-6: break
            room = [max(0.0, di - min_dur) for di in dur]
            R = sum(room)
            if R <= 1e-9:
                # cannot shrink further; just normalize hard
                scale = total / total_d(dur)
                dur = [di*scale for di in dur]
                break
            for i in range(n):
                if room[i] > 0:
                    cut = excess * (room[i]/R)
                    dur[i] -= cut
    # enforce max, then redistribute leftover to others (rare)
    for i in range(n):
        if dur[i] > max_dur: dur[i] = max_dur
    # If we now sum to less than total, distribute remainder proportionally
    rem = total - total_d(dur)
    if rem > 1e-6:
        W = sum(w)
        if W == 0: W = n
        for i in range(n):
            dur[i] += rem * (w[i]/W)
    return dur

# --- main processing ----------------------------------------------------------

def process(cues: List[Cue], by: str, min_dur: float, max_dur: float, gap: float) -> List[Cue]:
    out: List[Cue] = []
    for _, start, end, text in cues:
        start = float(start); end = float(end)
        if end <= start:
            # ignore zero/negative length cues
            continue
        sentences = split_sentences(text)
        if len(sentences) <= 1:
            out.append((0, start, end, text.strip()))
            continue
        total = end - start
        w = weights(sentences, by)
        durs = allocate_durations(total, len(sentences), w, min_dur, max_dur)

        # Build non-overlapping slices within [start, end]
        t0 = start
        new_parts = []
        for i, s in enumerate(sentences):
            t1 = t0 + durs[i]
            # last slice must end exactly at original end to avoid drift
            if i == len(sentences) - 1:
                t1 = end
            # Apply tiny gap after each slice except the last; gap is realized by advancing start of next slice
            new_parts.append((t0, t1, s.strip()))
            t0 = t1 + (gap if i < len(sentences) - 1 else 0.0)
            if t0 > end:
                t0 = end

        # Ensure monotonic non-overlap
        for (s0, s1, txt) in new_parts:
            s0 = max(start, min(s0, end))
            s1 = max(s0, min(s1, end))
            if s1 - s0 >= 0.01:  # discard too-short fragments
                out.append((0, s0, s1, txt))

    # Sort by time and reindex
    out.sort(key=lambda c: (c[1], c[2]))
    reindexed = [(i+1, s, e, txt) for i, (_, s, e, txt) in enumerate(out)]
    return reindexed

def parse_args():
    ap = argparse.ArgumentParser(description="Split SRT cues at sentence boundaries and re-time them to avoid overlaps.")
    ap.add_argument("infile")
    ap.add_argument("outfile")
    ap.add_argument("--by", choices=["words","chars"], default="words", help="allocation weight basis")
    ap.add_argument("--min-dur", type=float, default=0.80, help="minimum seconds per sentence")
    ap.add_argument("--max-dur", type=float, default=8.00, help="maximum seconds per sentence")
    ap.add_argument("--gap", type=float, default=0.02, help="tiny gap between newly created cues")
    return ap.parse_args()

def main():
    args = parse_args()
    if not os.path.exists(args.infile):
        print(f"[ERROR] Input not found: {args.infile}", file=sys.stderr)
        sys.exit(1)
    cues = read_srt(args.infile)
    if not cues:
        print(f"[ERROR] No cues parsed from: {args.infile}", file=sys.stderr)
        sys.exit(2)
    new_cues = process(cues, args.by, args.min_dur, args.max_dur, args.gap)
    os.makedirs(os.path.dirname(args.outfile) or ".", exist_ok=True)
    write_srt(new_cues, args.outfile)
    print(f"[OK] Wrote {args.outfile} with {len(new_cues)} cues.")

if __name__ == "__main__":
    main()
