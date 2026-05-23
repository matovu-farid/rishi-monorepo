/**
 * Issue #33 — EPUB reader force-closes on iOS at mount.
 *
 * Root cause: a hot require cycle between
 *   `components/player/MiniPlayer.tsx`
 *     → imports `ReaderShellContext` from `@/components/reader/ReaderShell`
 *   `components/reader/ReaderShell.tsx`
 *     → imports `ReaderOverlay`
 *   `components/reader/ReaderOverlay.tsx`
 *     → imports `MiniPlayer`
 *
 * Metro flagged this exact cycle in the crash logs attached to the
 * issue. Cycles produce uninitialized exports under Hermes: whichever
 * module the bundler enters first stalls the others mid-evaluation. The
 * cycle in this case routes a runtime value (`ReaderShellContext`)
 * through `ReaderShell.tsx`, so the binding `MiniPlayer` captures may
 * be `undefined` at mount, and `useContext(undefined)` throws on the
 * native side — which is what the issue reports (force-close, no JS
 * error overlay).
 *
 * The fix is trivial: re-point MiniPlayer at the dedicated leaf module
 * `@/components/reader/ReaderShellContext` (which exists for exactly
 * this reason — see its file header). The cycle breaks, the binding is
 * stable, and the iOS crash goes away.
 *
 * This test pins the import path so a future refactor cannot silently
 * reintroduce the cycle. We assert against MiniPlayer's source text
 * because a full mount of MiniPlayer drags in the entire Expo native
 * surface; the regex check is faster, deterministic, and load-bearing
 * for the actual fix.
 */
import fs from 'fs'
import path from 'path'

const MOBILE_ROOT = path.resolve(__dirname, '../../..')

function readSource(rel: string): string {
  return fs.readFileSync(path.join(MOBILE_ROOT, rel), 'utf8')
}

describe('reader/player require cycle (issue #33)', () => {
  it('MiniPlayer must NOT import ReaderShellContext through the cyclic edge', () => {
    const source = readSource('components/player/MiniPlayer.tsx')

    // The cycle is reintroduced the moment any import line names
    // `@/components/reader/ReaderShell` (no trailing path segment).
    // The leaf `@/components/reader/ReaderShellContext` is fine.
    const cyclicImport = /from\s+['"]@\/components\/reader\/ReaderShell['"]/m
    expect(cyclicImport.test(source)).toBe(false)
  })

  it('MiniPlayer must source the context from the leaf module', () => {
    const source = readSource('components/player/MiniPlayer.tsx')

    const leafImport = /from\s+['"]@\/components\/reader\/ReaderShellContext['"]/m
    expect(leafImport.test(source)).toBe(true)
  })

  it('the leaf module exports a real React context (load it in isolation)', () => {
    // Sanity check: even with MiniPlayer pointed at the leaf, the leaf
    // itself must still export a valid `createContext()` result. We
    // load it in isolation so this test doesn't accidentally pick up
    // any other module's cached export.
    let leafModule: { ReaderShellContext: unknown } | null = null
    jest.isolateModules(() => {
      leafModule = require('@/components/reader/ReaderShellContext') as {
        ReaderShellContext: unknown
      }
    })
    expect(leafModule).not.toBeNull()
    const ctx = leafModule!.ReaderShellContext as { $$typeof?: symbol } | undefined
    expect(ctx).toBeDefined()
    expect(typeof ctx?.$$typeof).toBe('symbol')
  })
})
