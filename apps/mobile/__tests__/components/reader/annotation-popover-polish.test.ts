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

  describe('#87 VIS-027 — swatch sits in 44pt hit target without overlap', () => {
    /**
     * Pull the swatch JSX block (the HIGHLIGHT_COLORS.map body) — this
     * is the wrapper Touchable + child circle View. Wrapper sizing lives
     * in `styles.swatchWrapper` (hoisted to StyleSheet) so we also lift
     * out that StyleSheet entry and assert against it.
     */
    function extractSwatchBlock(src: string): string {
      const fallback = src.match(/HIGHLIGHT_COLORS\.map\(\(c\)\s*=>\s*\(([\s\S]*?)\)\)/)
      if (!fallback) {
        throw new Error('HIGHLIGHT_COLORS.map block not found')
      }
      return fallback[1]
    }

    function extractStyleEntry(src: string, key: string): string {
      // Capture `<key>: { ... }` from the StyleSheet.create object.
      const re = new RegExp(`${key}:\\s*\\{([\\s\\S]*?)\\}`)
      const m = src.match(re)
      if (!m) {
        throw new Error(`styles.${key} not found — was it renamed?`)
      }
      return m[1]
    }

    const block = extractSwatchBlock(SRC)

    it('swatch wrapper TouchableOpacity references a hoisted style entry (styles.swatchWrapper)', () => {
      expect(block).toMatch(/style=\{styles\.swatchWrapper\}/)
    })

    it('styles.swatchWrapper sizes the wrapper at 44pt × 44pt (Apple HIG minimum)', () => {
      const entry = extractStyleEntry(SRC, 'swatchWrapper')
      expect(entry).toMatch(/width:\s*44/)
      expect(entry).toMatch(/height:\s*44/)
    })

    it('styles.swatchWrapper centers the inner circle', () => {
      const entry = extractStyleEntry(SRC, 'swatchWrapper')
      expect(entry).toMatch(/justifyContent:\s*['"]center['"]/)
      expect(entry).toMatch(/alignItems:\s*['"]center['"]/)
    })

    it('drops hitSlop on the swatch wrapper — layout provides the hit zone, not slop overlap', () => {
      // Only flag a JSX-prop usage (`hitSlop={...}`) so source-code
      // comments that mention the word in passing don't trigger.
      expect(block).not.toMatch(/hitSlop\s*=/)
    })

    it('keeps the visual circle at 20pt with borderRadius 10', () => {
      // The visual circle should still render at 20×20 (with borderRadius 10).
      expect(block).toMatch(/width:\s*20/)
      expect(block).toMatch(/height:\s*20/)
      expect(block).toMatch(/borderRadius:\s*10/)
    })
  })
})
