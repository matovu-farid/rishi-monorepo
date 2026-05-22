/**
 * RDR-016 — Toolbar centerSlot must not be positioned absolute.
 *
 * Pre-fix: `centerSlot: { position: 'absolute', left: 0, right: 0 }` overlaps
 * the right cluster. Long titles or progress pills render behind the
 * right-side icons because they share the same z-stack with no flex
 * constraint.
 *
 * Post-fix: center is a flex: 1 child between the side slots; sides keep
 * their natural width and the center cluster shrinks instead of clipping
 * behind them.
 *
 * Source-grep follows the established reader-screen wiring pattern
 * (see `reader-tap-region.test.ts`, `reader-sheets-wiring.test.ts`).
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'components', 'ui', 'Toolbar.tsx'),
  'utf-8',
)

/**
 * Pull out the `centerSlot:` entry from the StyleSheet.create block so we
 * can assert against just that style object.
 */
function extractCenterSlotStyle(src: string): string {
  const match = src.match(/centerSlot:\s*\{([\s\S]*?)\},?\s*\}\s*\)/)
  if (!match) {
    throw new Error(
      'centerSlot style entry not found in Toolbar.tsx — has it been renamed?',
    )
  }
  return match[1]
}

describe('RDR-016 — Toolbar centerSlot uses flex layout, not absolute positioning', () => {
  const block = extractCenterSlotStyle(SRC)

  it('centerSlot does NOT use position: "absolute"', () => {
    expect(block).not.toMatch(/position:\s*['"]absolute['"]/)
  })

  it('centerSlot grows to fill remaining space (flex: 1)', () => {
    expect(block).toMatch(/flex:\s*1/)
  })

  it('does not pin centerSlot via left: 0 / right: 0', () => {
    expect(block).not.toMatch(/left:\s*0/)
    expect(block).not.toMatch(/right:\s*0/)
  })
})
