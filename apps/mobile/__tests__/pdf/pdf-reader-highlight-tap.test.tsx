/**
 * CG16 — PDF highlight tap handler.
 *
 * The PDF reader's WebView emits a `highlightTapped` outgoing message
 * when the user taps an existing highlight overlay. The reader screen
 * (`app/reader/pdf/[id].tsx`) opens a recolor / delete picker anchored
 * at the tap point.
 *
 * This test pins the contract end-to-end without mounting the full
 * reader (which pulls in WebView, expo-file-system, the entire RAG
 * stack, and a half-dozen Zustand stores):
 *
 *   1. The bridge parses a `highlightTapped` message into the typed
 *      payload `{ highlightId, anchor }` (already covered by
 *      `pdf-webview-bridge.test.ts` — re-asserted here as the
 *      contract surface).
 *   2. `PdfWebReader` dispatches that payload to
 *      `propsRef.current.onHighlightTapped(highlightId, anchor)` —
 *      verified by source-grep.
 *   3. The reader screen wires `onHighlightTapped={handleHighlightTapped}`
 *      and `handleHighlightTapped` finds the matching highlight in its
 *      local list and opens the picker (`setPickerHighlight` +
 *      `setPickerAnchor`) — verified by source-grep + structural
 *      pattern match.
 *
 * Source-grep is the established pattern for reader-screen wiring
 * tests in this suite (see `goto-page-android.test.tsx`, the
 * `*-tts-wiring.test.tsx` files).
 */

import { readFileSync } from 'fs'
import { join } from 'path'

import { parseOutgoing } from '@/components/pdf/pdf-webview-bridge'

describe('CG16 — PDF highlight tap routing (parse layer)', () => {
  it('parses a highlightTapped outgoing message into the typed payload', () => {
    const raw = JSON.stringify({
      type: 'highlightTapped',
      highlightId: 'h-42',
      anchor: { x: 150, y: 320 },
    })
    const parsed = parseOutgoing(raw)
    expect(parsed).toEqual({
      type: 'highlightTapped',
      highlightId: 'h-42',
      anchor: { x: 150, y: 320 },
    })
  })

  it('defaults missing anchor coordinates to (0, 0)', () => {
    // The bridge tolerates a missing/partial `anchor` by zero-filling —
    // the reader screen can still open the picker, it just opens at the
    // top-left corner of the page. We pin this default so a refactor
    // that switches to "reject on missing anchor" forces an explicit
    // decision.
    const raw = JSON.stringify({
      type: 'highlightTapped',
      highlightId: 'h-42',
    })
    expect(parseOutgoing(raw)).toEqual({
      type: 'highlightTapped',
      highlightId: 'h-42',
      anchor: { x: 0, y: 0 },
    })
  })

  it('rejects highlightTapped with a non-string highlightId', () => {
    const raw = JSON.stringify({
      type: 'highlightTapped',
      highlightId: 123,
      anchor: { x: 0, y: 0 },
    })
    expect(parseOutgoing(raw)).toBeNull()
  })
})

// ── PdfWebReader dispatch wiring ────────────────────────────────────────────
//
// The `dispatchOutgoing` closure inside `PdfWebReader` routes the
// parsed `highlightTapped` payload to `props.onHighlightTapped` via a
// `propsRef.current.onHighlightTapped?.(...)` optional call. We pin the
// wiring at the source level so a refactor that drops or renames the
// route is caught.
describe('CG16 — PdfWebReader routes highlightTapped to onHighlightTapped', () => {
  const SRC_PATH = join(
    __dirname,
    '..',
    '..',
    'components',
    'pdf',
    'PdfWebReader.tsx',
  )
  const src = readFileSync(SRC_PATH, 'utf-8')

  it('exposes onHighlightTapped as a prop in PdfWebReaderProps', () => {
    expect(src).toMatch(/onHighlightTapped\?\(highlightId:\s*string,\s*anchor:\s*\{/)
  })

  it('dispatches highlightTapped to props.onHighlightTapped with (highlightId, anchor)', () => {
    // Match the closure that invokes onHighlightTapped — must reference
    // BOTH `msg.highlightId` and `msg.anchor` (so a half-implementation
    // that forgets the anchor is caught).
    expect(src).toMatch(
      /case\s+['"]highlightTapped['"][\s\S]{0,200}onHighlightTapped\?\.\(msg\.highlightId,\s*msg\.anchor\)/,
    )
  })
})

// ── Reader-screen handler wiring (PdfNativeReader) ─────────────────────────
//
// After the Task-15 route swap, `app/reader/pdf/[id].tsx` uses PdfNativeReader.
// PdfNativeReader exposes `onHighlightTap?: (id: string) => void` (no anchor).
// The route forwards the id to `handleHighlightTapped(id, { x: 0, y: 0 })`.
// The handler looks the tapped highlight up in local state and opens the
// recolor/delete picker via `setPickerHighlight` + `setPickerAnchor`.
describe('CG16 — PDF reader screen opens the picker on highlight tap', () => {
  const SRC_PATH = join(
    __dirname,
    '..',
    '..',
    'app',
    'reader',
    'pdf',
    '[id].tsx',
  )
  const src = readFileSync(SRC_PATH, 'utf-8')

  it('wires onHighlightTap on the PdfNativeReader and calls handleHighlightTapped', () => {
    // The route now uses PdfNativeReader.onHighlightTap and delegates to
    // handleHighlightTapped with a zero-origin anchor.
    expect(src).toMatch(/onHighlightTap=\{/)
    expect(src).toMatch(/handleHighlightTapped\(id,/)
  })

  it('defines handleHighlightTapped with (highlightId, anchor) and looks up by id', () => {
    // The handler must:
    //  - accept (highlightId, anchor)
    //  - find the row by `id === highlightId` in the `highlights` list
    //  - bail early if no match (no popover for a removed row)
    expect(src).toMatch(
      /handleHighlightTapped\s*=\s*useCallback\(\s*\(highlightId:\s*string,\s*anchor[\s\S]{0,300}highlights\.find\(/,
    )
    expect(src).toMatch(
      /handleHighlightTapped\s*=\s*useCallback\([\s\S]{0,400}if\s*\(!h\)\s*return/,
    )
  })

  it('opens the picker by setting both pickerHighlight and pickerAnchor', () => {
    expect(src).toMatch(
      /handleHighlightTapped\s*=\s*useCallback\([\s\S]{0,400}setPickerHighlight\(h\)[\s\S]{0,80}setPickerAnchor\(anchor\)/,
    )
  })

  it('declares the pickerHighlight and pickerAnchor state hooks the handler drives', () => {
    expect(src).toMatch(/useState<PdfHighlight\s*\|\s*null>\(null\)/)
    expect(src).toMatch(/setPickerAnchor/)
  })
})
