/**
 * NAV-P2-009 — Stale Expo-template `modal.tsx` route must not ship.
 *
 * The original `apps/mobile/app/modal.tsx` was the unmodified Expo
 * template ("This is a modal" + a Link back to "/"). It was reachable
 * via deep-link `rishimobile:///modal` and could surface in future
 * route pickers. No production code referenced it.
 *
 * Pinned behaviour:
 *   1. `apps/mobile/app/modal.tsx` no longer exists (the route is
 *      removed entirely; expo-router will no-op on `/modal` deep links
 *      and let the unmatched-route screen surface).
 *   2. No source file under `apps/mobile/app/`, `components/`, or
 *      `lib/` pushes/replaces/links to `/modal`. (Guards against a
 *      future re-introduction of a dead reference.)
 */
import * as fs from 'node:fs'
import * as path from 'node:path'

const MOBILE_ROOT = path.join(__dirname, '..', '..')

function walk(dir: string, out: string[] = []): string[] {
  if (!fs.existsSync(dir)) return out
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === 'node_modules' || entry.name.startsWith('.')) continue
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      walk(full, out)
    } else if (/\.(t|j)sx?$/.test(entry.name)) {
      out.push(full)
    }
  }
  return out
}

describe('NAV-P2-009 — stale modal.tsx route removed', () => {
  it('apps/mobile/app/modal.tsx no longer exists', () => {
    const modalPath = path.join(MOBILE_ROOT, 'app', 'modal.tsx')
    expect(fs.existsSync(modalPath)).toBe(false)
  })

  it('no production source references the /modal route', () => {
    const dirs = ['app', 'components', 'lib'].map((d) =>
      path.join(MOBILE_ROOT, d),
    )
    const files = dirs.flatMap((d) => walk(d))
    const offenders: string[] = []
    // Allow this test file itself, and any *.test.* file, to mention
    // the literal — we're guarding production code, not the regression
    // test that documents the removal.
    const isTest = (p: string): boolean =>
      /[\\/]__tests__[\\/]/.test(p) || /\.test\.[tj]sx?$/.test(p)
    for (const file of files) {
      if (isTest(file)) continue
      const src = fs.readFileSync(file, 'utf8')
      // Any of: router.push('/modal'), router.replace('/modal'),
      // <Link href="/modal" …/>, or a bare '/modal' route string.
      if (
        /router\.(push|replace)\(\s*['"`]\/modal['"`]/.test(src) ||
        /href\s*=\s*['"`]\/modal['"`]/.test(src) ||
        /\bfrom\s+['"`]\/modal['"`]/.test(src)
      ) {
        offenders.push(file)
      }
    }
    expect(offenders).toEqual([])
  })
})
