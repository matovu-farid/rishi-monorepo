/**
 * P1-G — PDF reader selection-bar action buttons (Read / Cancel / Note /
 * Delete / Close) share `styles.selectionAction`, which pre-fix set
 * `minHeight: 32` (8 short of Apple HIG's 44pt minimum). Post-fix bumps
 * both `minHeight` and `minWidth` to 44 so every action button — and any
 * future button reusing the style — meets the touch-target floor.
 *
 * Source-grep is the established pattern for reader-screen wiring tests
 * (see `reader-tap-region.test.ts`).
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', 'pdf', '[id].tsx'),
  'utf-8',
)

/**
 * Pull just the `selectionAction` style declaration so we don't get
 * tripped up by other `minHeight:` literals elsewhere in the file.
 */
function extractSelectionActionStyle(src: string): string {
  const match = src.match(/selectionAction:\s*\{([^}]*)\}/)
  if (!match) {
    throw new Error(
      '`selectionAction` style not found in app/reader/pdf/[id].tsx — has it been renamed?',
    )
  }
  return match[1]
}

describe('P1-G — PDF selection-bar action buttons meet 44pt minimum', () => {
  const block = extractSelectionActionStyle(SRC)

  it('selectionAction.minHeight is 44', () => {
    expect(block).toMatch(/minHeight:\s*44/)
  })

  it('selectionAction.minWidth is 44', () => {
    expect(block).toMatch(/minWidth:\s*44/)
  })

  it('legacy 32pt minHeight is gone', () => {
    expect(block).not.toMatch(/minHeight:\s*32/)
  })
})
