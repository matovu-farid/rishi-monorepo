/**
 * RDR-020 — TocSheet renders a flat list with no visual indication of TOC
 * depth or sub-items. Apple Books / electron render a hierarchical
 * outline with depth-based indentation and a disclosure chevron next to
 * any parent.
 *
 * Post-fix:
 *   - The component flattens `subitems` into a depth-tagged row list
 *     (the same pattern as the PDF reader's `OutlineList`).
 *   - Each row's left padding scales by `16 + depth * 16` so children
 *     visually nest under their parents.
 *   - Parent rows (rows with subitems) carry a chevron icon.
 *
 * Source-grep follows the established pattern in this suite — we avoid
 * mounting `BottomSheetFlatList` because it requires the gorhom modal
 * provider tree.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'components', 'TocSheet.tsx'),
  'utf-8',
)

describe('RDR-020 — TocSheet renders hierarchical TOC with depth-aware padding', () => {
  it('flattens the TOC into a depth-tagged row list', () => {
    // The flattener carries `depth` alongside the original `TocItem`.
    expect(SRC).toMatch(/depth/)
  })

  it('row padding scales with depth (16 + depth * 16)', () => {
    // Pin the formula so a future refactor that drops the indentation
    // visibly regresses the test.
    expect(SRC).toMatch(/depth\s*\*\s*16/)
  })

  it('parent rows render a disclosure chevron', () => {
    // The chevron may be rendered via IconSymbol or a Unicode glyph; we
    // pin the chevron name so the component must surface a parent marker.
    expect(SRC).toMatch(/chevron/i)
  })
})
