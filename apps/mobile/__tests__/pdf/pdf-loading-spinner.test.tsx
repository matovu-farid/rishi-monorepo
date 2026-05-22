/**
 * STA-016 — PDF reader loading screen must render an ActivityIndicator
 * alongside the "Downloading…" / "Loading book…" copy. MOBI/DJVU/EPUB
 * already do; PDF was missing the spinner (issue #92).
 *
 * We pin the wiring at the source level — the established pattern for
 * reader-screen tests in this suite (see `pdf-reader-highlight-tap.test.tsx`).
 */

import { readFileSync } from 'fs'
import { join } from 'path'

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

describe('STA-016 — PDF reader loading screen', () => {
  it('imports ActivityIndicator from react-native', () => {
    expect(src).toMatch(/ActivityIndicator/)
    // ensure the import is real, not an accidental string match
    expect(src).toMatch(/from\s+['"]react-native['"][\s\S]{0,5}/)
    expect(src.includes('ActivityIndicator')).toBe(true)
  })

  it('renders <ActivityIndicator size="large" /> in the loading branch', () => {
    // The loading branch is gated on `if (loading)` and returns the
    // reader-loading testID View. Pin the spinner inside that branch.
    expect(src).toMatch(
      /if\s*\(loading\)\s*\{[\s\S]{0,400}<ActivityIndicator[\s\S]{0,80}size=["']large["'][\s\S]{0,500}testID=["']reader-loading["']|testID=["']reader-loading["'][\s\S]{0,500}<ActivityIndicator[\s\S]{0,80}size=["']large["']/,
    )
  })

  it('keeps the differentiated "Downloading…" vs "Loading book…" copy', () => {
    expect(src).toMatch(/Downloading…/)
    expect(src).toMatch(/Loading book…/)
  })
})
