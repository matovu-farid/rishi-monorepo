/**
 * #37 — Hidden `/explore` tab leaves a deep-link to the Expo boilerplate.
 *
 * The original `apps/mobile/app/(tabs)/explore.tsx` was the unmodified
 * Expo template ("This app includes example code to help you get
 * started…"). It was hidden from the tab bar via
 * `<Tabs.Screen name="explore" options={{ href: null }} />` but the
 * route stayed mounted in the expo-router tree, so a deep-link to
 * `rishimobile:///explore` rendered the boilerplate page. No production
 * code referenced it.
 *
 * Pinned behaviour:
 *   1. `apps/mobile/app/(tabs)/explore.tsx` no longer exists (the route
 *      is removed entirely; expo-router will no-op on `/explore` deep
 *      links and let the unmatched-route screen surface — matching the
 *      modal-route-removed treatment pinned in
 *      __tests__/app/modal-route-removed.test.ts).
 *   2. `(tabs)/_layout.tsx` no longer registers a `<Tabs.Screen
 *      name="explore" …/>` entry — the hidden screen would otherwise
 *      re-introduce the same dead route.
 *   3. No source file under `apps/mobile/app/`, `components/`, or
 *      `lib/` pushes/replaces/links to `/explore`. (Guards against a
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

describe('#37 — boilerplate /explore tab route removed', () => {
  it('apps/mobile/app/(tabs)/explore.tsx no longer exists', () => {
    const explorePath = path.join(
      MOBILE_ROOT,
      'app',
      '(tabs)',
      'explore.tsx',
    )
    expect(fs.existsSync(explorePath)).toBe(false)
  })

  it('(tabs)/_layout.tsx no longer registers <Tabs.Screen name="explore">', () => {
    const layoutPath = path.join(
      MOBILE_ROOT,
      'app',
      '(tabs)',
      '_layout.tsx',
    )
    const src = fs.readFileSync(layoutPath, 'utf8')
    // No <Tabs.Screen name="explore" …/> entry (single or double quotes).
    expect(src).not.toMatch(
      /<Tabs\.Screen\b[^>]*\bname\s*=\s*['"]explore['"]/,
    )
  })

  it('no production source references the /explore route', () => {
    const dirs = ['app', 'components', 'lib'].map((d) =>
      path.join(MOBILE_ROOT, d),
    )
    const files = dirs.flatMap((d) => walk(d))
    const offenders: string[] = []
    const isTest = (p: string): boolean =>
      /[\\/]__tests__[\\/]/.test(p) || /\.test\.[tj]sx?$/.test(p)
    for (const file of files) {
      if (isTest(file)) continue
      const src = fs.readFileSync(file, 'utf8')
      // Any of: router.push('/explore'), router.replace('/explore'),
      // <Link href="/explore" …/>, or a bare '/explore' route string.
      if (
        /router\.(push|replace)\(\s*['"`]\/explore['"`]/.test(src) ||
        /href\s*=\s*['"`]\/explore['"`]/.test(src) ||
        /\bfrom\s+['"`]\/explore['"`]/.test(src)
      ) {
        offenders.push(file)
      }
    }
    expect(offenders).toEqual([])
  })
})
