/**
 * RDR-026 — EPUB readerEngine has no loading indicator while epubjs parses
 * the spine. The outer `loading` state only covers DB fetch + R2
 * download; once that flips, the user stares at a blank theme-coloured
 * screen until epubjs finishes parsing and `onLocationChange` fires.
 *
 * Post-fix: an in-shell `ActivityIndicator` overlay renders until the
 * reader engine reports its first location change. A boolean state
 * (`engineReady`) is set inside `handleLocationChange`; the overlay is
 * gated on `!engineReady`.
 *
 * Source-grep is the established pattern for reader-screen wiring tests
 * in this suite — we avoid mounting the full reader because it pulls in
 * many heavy native modules.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', '[id].tsx'),
  'utf-8',
)

describe('RDR-026 — EPUB reader shows an engine-loading overlay until the first location change', () => {
  it('declares an engineReady state', () => {
    // Pin the `const [engineReady, setEngineReady] = useState(false)` shape.
    expect(SRC).toMatch(/\[\s*engineReady\s*,\s*setEngineReady\s*\]\s*=\s*useState/)
  })

  it('flips engineReady to true inside handleLocationChange', () => {
    // Pin the assignment shape so a future refactor that drops the wiring
    // (e.g. forgets to set the flag) fails the test.
    expect(SRC).toMatch(/setEngineReady\s*\(\s*true\s*\)/)
  })

  it('renders an ActivityIndicator gated on !engineReady', () => {
    // Anchor: a JSX block that conditions on engineReady === false (or
    // !engineReady) and renders an ActivityIndicator.
    expect(SRC).toMatch(/!\s*engineReady[\s\S]{0,800}ActivityIndicator/)
  })

  it('the overlay carries a testID so Detox can wait on it', () => {
    expect(SRC).toMatch(/testID=['"]reader-engine-loading['"]/)
  })
})
