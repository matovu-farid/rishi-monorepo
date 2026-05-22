/**
 * P0-D / P0-E / P0-F — PDF / MOBI / DJVU reader screens must wire the
 * full ReaderShell `sheets` prop (TOC, Highlights, Bookmarks, Search,
 * Appearance, NoteEditor) — matching the EPUB reader.
 *
 * Pre-fix:
 *   - PDF passed `sheets={{ noteEditor: true }}` (5 sheets missing)
 *   - MOBI passed `sheets={{}}` (6 sheets missing)
 *   - DJVU passed `sheets={{}}` (6 sheets missing)
 *
 * Post-fix: each reader screen passes the full sheet set. Sheets that
 * don't apply to the format (e.g. MOBI/DJVU search) still mount so the
 * toolbar UI stays consistent — they render an empty-state body.
 *
 * Source-grep is the established pattern for reader-screen wiring tests
 * (see `reader-tap-region.test.ts`). We avoid mounting the screens because
 * they pull in WebView / expo-file-system / expo-router / player stores /
 * realtime chat — none of which are relevant to this fix.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

/**
 * Extract the object literal passed to the `sheets=` prop on the
 * `<ReaderShell ...>` JSX element in a reader screen.
 *
 * The screens use the same prop shape: `sheets={{ ...keys... }}`. We
 * non-greedy match the opening `{{` through the matching `}}` so we
 * grab only the sheet flags, not the surrounding JSX.
 */
function extractSheetsProp(src: string): string {
  const match = src.match(/sheets=\{\{([\s\S]*?)\}\}/)
  if (!match) {
    throw new Error(
      'sheets={{...}} prop not found on <ReaderShell> — has it been renamed?',
    )
  }
  return match[1]
}

const SHEET_KEYS = [
  'toc',
  'highlights',
  'bookmarks',
  'search',
  'appearance',
  'noteEditor',
] as const

describe('P0-D / P0-E / P0-F — readers wire the full sheets set', () => {
  describe('PDF reader (app/reader/pdf/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'pdf', '[id].tsx'),
      'utf-8',
    )
    const sheets = extractSheetsProp(src)

    for (const key of SHEET_KEYS) {
      it(`enables the ${key} sheet`, () => {
        expect(sheets).toMatch(new RegExp(`${key}\\s*:\\s*true`))
      })
    }
  })

  describe('MOBI reader (app/reader/mobi/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'mobi', '[id].tsx'),
      'utf-8',
    )
    const sheets = extractSheetsProp(src)

    for (const key of SHEET_KEYS) {
      it(`enables the ${key} sheet`, () => {
        expect(sheets).toMatch(new RegExp(`${key}\\s*:\\s*true`))
      })
    }
  })

  describe('DJVU reader (app/reader/djvu/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'djvu', '[id].tsx'),
      'utf-8',
    )
    const sheets = extractSheetsProp(src)

    for (const key of SHEET_KEYS) {
      it(`enables the ${key} sheet`, () => {
        expect(sheets).toMatch(new RegExp(`${key}\\s*:\\s*true`))
      })
    }
  })
})
