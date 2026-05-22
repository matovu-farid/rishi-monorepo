/**
 * Critic-sweep batch (mobile/annotation) — P1 fixes against
 * `apps/mobile/components/AnnotationPopover.tsx`.
 *
 * Source-grep mirrors the established pattern in this suite
 * (`reader-tap-region.test.ts`, `pdf-selection-swatch-hitslop.test.ts`).
 * Mounting the popover would drag the entire reader stack, so we lint
 * the source itself.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'components', 'AnnotationPopover.tsx'),
  'utf-8',
)

describe('AnnotationPopover — critic-sweep polish', () => {
  describe('#84 VIS-024 — delete uses colors.accent.error token', () => {
    it('does not hardcode the Tailwind red hex anywhere', () => {
      expect(SRC).not.toMatch(/#DC2626/i)
    })

    it('reads accent.error from the theme tokens for the delete button', () => {
      // Delete <Text> color must reference colors.accent.error.
      // Allow either `colors.accent.error` (useTheme) or theme.accent.error.
      expect(SRC).toMatch(/accent\.error/)
    })

    it('imports useTheme to source the semantic token', () => {
      expect(SRC).toMatch(/from\s+['"]@\/lib\/theme['"]/)
      expect(SRC).toMatch(/useTheme/)
    })
  })
})
