/**
 * STA-024 (#97) — Selection-TTS failure on PDF / MOBI / DJVU must give
 * the user feedback, matching the EPUB reader's behavior.
 *
 * The EPUB reader's `handleReadFromSelection`
 * (`apps/mobile/app/reader/[id].tsx`) calls
 *   AccessibilityInfo.announceForAccessibility('No text available for reading')
 *   AccessibilityInfo.announceForAccessibility('Could not find the selected text')
 * when seed or resolver returns null. The PDF/MOBI/DJVU siblings:
 *   - PDF: pops an Alert for resolver-null (blocking, native dialog) and
 *          silently console.warn's for seed-throw.
 *   - MOBI/DJVU: silently `return` on every failure path.
 *
 * Acceptance:
 *   All four readers (a) announce via AccessibilityInfo AND (b) show a
 *   visible toast on selection-TTS failure. We don't enforce removal of
 *   PDF's Alert — replacing it with a toast is fine; we just lock in a
 *   non-blocking visible cue exists.
 */
import { readFileSync } from 'fs'
import { join } from 'path'

const APP_ROOT = join(__dirname, '..', '..')

const READERS = [
  { label: 'PDF', relpath: ['app', 'reader', 'pdf', '[id].tsx'], handler: 'handleReadFromSelection' },
  { label: 'MOBI', relpath: ['app', 'reader', 'mobi', '[id].tsx'], handler: 'handleReadFromSelection' },
  { label: 'DJVU', relpath: ['app', 'reader', 'djvu', '[id].tsx'], handler: 'handleReadFromSelection' },
] as const

function read(r: (typeof READERS)[number]): string {
  return readFileSync(join(APP_ROOT, ...r.relpath), 'utf-8')
}

/**
 * Locate the source slice for the selection-TTS handler so the
 * assertions only inspect read-from-selection (not the toolbar Read-
 * Aloud, which #93 covers).
 */
function selectionHandlerSlice(src: string, handler: string): string {
  const start = src.indexOf(handler)
  if (start === -1) return ''
  // Find the matching closing of useCallback (a `, [...])` block).
  const closingIdx = src.indexOf('}, [', start)
  if (closingIdx === -1) return src.slice(start)
  // Include the deps array so dep-list assertions can also be made.
  const after = src.indexOf(')', closingIdx)
  return src.slice(start, after === -1 ? src.length : after + 1)
}

describe('STA-024 — PDF/MOBI/DJVU selection-TTS failures announce + show a toast', () => {
  for (const r of READERS) {
    const src = read(r)
    const slice = selectionHandlerSlice(src, r.handler)

    it(`${r.label}: ${r.handler} announces failure via AccessibilityInfo`, () => {
      expect(slice).toMatch(
        /AccessibilityInfo\.announceForAccessibility\(/,
      )
    })

    it(`${r.label}: ${r.handler} shows a non-blocking toast via undoSnackbar.show on failure`, () => {
      expect(slice).toMatch(/undoSnackbar\.show\(/)
    })

    it(`${r.label}: ${r.handler}'s seed-failure catch surfaces UI feedback (not just console.warn)`, () => {
      // The catch branch around the seed call must call undoSnackbar.show
      // and/or AccessibilityInfo.announceForAccessibility — not silently
      // swallow the error.
      const catchBlock = slice.match(/catch\s*\([^)]*\)\s*\{[\s\S]*?\n\s*\}/)
      expect(catchBlock).not.toBeNull()
      if (catchBlock) {
        expect(catchBlock[0]).toMatch(
          /undoSnackbar\.show\(|AccessibilityInfo\.announceForAccessibility\(/,
        )
      }
    })
  }
})
