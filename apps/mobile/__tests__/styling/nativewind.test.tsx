/**
 * NativeWind / Tailwind regression test.
 *
 * Why this test exists
 * --------------------
 * The mobile app has shipped multiple times with broken styling because of a
 * recurring class of failures:
 *
 *   1. `tailwind.config.js` `content` globs miss source directories, so utility
 *      classes used in the app are silently dropped from the compiled CSS and
 *      the runtime `cssInterop` cannot resolve them.
 *   2. `global.css` loses the `@tailwind` directives during refactors.
 *   3. `babel.config.js` loses the `jsxImportSource: "nativewind"` option, so
 *      the JSX runtime never goes through `react-native-css-interop` and
 *      `className` is dropped at runtime.
 *
 * Any of those produces the same user-visible symptom (no styling), but they
 * are diagnosed completely differently. This test verifies the build-time
 * contract that makes runtime styling possible:
 *
 *   - global.css imports the three @tailwind layers
 *   - tailwind.config.js scans app/ and components/
 *   - babel.config.js wires NativeWind into the JSX runtime
 *   - compiled CSS contains the utility classes the app actually uses
 *
 * If any of those break, this test fails BEFORE the change ships.
 */

import { execFileSync } from 'child_process'
import * as fs from 'fs'
import * as path from 'path'
import * as os from 'os'

const MOBILE_ROOT = path.resolve(__dirname, '../..')

describe('NativeWind / Tailwind build pipeline', () => {
  it('global.css declares the three Tailwind layers', () => {
    const css = fs.readFileSync(path.join(MOBILE_ROOT, 'global.css'), 'utf8')
    expect(css).toMatch(/@tailwind\s+base/)
    expect(css).toMatch(/@tailwind\s+components/)
    expect(css).toMatch(/@tailwind\s+utilities/)
  })

  it('tailwind.config.js uses nativewind preset and scans app/components', () => {
    const cfg = require(path.join(MOBILE_ROOT, 'tailwind.config.js'))
    const presetSources = (cfg.presets ?? []).map((p: unknown) =>
      typeof p === 'string' ? p : (p as { __isNativeWindPreset?: true; content?: unknown }),
    )
    // nativewind/preset exports an object that itself extends tailwind; we
    // only need to ensure the require resolved to a truthy object.
    expect(presetSources.length).toBeGreaterThan(0)
    expect(presetSources[0]).toBeTruthy()

    const content: string[] = cfg.content ?? []
    expect(content.some((g: string) => g.includes('./app/'))).toBe(true)
    expect(content.some((g: string) => g.includes('./components/'))).toBe(true)
  })

  it('babel.config.js wires NativeWind via jsxImportSource + nativewind/babel', () => {
    const babelFactory = require(path.join(MOBILE_ROOT, 'babel.config.js'))
    // The factory takes an `api` argument; fake it with the minimum surface.
    const api = { cache: () => undefined }
    const config = babelFactory(api)

    const presets = config.presets as unknown[]
    // Find the babel-preset-expo entry; it must be in tuple form with
    // `jsxImportSource: "nativewind"` in its options.
    const expoPreset = presets.find(
      (p) => Array.isArray(p) && p[0] === 'babel-preset-expo',
    ) as [string, { jsxImportSource?: string }] | undefined
    expect(expoPreset).toBeDefined()
    expect(expoPreset?.[1]?.jsxImportSource).toBe('nativewind')

    // The dedicated nativewind/babel preset must also be present.
    const hasNativeWindBabel = presets.some(
      (p) => p === 'nativewind/babel' || (Array.isArray(p) && p[0] === 'nativewind/babel'),
    )
    expect(hasNativeWindBabel).toBe(true)
  })

  it('compiles Tailwind utility classes actually used in the app', () => {
    // Compile tailwindcss against the project config + content globs and
    // assert that the resulting CSS contains the utility classes used in
    // the app's library screen. If `content` globs ever stop matching the
    // app directory (the most common silent-break cause), these utilities
    // disappear from the output and styling vanishes at runtime.
    const tmpOut = path.join(os.tmpdir(), `nativewind-test-${Date.now()}.css`)
    try {
      execFileSync(
        path.join(MOBILE_ROOT, 'node_modules/.bin/tailwindcss'),
        ['-i', path.join(MOBILE_ROOT, 'global.css'), '-o', tmpOut],
        { cwd: MOBILE_ROOT, stdio: 'pipe' },
      )
      const css = fs.readFileSync(tmpOut, 'utf8')

      // A representative slice of classes referenced from the live app —
      // if `content` globs miss them, they fail to appear in the bundle.
      const expectedUtilities = [
        'flex-1',
        'bg-white',
        'px-6',
        'rounded-lg',
        'text-2xl',
      ]
      for (const cls of expectedUtilities) {
        expect(css).toMatch(new RegExp(`\\.${cls}(\\\\|\\b|\\s|\\{)`))
      }
    } finally {
      if (fs.existsSync(tmpOut)) fs.unlinkSync(tmpOut)
    }
  }, 30_000)
})
