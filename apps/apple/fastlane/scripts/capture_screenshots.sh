#!/usr/bin/env bash
# Captures placeholder screenshots for every required device frame so
# `UPLOAD_SCREENSHOTS=1 fastlane release_app_store` is required to upload captures
# before real captures land. Replace with real captures from the post-a11y
# UI before publishing to App Store Connect.
#
# Real-capture workflow (manual, documented in docs/RELEASE.md):
#   1. Boot the device-frame simulator
#   2. Launch the rishi app
#   3. Navigate to each screen (library, reader, chat, voice, settings)
#   4. xcrun simctl io <UDID> screenshot <path>.png
#
# This script seeds 1x1 PNG placeholders so the lane is structurally
# verifiable today. The script is idempotent: it will NOT overwrite an
# existing PNG (so real captures committed in place survive re-runs).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/screenshots/en-US"

FRAMES=("iphone_6_9" "iphone_6_7" "ipad_13" "ipad_11" "mac")

mkdir -p "$OUT"

for frame in "${FRAMES[@]}"; do
  mkdir -p "$OUT/$frame"
  for i in 01 02 03 04 05; do
    target="$OUT/$frame/$i.png"
    if [[ ! -f "$target" ]]; then
      # Emit a valid 1x1 PNG with python3 (always present on macOS / CI runners).
      # Avoids depending on imagemagick / sips / sharp.
      python3 -c "
import struct, zlib, sys
sig = b'\x89PNG\r\n\x1a\n'
ihdr = struct.pack('>IIBBBBB', 1, 1, 8, 2, 0, 0, 0)
ihdr_chunk = b'IHDR' + ihdr
ihdr_crc = zlib.crc32(ihdr_chunk)
ihdr_block = struct.pack('>I', 13) + ihdr_chunk + struct.pack('>I', ihdr_crc)
raw = b'\x00\xff\xff\xff'
comp = zlib.compress(raw)
idat_chunk = b'IDAT' + comp
idat_crc = zlib.crc32(idat_chunk)
idat_block = struct.pack('>I', len(comp)) + idat_chunk + struct.pack('>I', idat_crc)
iend_chunk = b'IEND'
iend_crc = zlib.crc32(iend_chunk)
iend_block = struct.pack('>I', 0) + iend_chunk + struct.pack('>I', iend_crc)
sys.stdout.buffer.write(sig + ihdr_block + idat_block + iend_block)
" > "$target"
      echo "[capture_screenshots] seeded placeholder $target"
    else
      echo "[capture_screenshots] keep existing $target"
    fi
  done
done

echo "[capture_screenshots] done."
