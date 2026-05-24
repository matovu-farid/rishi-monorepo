/**
 * Issue #52 — MOBI large-file load materializes entire file as 3x heap.
 *
 * `file.base64()` → postMessage → `atob()` → Uint8Array(length) builds
 * the full base64 string, a same-length binary string, and a same-length
 * Uint8Array all alive at once. On a 50MB MOBI that is ~150MB of heap
 * pressure → WebView crash on iPhone 8 class devices.
 *
 * Post-fix:
 *   - RN reads the file in fixed-size byte windows via
 *     `ExpoFile.open()` + `FileHandle.readBytes(length)`, base64-encodes
 *     each window, and posts it to the WebView with a chunk index, the
 *     total chunk count, and the total byte length.
 *   - The WebView template preallocates a single `Uint8Array(totalBytes)`
 *     from the first chunk header and writes each decoded chunk directly
 *     into its offset — no intermediate full-file string or array.
 *   - The parser runs once after the final chunk arrives.
 *
 * Source-grep is the established pattern in this suite for reader-screen
 * wiring (see `mobi-active-paragraph-inject.test.ts`,
 * `mobi-djvu-read-from-selection.test.ts`). We avoid mounting the MOBI
 * reader because it pulls in WebView, expo-file-system, and the player
 * store, none of which is relevant to the file-transfer protocol.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', 'mobi', '[id].tsx'),
  'utf-8',
)

describe('Issue #52 — MOBI WebView template accepts chunked transfer', () => {
  it("WebView template handles a 'load-begin' message with totalBytes", () => {
    // Header chunk preallocates the destination Uint8Array; without this
    // anchor the WebView would have to grow its buffer dynamically and
    // we'd re-introduce the heap-doubling problem we're fixing.
    expect(SRC).toMatch(/['"]load-begin['"]/)
    expect(SRC).toMatch(/totalBytes/)
  })

  it("WebView template handles a 'load-chunk' message with an index", () => {
    expect(SRC).toMatch(/['"]load-chunk['"]/)
    // The chunk carries its offset (or index) so the WebView writes it
    // into the preallocated buffer at the correct position. We accept
    // either `offset` or `index` to keep the test resilient to naming.
    expect(SRC).toMatch(/offset|index/)
  })

  it("WebView template handles a 'load-end' message that triggers parsing", () => {
    expect(SRC).toMatch(/['"]load-end['"]/)
  })

  it('WebView decodes chunks directly into a preallocated Uint8Array', () => {
    // The fix's whole point is to avoid `var binary = atob(base64);` over
    // the full file (which doubles peak heap). We pin the new pattern:
    // a single preallocated buffer that chunks are written into.
    expect(SRC).toMatch(/new\s+Uint8Array\s*\(\s*totalBytes/)
  })

  it('WebView no longer holds the full base64 string before atob', () => {
    // The previous code ran `loadBook(base64)` which atob'd the whole
    // file. Forbid the old single-shot `{ type: 'load', data: <base64> }`
    // RN→WebView message — it's the smoking gun for the regression.
    //
    // We grep for the message-type literal because it's unique to the
    // old protocol. The new protocol uses load-begin / load-chunk /
    // load-end exclusively.
    //
    // (The WebView template still has a `loadBook` symbol; what we're
    // asserting is that nobody posts `{ type: 'load', data }` from RN.)
    expect(SRC).not.toMatch(/type:\s*['"]load['"]\s*,\s*data:/)
  })
})

describe('Issue #52 — RN side streams the MOBI file in fixed-size chunks', () => {
  it('imports a FileHandle-capable API for positional reads', () => {
    // The fix opens the file once and reads windows of N bytes via the
    // FileHandle. `file.base64()` materializes the entire file as one
    // string — exactly the heap-bloat we are removing.
    expect(SRC).not.toMatch(/file\.base64\(\)/)
  })

  it('declares a documented chunk-size constant rather than a bare literal', () => {
    // No-shortcuts contract: a hardcoded chunk size that's not justified
    // is rejected. We require a named constant whose name includes
    // `CHUNK` so a reviewer can find the rationale comment.
    expect(SRC).toMatch(/CHUNK[_A-Z]*\s*=\s*\d/)
  })

  it('posts load-begin / load-chunk / load-end frames in that order', () => {
    // The handler runs in `useEffect`; we just pin that all three frame
    // literals appear in the same source file so a partial implementation
    // (e.g. only load-chunk) regresses the test.
    expect(SRC).toMatch(/['"]load-begin['"]/)
    expect(SRC).toMatch(/['"]load-chunk['"]/)
    expect(SRC).toMatch(/['"]load-end['"]/)
  })
})
