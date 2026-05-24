/**
 * STA-027 (#100) — Reader load failure on cold-start must NOT strand the user.
 *
 * Acceptance:
 *   Each of the four reader screens (EPUB, PDF, MOBI, DJVU), when the
 *   initial book-load fails (either because `getBookForReading` throws or
 *   resolves to null/no filePath), must render `<ReaderErrorScreen />` with
 *   `onBack` routed through `safeBack(router)` so that a cold-start deep
 *   link with an empty navigation stack lands the user on `/(tabs)`
 *   instead of a dead screen.
 *
 * We follow the source-grep convention used by
 *   `__tests__/components/reader/reader-error-screen-wiring.test.ts`
 * and `reader-back-safebackguard.test.ts` because mounting the screens
 * directly is infeasible (WebView, RAG, every zustand store, four
 * platform parsers).
 */
import { readFileSync } from 'fs'
import { join } from 'path'

const APP_ROOT = join(__dirname, '..', '..')

const READER_FILES: Array<{ label: string; relpath: string[] }> = [
  { label: 'EPUB', relpath: ['app', 'reader', '[id].tsx'] },
  { label: 'PDF', relpath: ['app', 'reader', 'pdf', '[id].tsx'] },
  { label: 'MOBI', relpath: ['app', 'reader', 'mobi', '[id].tsx'] },
  { label: 'DJVU', relpath: ['app', 'reader', 'djvu', '[id].tsx'] },
]

function read(reader: (typeof READER_FILES)[number]): string {
  return readFileSync(join(APP_ROOT, ...reader.relpath), 'utf-8')
}

describe('STA-027 — cold-start reader-load failure recovery affordance', () => {
  for (const reader of READER_FILES) {
    it(`${reader.label}: <ReaderErrorScreen ... onBack=safeBack(router) ...> wires Back through safeBack`, () => {
      const src = read(reader)
      // The Back handler passed to ReaderErrorScreen must go through safeBack.
      // We allow both inline arrow shape and a hoisted handler; the test
      // is satisfied if any onBack prop on a ReaderErrorScreen tag flows
      // through `safeBack(`.
      const tagMatch = src.match(
        /<ReaderErrorScreen[\s\S]{0,500}onBack=\{[^}]*safeBack\(\s*router[^}]*\}/,
      )
      expect(tagMatch).not.toBeNull()
    })

    it(`${reader.label}: <ReaderErrorScreen ... onRetry=...> rewinds the loader (Retry path)`, () => {
      const src = read(reader)
      // Retry must bump some attempt counter (loadAttempt / setLoadAttempt).
      // The existing pattern is `setLoadAttempt((n) => n + 1)`.
      const tagMatch = src.match(
        /<ReaderErrorScreen[\s\S]{0,500}onRetry=\{[^}]*setLoadAttempt[^}]*\}/,
      )
      expect(tagMatch).not.toBeNull()
    })

    it(`${reader.label}: loader effect depends on loadAttempt so Retry actually re-fires`, () => {
      const src = read(reader)
      // The useEffect for loading must include `loadAttempt` in its dep
      // array — otherwise tapping Retry bumps the counter to no effect.
      expect(src).toMatch(/\[\s*id\s*,\s*loadAttempt\s*\]/)
    })

    it(`${reader.label}: thrown load → falls through to ReaderErrorScreen instead of an infinite spinner`, () => {
      const src = read(reader)
      // The post-load gate must short-circuit the spinner: when book is
      // null we render <ReaderErrorScreen />, not the ActivityIndicator.
      // Locked in by checking that the !book branch returns <ReaderErrorScreen>.
      const branch = src.match(
        /if\s*\(\s*!book[\s\S]{0,400}return[\s\S]{0,400}<ReaderErrorScreen/,
      )
      expect(branch).not.toBeNull()
    })
  }
})

/**
 * Behavioral cross-check — confirm that safeBack on an empty stack
 * replaces to `/(tabs)`. We exercise the helper directly so we lock in
 * the contract the four call sites depend on.
 */
describe('STA-027 — safeBack lands the user on /(tabs) when the stack is empty', () => {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { safeBack } = require('@/lib/navigation') as typeof import('@/lib/navigation')

  it('empty stack → router.replace("/(tabs)")', () => {
    const router = {
      canGoBack: jest.fn(() => false),
      back: jest.fn(),
      replace: jest.fn(),
    }
    safeBack(router)
    expect(router.replace).toHaveBeenCalledWith('/(tabs)')
    expect(router.back).not.toHaveBeenCalled()
  })

  it('non-empty stack → router.back()', () => {
    const router = {
      canGoBack: jest.fn(() => true),
      back: jest.fn(),
      replace: jest.fn(),
    }
    safeBack(router)
    expect(router.back).toHaveBeenCalledTimes(1)
    expect(router.replace).not.toHaveBeenCalled()
  })
})
