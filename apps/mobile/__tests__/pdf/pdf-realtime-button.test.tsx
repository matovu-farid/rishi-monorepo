/**
 * RDR-035 — PDF reader must pass `onRealtimePress` and `realtimeStatus`
 * to ReaderShell so the voice-chat (realtime) button renders. The
 * `useRealtimeChat` hook is already mounted, but the toggle was never
 * wired through — issue #49 (P0).
 *
 * Mirrors the EPUB pattern (apps/mobile/app/reader/[id].tsx:704-708):
 *   onRealtimePress={() => {
 *     if (realtimeActive) toggleRealtime()
 *     else requireVoiceChat(toggleRealtime)
 *   }}
 *   realtimeStatus={realtimeStatus}
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

describe('RDR-035 — PDF reader voice-chat wiring', () => {
  it('destructures toggle and isActive from useRealtimeChat', () => {
    // The hook returns { status, toggle, isActive, showGuardrailWarning }.
    // PDF previously read only `status`; now it must read `toggle` and
    // `isActive` so the realtime button can call them.
    expect(src).toMatch(
      /useRealtimeChat\(book\?\.id\s*\?\?\s*['"]['"]\)|useRealtimeChat\(book\.id\)/,
    )
    expect(src).toMatch(/toggle:\s*toggleRealtime/)
    expect(src).toMatch(/isActive:\s*realtimeActive/)
  })

  it('imports useRequireAuth with the voice-chat scope', () => {
    // requireVoiceChat is the auth gate around toggleRealtime.
    expect(src).toMatch(/requireVoiceChat\s*=\s*useRequireAuth\(['"]voice-chat['"]\)/)
  })

  it('passes onRealtimePress to ReaderShell', () => {
    // The wiring must call toggleRealtime directly when realtimeActive,
    // and gate through requireVoiceChat otherwise — parity with EPUB.
    expect(src).toMatch(/onRealtimePress=\{/)
    expect(src).toMatch(
      /onRealtimePress=\{\s*\(\)\s*=>\s*\{?[\s\S]{0,200}realtimeActive[\s\S]{0,80}toggleRealtime\(\)[\s\S]{0,200}requireVoiceChat\(toggleRealtime\)/,
    )
  })

  it('passes realtimeStatus to ReaderShell', () => {
    expect(src).toMatch(/realtimeStatus=\{realtimeStatus\}/)
  })
})
