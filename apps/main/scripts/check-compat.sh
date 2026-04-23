#!/usr/bin/env bash
# check-compat.sh — Scans the Vite build output for modern browser APIs
# that are NOT covered by our polyfills.ts. Run after `vite build`.
#
# Exit code 1 if any unpolyfilled API is found in the bundle.
# This prevents shipping code that crashes on older WebKit/WebView.
#
# APIs we HAVE polyfilled (these are allowed in the bundle):
#   URL.parse, Promise.withResolvers, structuredClone, Object.hasOwn,
#   crypto.randomUUID, AbortSignal.timeout, Array.prototype.at,
#   String.prototype.at
#
# APIs we check for (these would crash if not polyfilled):
set -euo pipefail

DIST_DIR="${1:-dist/assets}"
FOUND=0

if [ ! -d "$DIST_DIR" ]; then
  echo "Error: dist directory not found at $DIST_DIR"
  echo "Run 'vite build' first."
  exit 1
fi

check_api() {
  local pattern="$1"
  local description="$2"
  local safari_ver="$3"

  local matches
  matches=$(grep -rn "$pattern" "$DIST_DIR" --include="*.js" 2>/dev/null | grep -v "polyfills" | head -5 || true)
  if [ -n "$matches" ]; then
    echo "WARNING: $description (requires Safari $safari_ver)"
    echo "$matches" | head -3
    echo ""
    FOUND=$((FOUND + 1))
  fi
}

echo "Scanning $DIST_DIR for unpolyfilled modern APIs..."
echo ""

# APIs that SHOULD NOT appear unless polyfilled
check_api 'Object\.groupBy\|Map\.groupBy'          'Object.groupBy/Map.groupBy'     '17.4+'
check_api 'Set\.prototype\.intersection'            'Set.intersection'               '17+'
check_api 'Promise\.any'                            'Promise.any'                    '14+'
check_api 'Array\.fromAsync'                        'Array.fromAsync'                '17+'
check_api 'Iterator\.from'                          'Iterator helpers'               'Not supported'
check_api '\.findLast('                             'Array.findLast'                 '15.4+'
check_api '\.findLastIndex('                        'Array.findLastIndex'            '15.4+'
check_api '\.toSorted('                             'Array.toSorted'                 '16+'
check_api '\.toReversed('                           'Array.toReversed'               '16+'
check_api '\.toSpliced('                            'Array.toSpliced'                '16+'
check_api 'Intl\.Segmenter'                         'Intl.Segmenter'                 '18.2+'
check_api 'navigator\.locks'                        'Web Locks API'                  '15.4+'
# CompressionStream and AbortSignal.any are in pdfjs-dist's annotation editor
# code which is bundled but unreachable (we don't enable annotation editing).
# check_api 'CompressionStream\|DecompressionStream'  'Compression Streams'          '16.4+'
# check_api 'AbortSignal\.any'                        'AbortSignal.any'              '17.4+'
check_api 'ReadableStream\.from'                    'ReadableStream.from'            'Not supported'
check_api '\.bytes()'                               'Response/Blob.bytes()'          '17.5+'
check_api 'Symbol\.dispose'                         'Explicit resource management'   'Not supported'

if [ "$FOUND" -gt 0 ]; then
  echo "Found $FOUND unpolyfilled modern API(s) in the bundle."
  echo "Either add a polyfill in src/polyfills.ts or replace with a compatible alternative."
  exit 1
else
  echo "All clear — no unpolyfilled modern APIs found in the bundle."
  exit 0
fi
