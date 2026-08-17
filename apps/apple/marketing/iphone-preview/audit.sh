#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
OUTPUT_DIR="${RISHI_OUTPUT_DIR:-$SCRIPT_DIR/output}"
FFPROBE="${RISHI_FFPROBE:-$(command -v ffprobe || true)}"
fail() { printf 'audit.sh: %s\n' "$1" >&2; exit 1; }
[[ -n "$FFPROBE" && -x "$FFPROBE" ]] || fail "ffprobe is not available"

BLEND="$OUTPUT_DIR/rishi-iphone-preview.blend"
VIDEO="$OUTPUT_DIR/rishi-iphone-preview.mp4"
HERO="$OUTPUT_DIR/rishi-iphone-preview-hero.png"
for path in "$BLEND" "$VIDEO" "$HERO"; do [[ -s "$path" ]] || fail "missing or empty artifact: $path"; done

IFS=, read -r CODEC WIDTH HEIGHT SAR RATE AVG_RATE NB_FRAMES < <(
  "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name,width,height,sample_aspect_ratio,r_frame_rate,avg_frame_rate,nb_frames -of csv=p=0:s=, "$VIDEO"
)
[[ "$CODEC" == "h264" ]] || fail "expected H.264, got $CODEC"
[[ "$WIDTH" == "886" && "$HEIGHT" == "1920" ]] || fail "expected 886x1920 portrait, got ${WIDTH}x${HEIGHT}"
[[ "$SAR" == "1:1" ]] || fail "expected square pixels, got SAR $SAR"
[[ "$RATE" == "30/1" && "$AVG_RATE" == "30/1" ]] || fail "expected 30/1 CFR, got $RATE and $AVG_RATE"
BITRATE="$($FFPROBE -v error -show_entries format=bit_rate -of default=nw=1:nk=1 "$VIDEO")"
awk -v bitrate="$BITRATE" 'BEGIN { if (bitrate < 9000000 || bitrate > 12000000) exit 1 }' || fail "expected H.264 bitrate near Apple\'s 10–12 Mbps target, got $BITRATE"

if AUDIO_STREAM_COUNT="$($FFPROBE -v error -select_streams a -show_entries stream=index -of csv=p=0 "$VIDEO")"; then
  [[ -z "$AUDIO_STREAM_COUNT" ]] || fail "expected video-only output, found audio stream(s): $AUDIO_STREAM_COUNT"
else
  fail "could not inspect audio streams"
fi
DURATION="$($FFPROBE -v error -show_entries format=duration -of default=nw=1:nk=1 "$VIDEO")"
awk -v duration="$DURATION" 'BEGIN { if (duration < 12.95 || duration > 13.05) exit 1 }' || fail "duration must be exactly 13 seconds, got $DURATION"
awk -v frames="$NB_FRAMES" -v duration="$DURATION" 'BEGIN { expected=duration*30; if (frames < expected-2 || frames > expected+2) exit 1 }' || fail "frame count $NB_FRAMES is inconsistent with $DURATION seconds at 30 fps"

PREV=""
BAD_STEP="$("$FFPROBE" -v error -select_streams v:0 -show_frames -show_entries frame=best_effort_timestamp_time -of csv=p=0 "$VIDEO" | awk -v prev="" 'NR==1 {prev=$1; next} {step=$1-prev; if (step < 0.032833 || step > 0.033833) {print step; exit 1} prev=$1}')" || fail "video timestamps are not constant 30 fps"

BLEND_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.blend' | wc -l | tr -d ' ')"
VIDEO_COUNT="$(find "$OUTPUT_DIR" -maxdepth 1 -type f -name '*.mp4' | wc -l | tr -d ' ')"
[[ "$BLEND_COUNT" == "1" && "$VIDEO_COUNT" == "1" ]] || fail "expected exactly one .blend and one .mp4 in $OUTPUT_DIR"

printf 'audit: PASS\n'
printf 'codec=%s size=%sx%s sar=%s frame_rate=%s avg_frame_rate=%s frames=%s duration=%ss bitrate=%sbps audio=none\n' "$CODEC" "$WIDTH" "$HEIGHT" "$SAR" "$RATE" "$AVG_RATE" "$NB_FRAMES" "$DURATION" "$BITRATE"
printf 'blend=%s\nvideo=%s\nhero=%s\n' "$BLEND" "$VIDEO" "$HERO"
