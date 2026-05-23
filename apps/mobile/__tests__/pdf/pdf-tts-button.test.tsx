/**
 * RDR-031 — PDF reader must wire `onTTSPress={handleToggleTTS}` and
 * `ttsButtonActive={ttsActive}` to ReaderShell so the bottom-bar TTS
 * icon renders. MOBI/DJVU/EPUB all wire this; PDF was missing the prop
 * (issue #45).
 *
 * Source-grep pin — established pattern for reader-screen wiring tests
 * (see `pdf-reader-highlight-tap.test.tsx`).
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const SRC_PATH = join(
  __dirname,
  '..',
  '..',
  'app',
  'reader',
  'pdf',
  '[id].tsx',
)
const src = readFileSync(SRC_PATH, 'utf-8')

describe('RDR-031 — PDF reader TTS button', () => {
  it('defines handleToggleTTS as a useCallback', () => {
    expect(src).toMatch(/handleToggleTTS\s*=\s*useCallback\(/)
  })

  it('handleToggleTTS stops playback when ttsActive is true', () => {
    // STOP branch must dispatch into playerStore (parity with EPUB / MOBI).
    expect(src).toMatch(
      /handleToggleTTS\s*=\s*useCallback\([\s\S]{0,600}ttsActive[\s\S]{0,200}STOP/,
    )
  })

  it('handleToggleTTS gates start through requireTTS', () => {
    expect(src).toMatch(
      /handleToggleTTS\s*=\s*useCallback\([\s\S]{0,800}requireTTS\(/,
    )
  })

  it('handleToggleTTS seeds paragraphs from chunks and dispatches PLAY', () => {
    // The post-seed branch grew when STA-017 (#93) added a non-blocking
    // toast + a11y announcement for the "no chunks" path before the PLAY
    // dispatch. Window widened from 400 → 1200 to accommodate the
    // user-feedback affordance.
    expect(src).toMatch(
      /handleToggleTTS\s*=\s*useCallback\([\s\S]{0,1200}seedPlayerParagraphsFromChunks\([\s\S]{0,1200}PLAY/,
    )
  })

  it('passes onTTSPress and ttsButtonActive to ReaderShell', () => {
    expect(src).toMatch(/onTTSPress=\{handleToggleTTS\}/)
    expect(src).toMatch(/ttsButtonActive=\{ttsActive\}/)
  })
})
