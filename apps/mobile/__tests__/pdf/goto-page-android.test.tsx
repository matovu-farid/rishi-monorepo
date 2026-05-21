/**
 * G09 — PDF go-to-page Android modal.
 *
 * iOS uses `Alert.prompt` (a native text-input alert RN provides only on
 * iOS). On Android we render a small RN Modal with a TextInput. This
 * test covers the modal's behaviour at a logical level — the
 * `validateGoToPageInput` helper that the modal's "Go" button calls.
 */

import { validateGoToPageInput } from '@/components/pdf/goto-page-validate'

describe('validateGoToPageInput', () => {
  it('accepts a positive integer within range', () => {
    expect(validateGoToPageInput('5', 1, 100)).toBe(5)
  })

  it('accepts the lower bound', () => {
    expect(validateGoToPageInput('1', 1, 100)).toBe(1)
  })

  it('accepts the upper bound', () => {
    expect(validateGoToPageInput('100', 1, 100)).toBe(100)
  })

  it('rejects values below the lower bound', () => {
    expect(validateGoToPageInput('0', 1, 100)).toBeNull()
    expect(validateGoToPageInput('-1', 1, 100)).toBeNull()
  })

  it('rejects values above the upper bound', () => {
    expect(validateGoToPageInput('101', 1, 100)).toBeNull()
  })

  it('rejects non-numeric input', () => {
    expect(validateGoToPageInput('abc', 1, 100)).toBeNull()
    expect(validateGoToPageInput('', 1, 100)).toBeNull()
    expect(validateGoToPageInput('   ', 1, 100)).toBeNull()
  })

  it('rejects decimals', () => {
    expect(validateGoToPageInput('5.5', 1, 100)).toBeNull()
  })

  it('trims whitespace before parsing', () => {
    expect(validateGoToPageInput('  42  ', 1, 100)).toBe(42)
  })

  it('rejects negative input even with mixed signs', () => {
    expect(validateGoToPageInput('-5', 1, 100)).toBeNull()
  })
})

// ── Reader-screen wiring assertion ──────────────────────────────────────────
//
// The PDF reader must use the new modal on Android (not the placeholder
// alert from Batch 5). We verify at the source level that the Android
// branch references the modal component.

import { readFileSync } from 'fs'
import { join } from 'path'

describe('PDF reader uses the Android modal (G09)', () => {
  it('app/reader/pdf/[id].tsx imports GoToPageModal and routes Android there', () => {
    const abs = join(__dirname, '..', '..', 'app', 'reader', 'pdf', '[id].tsx')
    const src = readFileSync(abs, 'utf-8')
    expect(src).toMatch(/from\s+['"]@\/components\/pdf\/GoToPageModal['"]/)
    expect(src).toMatch(/<GoToPageModal/)
  })
})
