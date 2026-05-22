/**
 * P0-B / P0-C — Tap-to-toggle Pressable must cover the full reader area.
 *
 * The MOBI, DJVU, and PDF reader screens render a `<Pressable
 * testID="reader-toggle-toolbar">` whose `onPress` fires
 * `ReaderShellContext.toggleToolbar`. Pre-fix:
 *
 *   - MOBI / DJVU: a 60% × 40% band in the centre. Taps outside the
 *     band did NOT reveal the toolbar (including the Back button).
 *   - PDF: a 48pt strip pinned to the top. Taps below the strip did
 *     NOT reveal the toolbar.
 *
 * Post-fix: all three use `StyleSheet.absoluteFill` so the full page
 * area routes "missed" taps through to the toggle. The Pressable is
 * placed BEHIND the WebView in JSX order (so WebView still receives
 * scroll / select gestures); only taps the WebView doesn't consume —
 * including the always-occluded edges around its bounds — fall through.
 *
 * Source-grep is the established pattern for reader-screen wiring tests
 * in this suite (see `pdf-reader-highlight-tap.test.tsx`,
 * `goto-page-android.test.tsx`). We avoid mounting the full reader
 * screens because they pull in WebView, expo-file-system, expo-router,
 * the player store, the realtime chat hook, and many other modules
 * that have nothing to do with this fix.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

/**
 * Locate the body of the `PressableToggleToolbar` function in a reader
 * screen source. We accept either declaration form
 * (`function PressableToggleToolbar`) since the screens use the named
 * function form; using a non-greedy match up to the closing `}` of the
 * component lets us grab the Pressable's `style` prop without scooping
 * up neighbouring components.
 */
function extractPressableBlock(src: string): string {
  const match = src.match(
    /function\s+PressableToggleToolbar[\s\S]*?return\s*\(([\s\S]*?)\)\s*\n\s*\}/,
  )
  if (!match) {
    throw new Error(
      'PressableToggleToolbar component not found in source — has it been renamed?',
    )
  }
  return match[1]
}

describe('P0-B / P0-C — reader-toggle-toolbar covers the full reader area', () => {
  describe('MOBI reader (app/reader/mobi/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'mobi', '[id].tsx'),
      'utf-8',
    )
    const block = extractPressableBlock(src)

    it('uses StyleSheet.absoluteFill (not a 60% × 40% band)', () => {
      expect(block).toMatch(/StyleSheet\.absoluteFill/)
    })

    it('does NOT use the legacy 60% × 40% band coordinates', () => {
      // Defensive: the previous coordinates were
      //   top: '30%', left: '20%', width: '60%', height: '40%'
      // Match `top: '30%'` (the most specific marker) so a future
      // refactor that re-introduces a percentage band trips this test.
      expect(block).not.toMatch(/top:\s*['"]30%['"]/)
    })
  })

  describe('DJVU reader (app/reader/djvu/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'djvu', '[id].tsx'),
      'utf-8',
    )
    const block = extractPressableBlock(src)

    it('uses StyleSheet.absoluteFill (not a 60% × 40% band)', () => {
      expect(block).toMatch(/StyleSheet\.absoluteFill/)
    })

    it('does NOT use the legacy 60% × 40% band coordinates', () => {
      expect(block).not.toMatch(/top:\s*['"]30%['"]/)
    })
  })

  describe('PDF reader (app/reader/pdf/[id].tsx)', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'app', 'reader', 'pdf', '[id].tsx'),
      'utf-8',
    )
    const block = extractPressableBlock(src)

    it('uses StyleSheet.absoluteFill (not a 48pt top strip)', () => {
      expect(block).toMatch(/StyleSheet\.absoluteFill/)
    })

    it('does NOT use the legacy 48pt top-strip height', () => {
      // The previous PDF strip used `height: 48`. We don't forbid the
      // literal 48 elsewhere — only inside this component.
      expect(block).not.toMatch(/height:\s*48[,\s\n]/)
    })
  })
})
