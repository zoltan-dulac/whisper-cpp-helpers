#!/usr/bin/env python3
"""
break-at-sentences.py

Post-process a whisper.cpp SRT so captions break more cleanly at sentence
boundaries.

What it does:
- Parses an input SRT
- Merges adjacent caption fragments into larger sentence-like chunks
- Splits those chunks back into readable subtitle cards
- Prefers sentence punctuation as breakpoints
- Wraps to at most 2 lines
- Uses a max characters-per-line limit
- Optionally respects a characters-per-second target

Example:
    python3 break-at-sentences.py input.srt output.srt

Optional:
    python3 break-at-sentences.py input.srt output.srt \
        --max-cpl 42 \
        --max-lines 2 \
        --max-cps 18 \
        --min-duration 1.0 \
        --max-duration 6.0
"""

from __future__ import annotations

import argparse
import math
import re
from dataclasses import dataclass
from typing import List, Tuple


TIME_RE = re.compile(
    r"(\d{2}):(\d{2}):(\d{2}),(\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2}),(\d{3})"
)


@dataclass
class Caption:
    start: float
    end: float
    text: str


def srt_time_to_seconds(h: str, m: str, s: str, ms: str) -> float:
    return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000.0


def seconds_to_srt_time(value: float) -> str:
    value = max(0.0, value)
    hours = int(value // 3600)
    value -= hours * 3600
    minutes = int(value // 60)
    value -= minutes * 60
    seconds = int(value)
    milliseconds = int(round((value - seconds) * 1000))

    if milliseconds == 1000:
        milliseconds = 0
        seconds += 1
    if seconds == 60:
        seconds = 0
        minutes += 1
    if minutes == 60:
        minutes = 0
        hours += 1

    return f"{hours:02}:{minutes:02}:{seconds:02},{milliseconds:03}"


def normalize_whitespace(text: str) -> str:
    text = text.replace("\n", " ")
    text = re.sub(r"\s+", " ", text).strip()
    # Remove spaces before punctuation
    text = re.sub(r"\s+([,.;:!?])", r"\1", text)
    # Clean up spaces after opening punctuation if weird source
    text = re.sub(r"([(\[\"'])\s+", r"\1", text)
    return text


def parse_srt(content: str) -> List[Caption]:
    blocks = re.split(r"\n\s*\n", content.strip(), flags=re.MULTILINE)
    captions: List[Caption] = []

    for block in blocks:
        lines = [line.rstrip("\r") for line in block.splitlines() if line.strip()]
        if not lines:
            continue

        time_line_index = None
        for i, line in enumerate(lines):
            if "-->" in line:
                time_line_index = i
                break

        if time_line_index is None:
            continue

        match = TIME_RE.search(lines[time_line_index])
        if not match:
            continue

        start = srt_time_to_seconds(*match.groups()[0:4])
        end = srt_time_to_seconds(*match.groups()[4:8])

        text_lines = lines[time_line_index + 1 :]
        text = normalize_whitespace(" ".join(text_lines))
        if not text:
            continue

        captions.append(Caption(start=start, end=end, text=text))

    return captions


def ends_sentence(text: str) -> bool:
    text = text.strip()
    if not text:
        return False
    return bool(re.search(r'[.!?]["\')\]]*$', text))


def looks_like_hard_stop(text: str) -> bool:
    text = text.strip()
    if not text:
        return False
    return ends_sentence(text) or text.endswith(":") or text.endswith(";")

def starts_lowercase(text: str) -> bool:
    text = text.strip()
    if not text:
        return False
    first = text[0]
    return first.isalpha() and first.islower()


def should_merge(prev_text: str, next_text: str, gap: float, max_merge_gap: float) -> bool:
    """
    Decide whether next_text likely continues prev_text.
    """
    if gap > max_merge_gap:
        return False

    prev_text = prev_text.strip()
    next_text = next_text.strip()

    if not prev_text or not next_text:
        return False

    # Strong signal to STOP merging if previous already looks complete
    if looks_like_hard_stop(prev_text):
        # But continue if next clearly continues a quote or odd formatting
        if starts_lowercase(next_text):
            return True
        return False

    # Strong signal to merge if previous ends with comma or no punctuation
    if re.search(r"[,–—-]$", prev_text):
        return True

    if re.search(r"[A-Za-z0-9\"]$", prev_text):
        return True

    if starts_lowercase(next_text):
        return True

    return False


def merge_into_sentence_groups(
    captions: List[Caption],
    max_merge_gap: float,
    max_group_duration: float,
) -> List[Caption]:
    if not captions:
        return []

    groups: List[Caption] = []
    current = Caption(
        start=captions[0].start,
        end=captions[0].end,
        text=captions[0].text,
    )

    for nxt in captions[1:]:
        gap = nxt.start - current.end
        prospective_duration = nxt.end - current.start

        if (
            should_merge(current.text, nxt.text, gap, max_merge_gap)
            and prospective_duration <= max_group_duration
        ):
            current.text = normalize_whitespace(f"{current.text} {nxt.text}")
            current.end = nxt.end
        else:
            groups.append(current)
            current = Caption(start=nxt.start, end=nxt.end, text=nxt.text)

    groups.append(current)
    return groups


def split_into_sentences(text: str) -> List[str]:
    """
    Conservative sentence splitter.
    """
    text = normalize_whitespace(text)
    if not text:
        return []

    parts = re.split(r'(?<=[.!?]["\')\]])\s+|(?<=[.!?])\s+', text)
    parts = [p.strip() for p in parts if p.strip()]
    return parts if parts else [text]


def wrap_words(words: List[str], max_cpl: int, max_lines: int) -> Tuple[List[str], List[str]]:
    """
    Build up to max_lines lines greedily.
    Returns (used_lines, remaining_words).
    """
    lines: List[str] = []
    remaining = words[:]

    for _ in range(max_lines):
        if not remaining:
            break

        line_words = [remaining.pop(0)]
        while remaining:
            trial = " ".join(line_words + [remaining[0]])
            if len(trial) <= max_cpl:
                line_words.append(remaining.pop(0))
            else:
                break

        lines.append(" ".join(line_words))

    return lines, remaining


def split_long_sentence(text: str, max_cpl: int, max_lines: int) -> List[str]:
    """
    Split oversized text into subtitle-sized chunks.
    """
    words = text.split()
    chunks: List[str] = []

    while words:
        lines, words = wrap_words(words, max_cpl=max_cpl, max_lines=max_lines)
        if not lines:
            break
        chunks.append("\n".join(lines))

    return chunks


def text_fits_card(text: str, max_cpl: int, max_lines: int) -> bool:
    chunks = split_long_sentence(text, max_cpl=max_cpl, max_lines=max_lines)
    return len(chunks) == 1


def split_group_to_cards(text: str, max_cpl: int, max_lines: int) -> List[str]:
    """
    Prefer sentence boundaries, then fall back to line wrapping.
    """
    sentences = split_into_sentences(text)
    if not sentences:
        return []

    cards: List[str] = []
    current = ""

    for sentence in sentences:
        trial = sentence if not current else f"{current} {sentence}"
        if text_fits_card(trial, max_cpl, max_lines):
            current = trial
        else:
            if current:
                cards.append(current)
                current = sentence
            else:
                # Single sentence too large; hard-wrap it
                cards.extend(split_long_sentence(sentence, max_cpl, max_lines))
                current = ""

    if current:
        cards.append(current)

    final_cards: List[str] = []
    for card in cards:
        if text_fits_card(card, max_cpl, max_lines):
            wrapped = split_long_sentence(card, max_cpl, max_lines)
            final_cards.extend(wrapped)
        else:
            final_cards.extend(split_long_sentence(card, max_cpl, max_lines))

    return final_cards


def allocate_durations(
    total_start: float,
    total_end: float,
    card_texts: List[str],
    min_duration: float,
    max_duration: float,
    max_cps: float,
) -> List[Tuple[float, float]]:
    """
    Allocate times proportionally by text length, then clamp.
    """
    total_available = max(0.1, total_end - total_start)
    lengths = [max(1, len(re.sub(r"\s+", "", t))) for t in card_texts]
    total_len = sum(lengths)

    desired = []
    for t, length in zip(card_texts, lengths):
        by_share = total_available * (length / total_len)
        by_cps = max(len(t.replace("\n", " ")) / max_cps, min_duration)
        d = max(by_share, by_cps, min_duration)
        d = min(d, max_duration)
        desired.append(d)

    desired_total = sum(desired)

    if desired_total <= total_available:
        # distribute remaining slack proportionally
        slack = total_available - desired_total
        if slack > 0 and total_len > 0:
            desired = [
                d + slack * (length / total_len)
                for d, length in zip(desired, lengths)
            ]
    else:
        # compress proportionally to fit, then enforce minimums as best effort
        scale = total_available / desired_total
        desired = [d * scale for d in desired]

        # best-effort minimum enforcement
        for i, d in enumerate(desired):
            if d < min_duration:
                desired[i] = min_duration

        # if minimums overflow, just distribute evenly
        if sum(desired) > total_available:
            even = total_available / len(desired)
            desired = [even] * len(desired)

    spans: List[Tuple[float, float]] = []
    cursor = total_start
    for i, d in enumerate(desired):
        if i == len(desired) - 1:
            end = total_end
        else:
            end = cursor + d
        spans.append((cursor, end))
        cursor = end

    return spans


def reflow_captions(
    captions: List[Caption],
    max_merge_gap: float,
    max_group_duration: float,
    max_cpl: int,
    max_lines: int,
    min_duration: float,
    max_duration: float,
    max_cps: float,
) -> List[Caption]:
    merged = merge_into_sentence_groups(
        captions,
        max_merge_gap=max_merge_gap,
        max_group_duration=max_group_duration,
    )

    out: List[Caption] = []

    for group in merged:
        cards = split_group_to_cards(
            group.text,
            max_cpl=max_cpl,
            max_lines=max_lines,
        )

        if not cards:
            continue

        spans = allocate_durations(
            total_start=group.start,
            total_end=group.end,
            card_texts=cards,
            min_duration=min_duration,
            max_duration=max_duration,
            max_cps=max_cps,
        )

        for (start, end), text in zip(spans, cards):
            out.append(Caption(start=start, end=end, text=text))

    return out


def write_srt(captions: List[Caption], path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        for i, cap in enumerate(captions, start=1):
            f.write(f"{i}\n")
            f.write(
                f"{seconds_to_srt_time(cap.start)} --> {seconds_to_srt_time(cap.end)}\n"
            )
            f.write(f"{cap.text}\n")
            if i != len(captions):
                f.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reflow whisper.cpp SRT captions into more sentence-aware subtitle blocks."
    )
    parser.add_argument("input_srt", help="Input SRT file")
    parser.add_argument("output_srt", help="Output SRT file")
    parser.add_argument("--max-cpl", type=int, default=42, help="Max characters per line")
    parser.add_argument("--max-lines", type=int, default=2, help="Max lines per caption")
    parser.add_argument("--max-cps", type=float, default=18.0, help="Approx max characters per second")
    parser.add_argument("--min-duration", type=float, default=1.0, help="Minimum caption duration in seconds")
    parser.add_argument("--max-duration", type=float, default=6.0, help="Maximum caption duration in seconds")
    parser.add_argument(
        "--max-merge-gap",
        type=float,
        default=0.45,
        help="Maximum silent gap between captions to still consider merging",
    )
    parser.add_argument(
        "--max-group-duration",
        type=float,
        default=12.0,
        help="Maximum duration of a merged sentence group",
    )

    args = parser.parse_args()

    with open(args.input_srt, "r", encoding="utf-8-sig") as f:
        content = f.read()

    captions = parse_srt(content)
    out = reflow_captions(
        captions=captions,
        max_merge_gap=args.max_merge_gap,
        max_group_duration=args.max_group_duration,
        max_cpl=args.max_cpl,
        max_lines=args.max_lines,
        min_duration=args.min_duration,
        max_duration=args.max_duration,
        max_cps=args.max_cps,
    )
    write_srt(out, args.output_srt)


if __name__ == "__main__":
    main()