/**
 * P1-I — PDF reader selection-bar and picker-bar color swatches are 22pt
 * with no hitSlop. Apple HIG requires 44pt minimum touch targets.
 *
 * Both the new-selection bar (HIGHLIGHT_COLORS.map then handleAddHighlight)
 * and the existing-highlight picker (HIGHLIGHT_COLORS.map then
 * handleChangeHighlightColor) reuse styles.swatch. Both must declare
 * `hitSlop={{ top: 11, bottom: 11, left: 11, right: 11 }}` so 22 + 22
 * equals a 44pt effective target.
 *
 * Source-grep pattern mirrors reader-tap-region.test.ts.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', 'pdf', '[id].tsx'),
  'utf-8',
)

/**
 * Pull every JSX block where the file maps HIGHLIGHT_COLORS to a swatch
 * TouchableOpacity. There are two (selection-bar + picker-bar); both
 * must carry the hitSlop.
 */
function extractSwatchBlocks(src: string): string[] {
  const re = /HIGHLIGHT_COLORS\.map\(\(c\)\s*=>\s*\(([\s\S]*?\/>)\s*\)\)/g
  const blocks: string[] = []
  let m: RegExpExecArray | null
  while ((m = re.exec(src)) !== null) {
    blocks.push(m[1])
  }
  if (blocks.length === 0) {
    throw new Error(
      'HIGHLIGHT_COLORS.map blocks not found in app/reader/pdf/[id].tsx — has the file changed?',
    )
  }
  return blocks
}

describe('P1-I — PDF selection-bar swatches meet 44pt touch target', () => {
  const blocks = extractSwatchBlocks(SRC)

  it('finds both swatch map blocks (selection bar + picker bar)', () => {
    expect(blocks.length).toBeGreaterThanOrEqual(2)
  })

  it.each(blocks.map((_, i) => [i]))(
    'swatch block #%i carries hitSlop with 11pt on all sides',
    (i) => {
      const block = blocks[i]
      // Require all four sides → 11pt each. Order-independent.
      expect(block).toMatch(/hitSlop=\{\{[\s\S]*\}\}/)
      expect(block).toMatch(/top:\s*11/)
      expect(block).toMatch(/bottom:\s*11/)
      expect(block).toMatch(/left:\s*11/)
      expect(block).toMatch(/right:\s*11/)
    },
  )
})
