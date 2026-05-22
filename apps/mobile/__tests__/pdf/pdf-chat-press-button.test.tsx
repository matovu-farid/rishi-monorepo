/**
 * RDR-032 — PDF reader must pass `onChatPress` (gated through
 * `requireAIChat`) to ReaderShell so the dedicated chat-press button
 * renders. `onChatToggle` was already wired but `onChatPress` was
 * missing — issue #46 (DJVU stays open for another slot).
 *
 * Mirrors the EPUB wiring (apps/mobile/app/reader/[id].tsx:709):
 *   onChatPress={() => requireAIChat(() => router.push(`/chat/${book.id}`))}
 *
 * The voice-chat `onRealtimePress` piece of #46 is covered by the
 * sibling `pdf-realtime-button.test.tsx` (RDR-035 / #49 also touches
 * it). This test focuses on the chat-press lane.
 *
 * Source-grep pin — established pattern for reader-screen wiring tests.
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

describe('RDR-032 — PDF reader chat-press button', () => {
  it('passes onChatPress to ReaderShell gated through requireAIChat', () => {
    // Match the EPUB pattern verbatim — the chat-press button shares
    // the same destination route as onChatToggle, but is a separate
    // explicit button (the toolbar-pulse chat shortcut).
    expect(src).toMatch(/onChatPress=\{/)
    expect(src).toMatch(
      /onChatPress=\{\s*\(\)\s*=>\s*requireAIChat\(\s*\(\)\s*=>\s*router\.push\(`\/chat\/\$\{book\.id\}`\)/,
    )
  })

  it('keeps onChatToggle wired in parallel (regression guard for the existing button)', () => {
    expect(src).toMatch(/onChatToggle=\{/)
  })
})
