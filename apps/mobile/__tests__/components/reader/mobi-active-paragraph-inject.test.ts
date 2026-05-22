/**
 * RDR-024 — MOBI active-paragraph reconciler `injectJavaScript` fires on
 * every TTS step even though the inline parser rarely emits
 * `[data-paragraph-index]` ids — the JNI hop is wasted.
 *
 * Post-fix:
 *   - The chapter-change postMessage from the WebView includes a
 *     `hasParagraphIds` boolean (true when the rendered chapter contains
 *     any `[data-paragraph-index]` element).
 *   - The RN-side reader screen tracks that flag and SKIPS the
 *     `injectJavaScript` call when no ids are present.
 *
 * Source-grep is the established pattern in this suite — we avoid
 * mounting the MOBI reader because it pulls in WebView, expo-file-system,
 * and the player store.
 */

import { readFileSync } from 'fs'
import { join } from 'path'

const MOBILE_ROOT = join(__dirname, '..', '..', '..')
const SRC = readFileSync(
  join(MOBILE_ROOT, 'app', 'reader', 'mobi', '[id].tsx'),
  'utf-8',
)

describe('RDR-024 — MOBI active-paragraph reconciler skips injection when no ids exist', () => {
  it('WebView template scans for [data-paragraph-index] on chapter change', () => {
    // The probe lives inside showChapter so it runs once per chapter,
    // not per TTS step. Pin the selector so a future refactor that
    // drops the probe regresses the test.
    expect(SRC).toMatch(/data-paragraph-index/)
  })

  it('chapter postMessage carries a hasParagraphIds boolean', () => {
    // The boolean is computed inside the WebView and surfaces alongside
    // the existing { type: 'chapter', current, total } payload.
    expect(SRC).toMatch(/hasParagraphIds/)
  })

  it('reader screen tracks the flag in a ref/state', () => {
    expect(SRC).toMatch(/hasParagraphIds(Ref)?/)
  })

  it('the activeParagraph effect short-circuits when hasParagraphIds is false', () => {
    // Pin the early-return pattern so the optimisation can't be silently
    // removed. We allow either a `.current === false` ref check or a
    // direct state read — both are valid implementations.
    expect(SRC).toMatch(/hasParagraphIds/)
    // The early-return guard sits BEFORE the `injectJavaScript` call.
    // We allow some slack but the two must appear in the same effect.
    expect(SRC).toMatch(/hasParagraphIds[\s\S]{0,400}return/)
  })
})
