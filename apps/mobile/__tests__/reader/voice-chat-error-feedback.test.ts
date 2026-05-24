/**
 * CHT-016 (#63) — Voice-chat activation failures must surface a
 * non-blocking snackbar in the reader, not silently no-op.
 *
 * Prior to this fix, `useVoiceChat` (the new hook behind the
 * `useRealtimeChat` compatibility shim) exposed `voiceError`,
 * `isMicPermissionError`, `retryStart`, and `dismissError` for consumers
 * to render their own UI, but the EPUB reader screen never read those
 * fields. Mic-denied / network-drop / other activation errors regressed
 * from a modal Alert to a silent no-op — issue #63's user-facing AC
 * was no longer met.
 *
 * Acceptance for this fix (EPUB reader first; PDF/MOBI/DJVU follow in a
 * later card so the diff stays scoped):
 *   1. The reader destructures `voiceError`, `isMicPermissionError`,
 *      `retryStart`, and `dismissError` from `useRealtimeChat`.
 *   2. The reader mounts a snackbar (or banner) that renders when
 *      `voiceError` is truthy.
 *   3. The snackbar wires Retry → `retryStart` for non-permission
 *      errors and Open Settings → `Linking.openSettings` for mic-
 *      permission errors. Dismiss → `dismissError`.
 *   4. The reader imports `Linking` from react-native.
 *
 * We follow the source-grep convention used by sibling tests
 * (`tts-seed-failure-feedback.test.ts`, `selection-tts-failure-feedback.test.ts`).
 * Mounting the EPUB reader is infeasible because of the embedded WebView.
 */
import { readFileSync } from 'fs'
import { join } from 'path'

const APP_ROOT = join(__dirname, '..', '..')

const EPUB_READER_PATH = join(APP_ROOT, 'app', 'reader', '[id].tsx')

function readEpubReader(): string {
  return readFileSync(EPUB_READER_PATH, 'utf-8')
}

describe('CHT-016 (#63) — EPUB reader surfaces voice-chat activation errors', () => {
  const src = readEpubReader()

  it('imports Linking from react-native (for the "Open Settings" CTA)', () => {
    expect(src).toMatch(
      /import\s+\{[^}]*\bLinking\b[^}]*\}\s+from\s+['"]react-native['"]/,
    )
  })

  it('destructures voiceError from useRealtimeChat', () => {
    expect(src).toMatch(
      /const\s*\{[\s\S]*?\bvoiceError\b[\s\S]*?\}\s*=\s*useRealtimeChat\(/,
    )
  })

  it('destructures isMicPermissionError from useRealtimeChat', () => {
    expect(src).toMatch(
      /const\s*\{[\s\S]*?\bisMicPermissionError\b[\s\S]*?\}\s*=\s*useRealtimeChat\(/,
    )
  })

  it('destructures retryStart from useRealtimeChat', () => {
    expect(src).toMatch(
      /const\s*\{[\s\S]*?\bretryStart\b[\s\S]*?\}\s*=\s*useRealtimeChat\(/,
    )
  })

  it('destructures dismissError from useRealtimeChat', () => {
    expect(src).toMatch(
      /const\s*\{[\s\S]*?\bdismissError\b[\s\S]*?\}\s*=\s*useRealtimeChat\(/,
    )
  })

  it('mounts a snackbar / banner that renders when voiceError is truthy', () => {
    // The snackbar (or banner) must be guarded by `voiceError` and have a
    // stable testID so e2e can find it. We accept either a dedicated
    // <VoiceChatErrorSnackbar> component OR a generic conditional render
    // of <UndoSnackbar>/<View> keyed on voiceError, as long as a
    // `voice-error-snackbar` testID surfaces.
    expect(src).toMatch(/voice-error-snackbar/)
    // …and the snackbar element is conditioned on voiceError (not
    // unconditionally mounted).
    expect(src).toMatch(/voiceError\s*(?:&&|\?)/)
  })

  it('wires retryStart for non-permission errors', () => {
    // The Retry path must reference both retryStart and the negation of
    // isMicPermissionError (or the equivalent positive permission branch).
    expect(src).toMatch(/retryStart\b/)
    expect(src).toMatch(/!\s*isMicPermissionError|isMicPermissionError\s*\?/)
  })

  it('wires Linking.openSettings for the mic-permission branch', () => {
    expect(src).toMatch(/Linking\.openSettings\s*\(/)
  })

  it('wires dismissError as the snackbar dismiss handler', () => {
    expect(src).toMatch(/dismissError\b/)
  })
})
