/**
 * RDR-022 — PDF's `legacyTopRight` thumbnails + outline buttons live
 * outside the ReaderShell auto-hide flow. The `SafeAreaView` wrapper is
 * statically rendered, so the buttons stay visible even after the bottom
 * bar has dismissed itself. Apple Books / electron tuck all chrome on
 * the same auto-hide flow.
 *
 * Post-fix: the legacy cluster consumes `ReaderShellContext.bottomBarVisible`
 * and its container drops `opacity` / `pointerEvents` together when the
 * bar is hidden.
 *
 * Source-grep — we avoid mounting the PDF reader because it imports
 * react-native-webview and many native modules.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', 'pdf', '[id].tsx'),
  'utf-8',
)

describe('RDR-022 — PDF legacyTopRight follows ReaderShell auto-hide', () => {
  it('consumes ReaderShellContext for visibility', () => {
    // The reader screen already imports ReaderShellContext via the
    // `@/components/reader` barrel; the legacy cluster must read
    // `bottomBarVisible` from it.
    expect(SRC).toMatch(/ReaderShellContext/)
    expect(SRC).toMatch(/bottomBarVisible/)
  })

  it('binds opacity to bottomBarVisible so the cluster fades with the bar', () => {
    // Either via `opacity: bottomBarVisible ? 1 : 0` or
    // `opacity: visible ? 1 : 0`. We allow either binding shape.
    expect(SRC).toMatch(/opacity:\s*\w*[Vv]isible\s*\?\s*1\s*:\s*0/)
  })

  it('drops pointer events when the bar is hidden so the buttons cannot be tapped through', () => {
    // Without this, the icons stay tappable even when invisible.
    expect(SRC).toMatch(/pointerEvents=\{?['"]?\w*[Vv]isible/)
  })
})
