/**
 * P1-F — AnnotationPopover color swatches are 20×20pt. Apple HIG requires
 * a 44×44pt minimum touch target. Pre-fix: no hitSlop, no padding. Tapping
 * the swatch edge frequently missed.
 *
 * Post-fix: each swatch TouchableOpacity carries `hitSlop={12}` (12pt on
 * all sides → 20 + 24 = 44pt effective target).
 *
 * Source-grep is the established pattern for reader-screen wiring tests in
 * this suite (see `reader-tap-region.test.ts`). We avoid mounting the
 * full popover because it pulls in the entire reader stack.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'components', 'AnnotationPopover.tsx'),
  'utf-8',
)

/**
 * Isolate the JSX block that maps over HIGHLIGHT_COLORS and renders the
 * 20pt swatches. Matching from `HIGHLIGHT_COLORS.map` to the closing
 * `</TouchableOpacity>` lets us grep within just the swatch element.
 */
function extractSwatchBlock(src: string): string {
  // Find the `.map((c) => (` opening, then capture until the matching
  // self-closing `/>` so we only inspect the swatch TouchableOpacity.
  const match = src.match(
    /HIGHLIGHT_COLORS\.map\(\(c\)\s*=>\s*\(([\s\S]*?\/>)\s*\)\)/,
  )
  if (!match) {
    throw new Error(
      'HIGHLIGHT_COLORS.map block not found in AnnotationPopover.tsx — has it been renamed?',
    )
  }
  return match[1]
}

describe('P1-F — AnnotationPopover color swatches meet 44pt touch target', () => {
  const block = extractSwatchBlock(SRC)

  it('each swatch TouchableOpacity carries hitSlop={12}', () => {
    expect(block).toMatch(/hitSlop=\{12\}/)
  })

  it('keeps the 20pt visual size (hitSlop is what bumps the target, not layout)', () => {
    expect(block).toMatch(/width:\s*20/)
    expect(block).toMatch(/height:\s*20/)
  })
})
