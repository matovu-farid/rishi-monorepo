#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
OUTPUT_DIR="${RISHI_OUTPUT_DIR:-$SCRIPT_DIR/output}"
MODEL="${RISHI_PHONE_MODEL:-/Users/faridmatovu/Downloads/iphone_17_pro.glb}"
LIBRARY_SOURCE="${RISHI_LIBRARY_SCREEN:-/private/tmp/rishi-current-library-new.png}"
READER_SOURCE="${RISHI_READER_SCREEN:-/private/tmp/rishi-current-reader-next-new.png}"
MCP_BIN="${RISHI_MCP_BIN:-/Users/faridmatovu/projects/mockup-studio/.build/out/Products/Release/MockupStudioMCP}"
BLENDER="${RISHI_BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
FFMPEG="${RISHI_FFMPEG:-$(command -v ffmpeg || true)}"
PYTHON="${RISHI_PYTHON:-$(command -v python3 || true)}"
SWIFT="${RISHI_SWIFT:-$(command -v swift || true)}"
STORY_SWIFT="$SCRIPT_DIR/story_plate.swift"
SWIFT_MODULE_CACHE_ARGS=(-module-cache-path /private/tmp/rishi-swift-module-cache)
WIDTH="886"
HEIGHT="1920"
# Each feature opens with a short in-screen instruction, then cuts immediately
# to the product state. The complete story is 13 seconds and intentionally
# does not spend time on a title card or a transition animation.
SEGMENT_DURATION="2.6"
INSTRUCTION_DURATION="1.0"
READING_DURATION="2.4"
CHAT_DURATION="2.6"
SHARE_MENU_DURATION="1.8"
SHARE_SHEET_DURATION="2.2"
FRAME_RATE="30"

fail() { printf 'render.sh: %s\n' "$1" >&2; exit 1; }
[[ -f "$MODEL" ]] || fail "missing phone model: $MODEL"
[[ -f "$LIBRARY_SOURCE" ]] || fail "missing library screenshot: $LIBRARY_SOURCE"
[[ -f "$READER_SOURCE" ]] || fail "missing reader source: $READER_SOURCE"
[[ -f "$STORY_SWIFT" ]] || fail "missing story plate renderer: $STORY_SWIFT"
[[ -x "$BLENDER" ]] || fail "missing Blender executable: $BLENDER"
[[ -x "$MCP_BIN" ]] || fail "missing Mockup Studio MCP executable: $MCP_BIN"
[[ -n "$FFMPEG" && -x "$FFMPEG" ]] || fail "ffmpeg is not available"
[[ -n "$PYTHON" && -x "$PYTHON" ]] || fail "python3 is not available"
[[ -n "$SWIFT" && -x "$SWIFT" ]] || fail "swift is not available"
[[ -x "$STORY_SWIFT" || -f "$STORY_SWIFT" ]] || fail "story plate renderer is not available"

mkdir -p "$OUTPUT_DIR"
cleanup_stale_staging() {
  local dir pid command
  while IFS= read -r -d '' dir; do
    pid=""
    [[ -f "$dir/.rishi-active.pid" ]] && pid="$(<"$dir/.rishi-active.pid")"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
      [[ "$command" == *render.sh* ]] && continue
    fi
    rm -rf -- "$dir"
  done < <(find /private/tmp -maxdepth 1 -type d -name 'rishi-iphone-preview.*' -mmin +120 -print0)
}
# Recover only old task-owned roots whose recorded render process is no longer
# alive. This handles host crashes without deleting a long-running render.
cleanup_stale_staging
STAGING="$(mktemp -d /private/tmp/rishi-iphone-preview.XXXXXX)"
printf '%s\n' "$$" > "$STAGING/.rishi-active.pid"
cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT INT TERM

printf '%s\n' "staging: $STAGING"
printf '%s\n' "preflight: Blender 5.2 startup"
if ! "$BLENDER" --background --factory-startup --python-expr "print('RISHI_BLENDER_PREFLIGHT')" >/dev/null 2>&1; then
  printf '%s\n' "preflight warning: Blender startup probe exited non-zero; continuing with the hidden MCP render path"
fi

