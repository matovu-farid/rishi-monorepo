/**
 * P1-K — MOBI / DJVU "Read from selection" bridge.
 *
 * The EPUB reader exposes a `menuItems` selection menu with a
 * "Read from here" action that calls `resolveEpubReadFromSelection`
 * and dispatches PLAY_FROM. MOBI and DJVU had no equivalent.
 *
 * Post-fix:
 *   - The MOBI / DJVU WebView template injects a `selectionchange`
 *     bridge that posts `{ type: 'selection', text }` to RN.
 *   - The reader screen's `onMessage` handler captures `selection` and
 *     wires it to the plain-text resolver
 *     (`resolvePlainTextReadFromSelection`) → PLAY_FROM.
 *
 * Source-grep is the established pattern for reader-screen wiring tests
 * in this suite (see `reader-tap-region.test.ts`,
 * `reader-sheets-wiring.test.ts`). We avoid mounting the full reader
 * screens because they pull in WebView, expo-file-system, the player
 * store, and many other modules that have nothing to do with this fix.
 *
 * Per-format limitations:
 *   - MOBI WebView renders selectable HTML → the bridge works as-is.
 *   - DJVU is canvas-only (no text layer yet) → the bridge is wired so
 *     the reader doesn't crash when a future text-layer/OCR phase fires
 *     selection events, but in practice `window.getSelection()` over a
 *     canvas returns an empty string and the menu never appears.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

function readReader(relPath: string): string {
  return readFileSync(join(MOBILE_ROOT, relPath), 'utf-8')
}

describe('P1-K — MOBI reader Read-from-selection wiring', () => {
  const src = readReader('app/reader/mobi/[id].tsx')

  it("WebView template installs a 'selectionchange' bridge", () => {
    expect(src).toMatch(/addEventListener\(\s*['"]selectionchange['"]/)
  })

  it("WebView template posts a `{ type: 'selection', text }` message", () => {
    // Match the JSON.stringify call carrying type:'selection' with a text field.
    expect(src).toMatch(
      /JSON\.stringify\(\{\s*type:\s*['"]selection['"][\s\S]*?text/,
    )
  })

  it('reader screen imports the plain-text selection resolver', () => {
    expect(src).toMatch(/resolvePlainTextReadFromSelection/)
  })

  it("onMessage handler branches on `msg.type === 'selection'`", () => {
    expect(src).toMatch(/msg\.type\s*===\s*['"]selection['"]/)
  })

  it('dispatches a PLAY_FROM event into the player store', () => {
    expect(src).toMatch(/type:\s*['"]PLAY_FROM['"]/)
  })
})

describe('P1-K — DJVU reader Read-from-selection wiring', () => {
  const src = readReader('app/reader/djvu/[id].tsx')

  it("WebView template installs a 'selectionchange' bridge", () => {
    // DJVU is canvas-only today, but we still mount the bridge so the
    // reader survives future text-layer / OCR phases without a code
    // change. Documented in a leading comment in the source.
    expect(src).toMatch(/addEventListener\(\s*['"]selectionchange['"]/)
  })

  it("WebView template posts a `{ type: 'selection', text }` message", () => {
    expect(src).toMatch(
      /JSON\.stringify\(\{\s*type:\s*['"]selection['"][\s\S]*?text/,
    )
  })

  it('reader screen imports the plain-text selection resolver', () => {
    expect(src).toMatch(/resolvePlainTextReadFromSelection/)
  })

  it("onMessage handler branches on `msg.type === 'selection'`", () => {
    expect(src).toMatch(/msg\.type\s*===\s*['"]selection['"]/)
  })

  it('dispatches a PLAY_FROM event into the player store', () => {
    expect(src).toMatch(/type:\s*['"]PLAY_FROM['"]/)
  })

  it('documents the canvas-only limitation in a leading comment', () => {
    // Anchor: a comment near the selection bridge explaining the caveat
    // so future maintainers know why the bridge is wired but inert today.
    expect(src).toMatch(/canvas/i)
    expect(src).toMatch(/text layer|OCR|Phase 7/i)
  })
})
