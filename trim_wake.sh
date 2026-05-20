#!/bin/bash
# trim_wake.sh — trims a wake-word recording to a 1.5s clip
# centered on the loudest moment, at 16 kHz mono.
#
# Usage: trim_wake.sh <input.wav> <output.wav>

set -e

INPUT="$1"
OUTPUT="$2"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
  echo "Usage: $0 <input.wav> <output.wav>" >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "Input file not found: $INPUT" >&2
  exit 1
fi

# Detect the loudest moment in the file by sampling RMS levels every 100ms.
# Use ffmpeg's astats filter with metadata output, parsed via awk.
PEAK_TIME=$(ffmpeg -hide_banner -nostats -i "$INPUT" \
  -af "astats=metadata=1:reset=1:length=0.1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-" \
  -f null - 2>/dev/null \
  | awk '
      # Handles both old form "pts_time=0.1" and new form
      # "frame:N pts:M pts_time:0.1" (ffmpeg >= 7.x).
      /pts_time[=:]/ {
        s = $0
        sub(/.*pts_time[=:]/, "", s)
        sub(/[^0-9.].*$/, "", s)
        if (s != "") t = s
      }
      /RMS_level/ {
        split($1, a, "=");
        rms = a[2];
        if (rms != "-inf" && (best == "" || rms > best)) {
          best = rms;
          best_t = t;
        }
      }
      END { print best_t }
    ')

# Fallback: if peak detection failed, use the middle of the file
if [ -z "$PEAK_TIME" ]; then
  DURATION=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$INPUT")
  PEAK_TIME=$(awk -v d="$DURATION" 'BEGIN { print d / 2 }')
fi

# Compute start time = peak - 0.75s, clamped to 0
START=$(awk -v t="$PEAK_TIME" 'BEGIN { s = t - 0.75; if (s < 0) s = 0; print s }')

# Crop to a 1.5s window starting at START, force 16 kHz mono PCM 16-bit
ffmpeg -hide_banner -loglevel error -y \
  -ss "$START" -t 1.5 \
  -i "$INPUT" \
  -ar 16000 -ac 1 -sample_fmt s16 \
  "$OUTPUT"

# Verify output was created and is non-empty
if [ ! -s "$OUTPUT" ]; then
  echo "Output file was not created: $OUTPUT" >&2
  exit 1
fi
