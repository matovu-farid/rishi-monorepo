/**
 * T-P2.5 — CONTEXT-001: shared `softCapPageText` helper.
 *
 * Source: `.parity-v2/SPEC.md` §3.8 — the helper lives at
 * `packages/shared/src/voice-chat/pageTextCap.ts`.
 *
 * Contract per spec:
 *   - Soft-cap text at a maximum character length (default 8000).
 *   - When over the cap, trim at the last paragraph break (`\n\n`) before
 *     the limit; if no paragraph break exists, trim at the last sentence
 *     boundary (`.`) before the limit; otherwise hard-cut at the cap.
 *   - When truncated, append the literal suffix `\n[text truncated]`.
 *   - When input is at or below the cap, return it unchanged (no suffix).
 *   - Empty input → empty string (no throw, no suffix).
 *   - Trim happens at a word boundary — no mid-word cut.
 *
 * This test imports the helper from `@rishi/shared/voice-chat/pageTextCap`.
 * That module is created as part of the GREEN phase; until then this file
 * fails at import time, which is the intended RED state.
 */
import { softCapPageText } from '@rishi/shared/voice-chat/pageTextCap'

describe('softCapPageText (CONTEXT-001)', () => {
  it('returns input unchanged when length is below the cap', () => {
    const input = 'A short paragraph well under the limit.'
    expect(softCapPageText(input, 8000)).toBe(input)
  })

  it('returns input unchanged when length is exactly at the cap', () => {
    const input = 'a'.repeat(100)
    expect(softCapPageText(input, 100)).toBe(input)
  })

  it('returns the empty string when input is empty (no throw, no suffix)', () => {
    expect(softCapPageText('', 8000)).toBe('')
  })

  it('appends the [text truncated] suffix when the input exceeds the cap', () => {
    const longInput = 'word '.repeat(2500) // ~12,500 chars
    const out = softCapPageText(longInput, 8000)
    expect(out.length).toBeLessThanOrEqual(8000 + '\n[text truncated]'.length)
    expect(out.endsWith('[text truncated]')).toBe(true)
  })

  it('does not cut a word in half — output never ends mid-word', () => {
    const longInput = 'antidisestablishmentarianism '.repeat(400) // long, repeating
    const out = softCapPageText(longInput, 4000)
    // Strip the suffix and check the last char before it is whitespace,
    // punctuation, or end-of-word (alpha → non-alpha).
    const body = out.replace(/\n\[text truncated\]$/, '')
    // The body must not end in mid-word: the char immediately following the
    // body in the ORIGINAL input must be a non-word boundary.
    const nextCharInSource = longInput.charAt(body.length)
    if (nextCharInSource && /\w/.test(nextCharInSource)) {
      // If the next source char is a word char, then the body ended INSIDE
      // a word — fail.
      expect(/\w$/.test(body)).toBe(false)
    }
  })

  it('prefers paragraph break (\\n\\n) as the cut boundary when available before the cap', () => {
    const para1 = 'First paragraph with enough text to matter.'
    const para2 = 'B'.repeat(8000) // pushes total over the cap
    const input = `${para1}\n\n${para2}`
    const out = softCapPageText(input, 100)
    // The cut should happen at the paragraph boundary — i.e. the body
    // ends with the first paragraph's last char (no part of para2).
    const body = out.replace(/\n\[text truncated\]$/, '')
    expect(body).toBe(para1)
  })

  it('falls back to the last sentence boundary (.) before the cap when no paragraph break fits', () => {
    const input =
      'The first sentence ends here. The second sentence is much much longer and definitely overruns whatever cap we set so that the truncation must land somewhere inside it.'
    const out = softCapPageText(input, 60)
    const body = out.replace(/\n\[text truncated\]$/, '')
    expect(body.endsWith('.')).toBe(true)
    expect(body).toBe('The first sentence ends here.')
  })
})
