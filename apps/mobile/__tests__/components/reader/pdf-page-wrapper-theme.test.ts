/**
 * Issue #231 — PR #230 (issue #47) themed the WebView body background but
 * the PDF reader's inline `<style>` block in `webview-template.ts`
 * hardcodes `.page-wrapper { background: #fff }`. In Dark / Sepia themes
 * the body re-themes, but the white rectangle behind each PDF page stays
 * bright white — a jarring contrast against the dark surround.
 *
 * Acceptance:
 *   - Each ReaderTheme yields injected CSS that includes a `.page-wrapper`
 *     rule whose background matches the active theme's `background`.
 *   - Light theme behaviour stays visually identical (still resolves to
 *     the theme's `#FFFFFF`).
 *   - The PDF webview template no longer hardcodes a static
 *     `background: #fff` on `.page-wrapper` — the injected CSS must win.
 *
 * Source-grep is the established pattern for the PDF WebView template
 * (see `pdf-webview-bridge.test.ts`) — instantiating the HTML/JS inside
 * Jest would require a real DOM + pdfjs runtime. Pinning the hardcoded
 * literal at the source level is the cheapest way to catch a regression
 * that re-introduces the white rectangle.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

import { READER_THEMES } from '../../../constants/reader-themes'
import type { ThemeName } from '../../../types/book'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

const THEME_NAMES: ThemeName[] = ['white', 'dark', 'yellow']

describe('Issue #231 — PDF .page-wrapper background follows the active theme', () => {
  describe('shared reader-theme CSS helper', () => {
    let buildReaderThemeCss: (theme: (typeof READER_THEMES)[ThemeName]) => string

    beforeAll(async () => {
      const mod = await import('../../../lib/reader-theme-css')
      buildReaderThemeCss = mod.buildReaderThemeCss
    })

    it.each(THEME_NAMES)(
      'emits a .page-wrapper rule using the %s theme background',
      (name) => {
        const theme = READER_THEMES[name]
        const css = buildReaderThemeCss(theme)
        // Must mention `.page-wrapper` as a selector and carry the
        // theme's background literal somewhere in the same stylesheet —
        // proving that a theme toggle visibly re-paints the wrapper.
        expect(css).toMatch(/\.page-wrapper\b/)
        // The same generated CSS must reference the theme's background
        // colour. We deliberately use a substring assertion (not a
        // strict-equality regex) so the helper is free to render the
        // rule with !important, additional declarations, or surrounding
        // whitespace — the contract is "wrapper uses the theme colour",
        // not a particular formatter style.
        const wrapperRule = css
          .split('\n')
          .find((line) => /\.page-wrapper\b/.test(line))
        expect(wrapperRule).toBeDefined()
        expect(wrapperRule).toContain(theme.background)
      },
    )

    it('does not leak the light background into the dark stylesheet', () => {
      const dark = buildReaderThemeCss(READER_THEMES.dark)
      // The pre-fix template used `#fff` as the static wrapper colour;
      // pin that it no longer appears in the dark stylesheet so a future
      // refactor can't quietly re-introduce the bright rectangle.
      expect(dark).not.toMatch(/#fff\b/i)
      expect(dark).not.toMatch(/#ffffff\b/i)
    })
  })

  describe('PDF webview template', () => {
    const TEMPLATE_PATH = join(
      MOBILE_ROOT,
      'components',
      'pdf',
      'webview-template.ts',
    )
    const src = readFileSync(TEMPLATE_PATH, 'utf-8')

    it('does not hardcode a static background:#fff on .page-wrapper', () => {
      // The bug: an inline `<style>` rule like
      //   `.page-wrapper { ...; background: #fff; ... }`
      // wins over the injected stylesheet whenever the latter omits the
      // selector. Strip whitespace before matching so a reformatter
      // (single-line vs. multi-line declaration block) can't sneak the
      // hardcoded literal back in.
      const stripped = src.replace(/\s+/g, ' ')
      // Match any `.page-wrapper { ... background: #fff ... }` declaration
      // block — `[^}]*` keeps the assertion inside a single rule body.
      const offendingRule = /\.page-wrapper\s*\{[^}]*background\s*:\s*#fff\b[^}]*\}/i
      expect(stripped).not.toMatch(offendingRule)
    })
  })
})
