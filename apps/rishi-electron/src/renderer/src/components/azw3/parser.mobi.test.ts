import { describe, it, expect } from 'vitest'
import fs from 'node:fs'
import { parseAzw3 } from './parser'

// Foliate-js's MOBI.open auto-detects KF8 (.azw3) vs MOBI6 (.mobi) inside
// the same MOBI class, so parseAzw3 works for both formats. The reader routes
// `book.kind === 'mobi' | 'azw3'` through Azw3View — this test pins down that
// pipeline for the legacy MOBI format too.
describe('parseAzw3 against a MOBI6 fixture', () => {
  it('parses a plain MOBI file and returns at least one loadable section', async () => {
    const bytes = fs.readFileSync('e2e/fixtures/test-book.mobi').buffer.slice(0)
    const { sections } = await parseAzw3(bytes as ArrayBuffer)
    expect(sections.length).toBeGreaterThan(0)
    expect(typeof sections[0].load).toBe('function')
  })
})
