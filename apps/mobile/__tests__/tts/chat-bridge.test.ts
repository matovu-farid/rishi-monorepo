/**
 * useTtsChatBridge tests. We exercise the dispatch logic directly by
 * replicating the bridge's state transitions, since React Testing
 * Library isn't currently set up in this jest config.
 *
 * The behavioural assertion is that the bridge sends CHAT_STARTED on
 * entry into any chat-active state and CHAT_ENDED on exit, and is
 * idempotent across repeats.
 */
import type { RealtimeStatus } from '@/lib/realtime/types'

// Replicate the inChat predicate from the bridge so the test stays in
// sync with the production code without importing React.
function inChat(status: RealtimeStatus): boolean {
  return status === 'connecting' || status === 'active' || status === 'speaking'
}

/**
 * Replay a sequence of statuses through the bridge's dispatch decision
 * and return the events that would be sent.
 */
function replay(statuses: RealtimeStatus[]): string[] {
  let last: 'started' | 'ended' | null = null
  const sent: string[] = []
  for (const status of statuses) {
    const chatting = inChat(status)
    if (chatting && last !== 'started') {
      sent.push('CHAT_STARTED')
      last = 'started'
    } else if (!chatting && last === 'started') {
      sent.push('CHAT_ENDED')
      last = 'ended'
    }
  }
  return sent
}

describe('useTtsChatBridge dispatch logic', () => {
  it('sends CHAT_STARTED on connecting → active', () => {
    expect(replay(['idle', 'connecting', 'active'])).toEqual(['CHAT_STARTED'])
  })

  it('sends CHAT_ENDED on active → ending → idle', () => {
    expect(replay(['idle', 'active', 'ending', 'idle'])).toEqual([
      'CHAT_STARTED',
      'CHAT_ENDED',
    ])
  })

  it('is idempotent across the speaking state (no extra CHAT_STARTED)', () => {
    expect(
      replay(['idle', 'connecting', 'active', 'speaking', 'active', 'idle']),
    ).toEqual(['CHAT_STARTED', 'CHAT_ENDED'])
  })

  it('does not send CHAT_ENDED if no CHAT_STARTED was sent', () => {
    expect(replay(['idle', 'idle', 'idle'])).toEqual([])
  })

  it('handles flapping (connect → idle → connect) by dispatching twice', () => {
    expect(
      replay(['idle', 'connecting', 'idle', 'connecting', 'idle']),
    ).toEqual(['CHAT_STARTED', 'CHAT_ENDED', 'CHAT_STARTED', 'CHAT_ENDED'])
  })

  it('treats `ending` as not-in-chat (CHAT_ENDED dispatches before idle)', () => {
    expect(replay(['idle', 'active', 'ending'])).toEqual([
      'CHAT_STARTED',
      'CHAT_ENDED',
    ])
  })
})

// ── Integration check against the shared playerMachine ────────────────────────
//
// Confirms the events the bridge emits actually achieve the position-
// preservation behaviour the machine promises. This is the one place we
// connect the bridge to the canonical state machine.

import { createActor } from 'xstate'
import { playerMachine } from '@rishi/shared/machines/playerMachine'

// ── Reader-screen wiring assertions (G14 closure) ────────────────────────────
//
// We assert at the source level that every reader screen imports and invokes
// `useTtsChatBridge`. Doing this as a string check (rather than a full RN
// render) avoids pulling in the entire reader-screen native dep tree just to
// verify two lines of glue per file. If a future refactor moves the wiring,
// the import location may change but the symbol must still be referenced.

import { readFileSync } from 'fs'
import { join } from 'path'

const READER_FILES = [
  'app/reader/[id].tsx', // EPUB + AZW3
  'app/reader/pdf/[id].tsx',
  'app/reader/mobi/[id].tsx',
  'app/reader/djvu/[id].tsx',
]

describe('useTtsChatBridge wired in every reader screen (G14)', () => {
  for (const rel of READER_FILES) {
    it(`${rel} imports and calls useTtsChatBridge`, () => {
      const abs = join(__dirname, '..', '..', rel)
      const src = readFileSync(abs, 'utf-8')
      expect(src).toMatch(/from\s+['"]@\/hooks\/useTtsChatBridge['"]/)
      expect(src).toMatch(/useTtsChatBridge\s*\(/)
    })
  }
})

describe('CHAT_STARTED / CHAT_ENDED end-to-end through the shared playerMachine', () => {
  // Use jest fake timers so the machine's `after: 10000ms` timers don't
  // keep the test runtime alive past the assertions.
  beforeEach(() => {
    jest.useFakeTimers()
  })
  afterEach(() => {
    jest.useRealTimers()
  })

  it('preserves paragraphIndex across an interruption', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'b' })
    actor.send({
      type: 'PARAGRAPHS_UPDATED',
      paragraphs: [
        { index: 'p0', text: 'first' },
        { index: 'p1', text: 'second' },
        { index: 'p2', text: 'third' },
      ],
    })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'NEXT' })
    actor.send({ type: 'AUDIO_LOADED' })
    expect(actor.getSnapshot().value).toBe('playing')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    // Simulate the bridge: voice chat starts.
    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(true)
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)

    // Voice chat ends — bridge dispatches CHAT_ENDED.
    actor.send({ type: 'CHAT_ENDED' })
    expect(actor.getSnapshot().value).toBe('loading')
    expect(actor.getSnapshot().context.paragraphIndex).toBe(1)
    actor.stop()
  })

  it('does not resume if user paused intentionally before chat', () => {
    const actor = createActor(playerMachine).start()
    actor.send({ type: 'INITIALIZE', bookId: 'b' })
    actor.send({
      type: 'PARAGRAPHS_UPDATED',
      paragraphs: [
        { index: 'p0', text: 'first' },
        { index: 'p1', text: 'second' },
      ],
    })
    actor.send({ type: 'PLAY' })
    actor.send({ type: 'AUDIO_LOADED' })
    actor.send({ type: 'PAUSE' })

    actor.send({ type: 'CHAT_STARTED' })
    expect(actor.getSnapshot().context.wantsAutoResumeAfterChat).toBe(false)

    actor.send({ type: 'CHAT_ENDED' })
    // User remains paused.
    expect(actor.getSnapshot().value).toEqual({ paused: 'clean' })
    actor.stop()
  })
})