stage_phone_plate() {
  local source="$1"
  local name="$2"
  "$FFMPEG" -hide_banner -loglevel error -y -i "$source" -vf 'scale=886:-2,crop=886:1920:0:(ih-1920)/2' -frames:v 1 "$STAGING/${name}-crop.png"
  [[ -s "$STAGING/${name}-crop.png" ]] || fail "${name} crop was not created"
  local size
  size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$STAGING/${name}-crop.png" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
  [[ "$size" == "886x1920" ]] || fail "unexpected ${name} crop size: $size"
  cp "$STAGING/${name}-crop.png" "$STAGING/${name}.png"
}
stage_reader_plate() {
  local source="$1"
  local name="$2"
  "$FFMPEG" -hide_banner -loglevel error -y -i "$source" -vf 'scale=886:-2,crop=886:1920:0:(ih-1920)/2' -frames:v 1 "$STAGING/${name}-crop.png"
  [[ -s "$STAGING/${name}-crop.png" ]] || fail "${name} crop was not created"
  local size
  size="$(/usr/bin/sips -g pixelWidth -g pixelHeight "$STAGING/${name}-crop.png" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}')"
  [[ "$size" == "886x1920" ]] || fail "unexpected ${name} crop size: $size"
  cp "$STAGING/${name}-crop.png" "$STAGING/${name}.png"
}
stage_phone_plate "$LIBRARY_SOURCE" library
stage_reader_plate "$READER_SOURCE" reader-start

DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" instruction-reading "$STAGING/reader-start.png" "$STAGING/instruction-reading.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" chat "$STAGING/reader-start.png" "$STAGING/ai-chat.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" instruction-chat "$STAGING/reader-start.png" "$STAGING/instruction-chat.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" instruction-share "$STAGING/library.png" "$STAGING/instruction-share.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
"$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" share "$STAGING/library.png" "$STAGING/book-sharing.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" share-sheet "$STAGING/library.png" "$STAGING/share-sheet.png"
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  SWIFT_MODULECACHE_PATH=/private/tmp/rishi-swift-module-cache \
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$STORY_SWIFT" share-sent "$STAGING/library.png" "$STAGING/share-sent.png"

# Keep the hardware view locked and front-facing. The editorial push is applied
# later in the video edit so the display remains readable and the phone does not
# swing into an oblique angle while the user is trying to learn the app.
COMMON_ARGS=(--model "$MODEL" --mcp "$MCP_BIN" --blender "$BLENDER" --socket-dir "$STAGING" --width "$WIDTH" --height "$HEIGHT" --duration "$SEGMENT_DURATION" --frame-rate "$FRAME_RATE" --hero-time 3.5 --animation-preset none --camera-focal-length 95 --lighting-intensity 260 --reflection-intensity 0.025 --reflection-width 0.6 --device-roughness 0.28 --background-primary '#C9C6C2' --background-secondary '#E8E5E0')
(
  set -x
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 0.8 --media "$STAGING/instruction-reading.png" --preview-output "$STAGING/instruction-reading-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 1.4 --media "$STAGING/reader-start.png" --extra-media "$STAGING/instruction-reading.png" --preview-output "$STAGING/reading-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 0.8 --media "$STAGING/instruction-chat.png" --extra-media "$STAGING/reader-start.png" --preview-output "$STAGING/instruction-chat-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 1.4 --media "$STAGING/ai-chat.png" --extra-media "$STAGING/reader-start.png" --extra-media "$STAGING/instruction-chat.png" --preview-output "$STAGING/ai-chat-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 0.8 --media "$STAGING/instruction-share.png" --extra-media "$STAGING/library.png" --preview-output "$STAGING/instruction-share-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 1.2 --media "$STAGING/book-sharing.png" --extra-media "$STAGING/library.png" --extra-media "$STAGING/instruction-share.png" --preview-output "$STAGING/book-sharing-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 1.2 --media "$STAGING/share-sheet.png" --extra-media "$STAGING/library.png" --extra-media "$STAGING/book-sharing.png" --preview-output "$STAGING/share-sheet-hero.png"
  "$PYTHON" "$SCRIPT_DIR/mcp_render.py" "${COMMON_ARGS[@]}" --hero-time 0.8 --media "$STAGING/share-sent.png" --extra-media "$STAGING/library.png" --extra-media "$STAGING/share-sheet.png" --preview-output "$STAGING/share-sent-hero.png" --project-output "$STAGING/rishi-iphone-preview.blend"
) 2>&1 | tee "$STAGING/render.log"

[[ -s "$STAGING/instruction-reading-hero.png" && -s "$STAGING/reading-hero.png" && -s "$STAGING/instruction-chat-hero.png" && -s "$STAGING/ai-chat-hero.png" && -s "$STAGING/instruction-share-hero.png" && -s "$STAGING/book-sharing-hero.png" && -s "$STAGING/share-sheet-hero.png" && -s "$STAGING/share-sent-hero.png" ]] || fail "MCP story render missing"
[[ -s "$STAGING/rishi-iphone-preview.blend" ]] || fail "staged Blender project missing"

