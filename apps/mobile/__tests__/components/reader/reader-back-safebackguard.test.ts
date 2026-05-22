/**
 * P1-B — Deep-link cold-start into a reader or chat detail strands the
 * user because the Back handler calls `router.back()` unguarded. When the
 * stack is empty (cold-start from a notification, a Spotlight result, or
 * a fresh app launch into a `/reader/<id>` URL), `back()` no-ops and the
 * user is stuck on the reader UI.
 *
 * The four reader screens and the chat detail screen must funnel Back
 * presses through the shared `safeBack(router)` helper (which calls
 * `router.replace('/(tabs)')` when `router.canGoBack()` is false).
 *
 * The reader error screen (commit 37d773ed) already had the right pattern
 * inline — once `safeBack` exists, that call site funnels through it too.
 *
 * Mounting these screens directly is infeasible (WebView, RAG, all four
 * platform parsers, every zustand store). We follow the source-grep
 * convention established by `reader-error-screen-wiring.test.ts`.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const APP_ROOT = join(__dirname, '..', '..', '..')

const CALL_SITES: Array<{ label: string; relpath: string[] }> = [
  { label: 'EPUB reader', relpath: ['app', 'reader', '[id].tsx'] },
  { label: 'PDF reader', relpath: ['app', 'reader', 'pdf', '[id].tsx'] },
  { label: 'MOBI reader', relpath: ['app', 'reader', 'mobi', '[id].tsx'] },
  { label: 'DJVU reader', relpath: ['app', 'reader', 'djvu', '[id].tsx'] },
  { label: 'Chat detail', relpath: ['app', 'chat', '[bookId].tsx'] },
]

function read(site: (typeof CALL_SITES)[number]): string {
  return readFileSync(join(APP_ROOT, ...site.relpath), 'utf-8')
}

describe('P1-B — deep-link cold-start Back is guarded via safeBack', () => {
  for (const site of CALL_SITES) {
    it(`${site.label}: imports safeBack from @/lib/navigation`, () => {
      const src = read(site)
      expect(src).toMatch(
        /import\s+\{[^}]*safeBack[^}]*\}\s+from\s+['"]@\/lib\/navigation['"]/,
      )
    })

    it(`${site.label}: routes Back through safeBack(router) (no unguarded router.back() call sites)`, () => {
      const src = read(site)
      // Strip line comments so the regex only inspects executable code.
      // (Documentation may legitimately mention `router.back()` as part
      // of the explanation for why safeBack exists.)
      const codeOnly = src
        .split('\n')
        .map((line) => line.replace(/\/\/.*$/, ''))
        .join('\n')
      expect(codeOnly).not.toMatch(/(?<!safe)\brouter\.back\(\)/)
      // At least one safeBack call site must exist.
      expect(src).toMatch(/safeBack\(\s*router/)
    })
  }
})

/**
 * Behavioral spec — when the helper is invoked from any of the five
 * screens with an empty navigation stack, it must replace to the tabs
 * root rather than no-op. We exercise the helper directly here so that
 * the contract is locked in regardless of how the call sites are wired
 * (TouchableOpacity, useCallback, inline onPress, etc.).
 */
describe('P1-B — safeBack lands the user on /(tabs) when the stack is empty', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { safeBack } = require('@/lib/navigation') as typeof import('@/lib/navigation')

  for (const site of CALL_SITES) {
    it(`${site.label}: empty stack → router.replace('/(tabs)')`, () => {
      const router = {
        canGoBack: jest.fn(() => false),
        back: jest.fn(),
        replace: jest.fn(),
      }
      safeBack(router)
      expect(router.replace).toHaveBeenCalledWith('/(tabs)')
      expect(router.back).not.toHaveBeenCalled()
    })
  }
})
