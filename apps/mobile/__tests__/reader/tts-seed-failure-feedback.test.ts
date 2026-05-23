/**
 * STA-017 (#93) — TTS seed failure on PDF / MOBI / DJVU must surface a
 * non-blocking, user-visible cue (toast + accessibility announcement).
 *
 * The EPUB reader already calls
 *   AccessibilityInfo.announceForAccessibility('No text available for reading')
 * inside its handleToggleTTS seed branch. The PDF/MOBI/DJVU siblings
 * silently `console.warn` and return — sighted users get nothing.
 *
 * Acceptance: each PDF/MOBI/DJVU `handleToggleTTS` (toolbar Read-Aloud)
 * must:
 *   1. Show a toast / snackbar via the existing `undoSnackbar.show(...)` hook.
 *   2. Call AccessibilityInfo.announceForAccessibility with parity copy.
 *
 * The four readers all instantiate `undoSnackbar` via `useUndoSnackbar()`
 * and render the snackbar element — adding a `.show(...)` call from the
 * seed-failure branches is a one-liner that reuses the shipping surface.
 *
 * Mounting the reader screens directly is infeasible (WebView, RAG, all
 * platform parsers, etc.); follow the source-grep convention.
 */
import { readFileSync } from 'fs'
import { join } from 'path'

const APP_ROOT = join(__dirname, '..', '..')

const READERS = [
  { label: 'PDF', relpath: ['app', 'reader', 'pdf', '[id].tsx'] },
  { label: 'MOBI', relpath: ['app', 'reader', 'mobi', '[id].tsx'] },
  { label: 'DJVU', relpath: ['app', 'reader', 'djvu', '[id].tsx'] },
] as const

function read(r: (typeof READERS)[number]): string {
  return readFileSync(join(APP_ROOT, ...r.relpath), 'utf-8')
}

/**
 * Locate the source slice for `handleToggleTTS` so the assertions below
 * only inspect the toolbar's Read-Aloud handler (not the selection path,
 * which #97 covers separately).
 */
function toggleTtsSlice(src: string): string {
  const start = src.indexOf('handleToggleTTS')
  if (start === -1) return ''
  const end = src.indexOf('}, [', start)
  return src.slice(start, end === -1 ? src.length : end + 4)
}

describe('STA-017 — PDF/MOBI/DJVU TTS seed failure surfaces a toast', () => {
  for (const r of READERS) {
    const src = read(r)
    const slice = toggleTtsSlice(src)

    it(`${r.label}: imports AccessibilityInfo`, () => {
      expect(src).toMatch(
        /import\s+\{[^}]*AccessibilityInfo[^}]*\}\s+from\s+['"]react-native['"]/,
      )
    })

    it(`${r.label}: handleToggleTTS announces failure for VoiceOver users`, () => {
      expect(slice).toMatch(
        /AccessibilityInfo\.announceForAccessibility\(/,
      )
    })

    it(`${r.label}: handleToggleTTS surfaces a toast via undoSnackbar.show on seed failure`, () => {
      expect(slice).toMatch(/undoSnackbar\.show\(/)
    })

    it(`${r.label}: handleToggleTTS no longer silently swallows seed failures (catch must surface UI feedback)`, () => {
      // The catch branch must call undoSnackbar.show (visible feedback),
      // not just console.warn.
      const catchBlock = slice.match(/catch\s*\([^)]*\)\s*\{[\s\S]*?\}\s*\}/)
      expect(catchBlock).not.toBeNull()
      if (catchBlock) {
        expect(catchBlock[0]).toMatch(/undoSnackbar\.show\(/)
      }
    })
  }
})
