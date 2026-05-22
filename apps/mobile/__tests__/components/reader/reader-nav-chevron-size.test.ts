/**
 * P1-H — Reader nav chevrons did not meet Apple HIG's 44pt minimum.
 *
 *   - PDF  `styles.pdfNavBtn`: 36 × 36
 *   - MOBI `styles.navBtn`   : 36 × 36
 *   - DJVU `styles.navBtn`   : 32 × 32 (zoom in/out + page prev/next)
 *
 * Post-fix: each becomes 44 × 44. The DJVU cluster also packs zoom and
 * page chevrons through the same `navBtn` style, so bumping the style
 * covers every disabled-state hit-target as well.
 *
 * Source-grep pattern mirrors `reader-tap-region.test.ts`.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')

function readReader(format: 'pdf' | 'mobi' | 'djvu'): string {
  return readFileSync(
    join(MOBILE_ROOT, 'app', 'reader', format, '[id].tsx'),
    'utf-8',
  )
}

/**
 * Pull the named style declaration body (everything inside the first `{}`
 * after `<name>:`). Single-style isolation prevents collisions with other
 * `width:` / `height:` literals in the same file.
 */
function extractStyle(src: string, name: string): string {
  const re = new RegExp(`${name}:\\s*\\{([^}]*)\\}`)
  const match = src.match(re)
  if (!match) {
    throw new Error(`style \`${name}\` not found — has it been renamed?`)
  }
  return match[1]
}

describe('P1-H — Reader nav chevrons are 44 × 44', () => {
  describe('PDF reader pdfNavBtn', () => {
    const block = extractStyle(readReader('pdf'), 'pdfNavBtn')

    it('width is 44', () => {
      expect(block).toMatch(/width:\s*44/)
    })
    it('height is 44', () => {
      expect(block).toMatch(/height:\s*44/)
    })
    it('legacy 36pt is gone', () => {
      expect(block).not.toMatch(/(?:width|height):\s*36/)
    })
  })

  describe('MOBI reader navBtn', () => {
    const block = extractStyle(readReader('mobi'), 'navBtn')

    it('width is 44', () => {
      expect(block).toMatch(/width:\s*44/)
    })
    it('height is 44', () => {
      expect(block).toMatch(/height:\s*44/)
    })
    it('legacy 36pt is gone', () => {
      expect(block).not.toMatch(/(?:width|height):\s*36/)
    })
  })

  describe('DJVU reader navBtn', () => {
    const block = extractStyle(readReader('djvu'), 'navBtn')

    it('width is 44', () => {
      expect(block).toMatch(/width:\s*44/)
    })
    it('height is 44', () => {
      expect(block).toMatch(/height:\s*44/)
    })
    it('legacy 32pt is gone', () => {
      expect(block).not.toMatch(/(?:width|height):\s*32/)
    })
  })
})
