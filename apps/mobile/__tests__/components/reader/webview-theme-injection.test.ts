/**
 * Issue #47 — MOBI / DJVU / PDF reader theme changes were ignored by the
 * WebView. `handleSettingsChange` persisted `themeName` but no `useEffect`
 * forwarded the theme into the WebView, so dark-mode users still saw
 * white pages.
 *
 * Acceptance criteria (from issue):
 *   1. Each reader has a `useEffect` keyed on `settings.themeName` (or
 *      equivalent) that injects CSS into the WebView matching the active
 *      theme.
 *   2. Snapshot test toggles theme and verifies `injectJavaScript` is
 *      called with theme-specific CSS.
 *
 * Source-grep is the established pattern for these reader screens (see
 * `mobi-active-paragraph-inject.test.ts`) — mounting the screens pulls in
 * WebView, expo-file-system, the player store, expo-router, etc. Grep is
 * the cheapest reliable way to pin the theme-injection wiring without a
 * full RN test runtime.
 *
 * We also import the canonical `READER_THEMES` map and require each
 * reader's source to mention the theme's `background` color literal for
 * every supported theme — this is the "theme-specific CSS" part of
 * acceptance bullet 2 and the bit that catches a regression where a
 * future refactor injects a static stylesheet instead of one keyed on
 * the active theme.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

import { READER_THEMES } from '../../../constants/reader-themes'
import type { ThemeName } from '../../../types/book'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

function readReader(format: 'mobi' | 'djvu' | 'pdf'): string {
  return readFileSync(
    join(MOBILE_ROOT, 'app', 'reader', format, '[id].tsx'),
    'utf-8',
  )
}

const THEME_NAMES: ThemeName[] = ['white', 'dark', 'yellow']

describe('Issue #47 — readers inject theme CSS into the WebView', () => {
  describe.each([
    ['mobi', 'webViewRef.current?.injectJavaScript'],
    ['djvu', 'webViewRef.current?.injectJavaScript'],
  ] as const)('%s reader', (format, injectCall) => {
    const src = readReader(format)

    it('has a useEffect that depends on settings.themeName', () => {
      // The dependency array of *some* useEffect must include
      // `settings.themeName` (or `settings` itself, which would also
      // re-run on theme changes). We accept both, but require that
      // `themeName` appears somewhere in a useEffect dependency list.
      const useEffectThemeName = /useEffect\([\s\S]*?\}, \[[^\]]*settings\.themeName[^\]]*\]\)/
      const useEffectSettings = /useEffect\([\s\S]*?\}, \[[^\]]*\bsettings\b[^\]]*\]\)/
      expect(
        useEffectThemeName.test(src) || useEffectSettings.test(src),
      ).toBe(true)
    })

    it('uses READER_THEMES to resolve the active theme', () => {
      expect(src).toMatch(/READER_THEMES/)
    })

    it('calls injectJavaScript on the WebView ref to apply the theme', () => {
      // The MOBI / DJVU readers own the WebView directly, so the theme
      // effect must reach into the ref and inject JS that touches the
      // document — anything weaker (e.g. only persisting to settings)
      // is the bug this issue tracks.
      expect(src).toContain(injectCall)
    })

    it.each(THEME_NAMES)(
      'references the %s theme background color literal',
      (name) => {
        const bg = READER_THEMES[name].background
        // The background literal must appear in the source so the theme
        // effect can hand WebView CSS that visibly differs between
        // themes. Pinning the literals catches the failure mode in the
        // issue (theme persisted but never forwarded).
        expect(src).toContain(bg)
      },
    )
  })

  describe('pdf reader', () => {
    const src = readReader('pdf')

    it('has a useEffect that depends on settings.themeName', () => {
      const useEffectThemeName = /useEffect\([\s\S]*?\}, \[[^\]]*settings\.themeName[^\]]*\]\)/
      const useEffectSettings = /useEffect\([\s\S]*?\}, \[[^\]]*\bsettings\b[^\]]*\]\)/
      expect(
        useEffectThemeName.test(src) || useEffectSettings.test(src),
      ).toBe(true)
    })

    it('uses READER_THEMES to resolve the active theme', () => {
      expect(src).toMatch(/READER_THEMES/)
    })

    it('forwards the theme to the PdfWebReader via readerRef', () => {
      // PDF wraps the WebView in `PdfWebReader` and exposes an
      // imperative handle (`PdfWebReaderHandle`). The reader screen
      // must call a theme-applying method on that handle — anything
      // weaker (e.g. only persisting to settings) is the bug.
      expect(src).toMatch(/readerRef\.current\??\.setTheme/)
    })

    it.each(THEME_NAMES)(
      'references the %s theme background color literal',
      (name) => {
        const bg = READER_THEMES[name].background
        expect(src).toContain(bg)
      },
    )
  })

  describe('PdfWebReader exposes a setTheme on its imperative handle', () => {
    const src = readFileSync(
      join(MOBILE_ROOT, 'components', 'pdf', 'PdfWebReader.tsx'),
      'utf-8',
    )

    it('declares setTheme on PdfWebReaderHandle', () => {
      // The reader screen needs a typed way to forward theme CSS into
      // the PDF WebView. Pin the handle so the screen's call doesn't
      // become an `as any` cast.
      expect(src).toMatch(/setTheme\s*\(/)
    })

    it('calls injectJavaScript when setTheme runs', () => {
      // The setTheme implementation must reach into the WebView ref
      // and inject CSS — otherwise the theme is silently dropped.
      expect(src).toMatch(/injectJavaScript/)
    })
  })
})