# The camera now fills the portrait target directly. Avoiding a second
# 1350-to-1920 upscale keeps simulator typography and controls crisp.
for plate in instruction-reading reading instruction-chat ai-chat instruction-share book-sharing share-sheet share-sent; do
  "$SWIFT" "${SWIFT_MODULE_CACHE_ARGS[@]}" "$SCRIPT_DIR/ground_shadow.swift" "$STAGING/${plate}-hero.png" "$STAGING/${plate}-grounded.png"
  [[ -s "$STAGING/${plate}-grounded.png" ]] || fail "${plate} grounding composite was not created"
  "$FFMPEG" -hide_banner -loglevel error -y -i "$STAGING/${plate}-grounded.png" -vf 'scale=1028:2227:flags=lanczos,crop=886:1920' -frames:v 1 "$STAGING/${plate}-tight.png"
  [[ -s "$STAGING/${plate}-tight.png" ]] || fail "${plate} tightening composite was not created"
  cp "$STAGING/${plate}-tight.png" "$STAGING/${plate}-hero.png"
  cp "$STAGING/${plate}-hero.png" "$STAGING/${plate}-framed.png"
done

# Video-only export: no generated bed, no silent audio track, and no audio map.
# Hard cuts make the reader states feel like pages changing. The small scale
# push keeps each still alive without delaying the next feature.
"$FFMPEG" -hide_banner -loglevel error -y \
  -loop 1 -i "$STAGING/instruction-reading-framed.png" \
  -loop 1 -i "$STAGING/reading-framed.png" \
  -loop 1 -i "$STAGING/instruction-chat-framed.png" \
  -loop 1 -i "$STAGING/ai-chat-framed.png" \
  -loop 1 -i "$STAGING/instruction-share-framed.png" \
  -loop 1 -i "$STAGING/book-sharing-framed.png" \
  -loop 1 -i "$STAGING/share-sheet-framed.png" \
  -loop 1 -i "$STAGING/share-sent-framed.png" \
  -filter_complex "[0:v]zoompan=z='min(zoom+0.00010,1.012)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=30:s=886x1920:fps=30,trim=duration=1.0,setpts=PTS-STARTPTS[s0];[1:v]zoompan=z='min(zoom+0.00018,1.016)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=72:s=886x1920:fps=30,trim=duration=2.4,setpts=PTS-STARTPTS[s1];[2:v]zoompan=z='min(zoom+0.00010,1.012)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=30:s=886x1920:fps=30,trim=duration=1.0,setpts=PTS-STARTPTS[s2];[3:v]zoompan=z='min(zoom+0.00018,1.016)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=78:s=886x1920:fps=30,trim=duration=2.6,setpts=PTS-STARTPTS[s3];[4:v]zoompan=z='min(zoom+0.00010,1.012)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=30:s=886x1920:fps=30,trim=duration=1.0,setpts=PTS-STARTPTS[s4];[5:v]zoompan=z='min(zoom+0.00018,1.014)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=54:s=886x1920:fps=30,trim=duration=1.8,setpts=PTS-STARTPTS[s5];[6:v]zoompan=z='min(zoom+0.00018,1.014)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=60:s=886x1920:fps=30,trim=duration=2.0,setpts=PTS-STARTPTS[s6];[7:v]zoompan=z='min(zoom+0.00018,1.012)':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d=36:s=886x1920:fps=30,trim=duration=1.2,setpts=PTS-STARTPTS[s7];[s0][s1][s2][s3][s4][s5][s6][s7]concat=n=8:v=1:a=0,format=yuv420p,setsar=1[v]" \
  -map '[v]' -an -t 13.0 -c:v libx264 -profile:v high -pix_fmt yuv420p -b:v 11.5M -minrate 11.5M -maxrate 11.5M -bufsize 2M -x264-params 'nal-hrd=cbr:force-cfr=1' -r "$FRAME_RATE" -fps_mode cfr -movflags +faststart "$STAGING/rishi-iphone-preview.mp4"
cp "$STAGING/reading-framed.png" "$STAGING/rishi-iphone-preview-hero.png"
RISHI_OUTPUT_DIR="$STAGING" "$SCRIPT_DIR/audit.sh"

mv -f "$STAGING/rishi-iphone-preview.blend" "$OUTPUT_DIR/rishi-iphone-preview.blend"
mv -f "$STAGING/rishi-iphone-preview.mp4" "$OUTPUT_DIR/rishi-iphone-preview.mp4"
mv -f "$STAGING/rishi-iphone-preview-hero.png" "$OUTPUT_DIR/rishi-iphone-preview-hero.png"
printf '%s\n' "render complete: $OUTPUT_DIR/rishi-iphone-preview.blend"
printf '%s\n' "render complete: $OUTPUT_DIR/rishi-iphone-preview.mp4"
printf '%s\n' "render complete: $OUTPUT_DIR/rishi-iphone-preview-hero.png"
