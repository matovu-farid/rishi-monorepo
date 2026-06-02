import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { createActor } from 'xstate'
import { syncActor } from '../syncActor'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

describe('syncActor (producer)', () => {
  it('coalesces PDF reader.position events within 100ms', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'producer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'BROADCAST',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 1,
        position: { format: 'pdf', page: 3, offsetY: 0, ts: 1 }
      }
    })
    actor.send({
      type: 'BROADCAST',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 2,
        position: { format: 'pdf', page: 3, offsetY: 120, ts: 2 }
      }
    })
    vi.advanceTimersByTime(100)
    const out = events.filter((e) => e.type === 'OUTGOING_SYNC')
    expect(out).toHaveLength(1)
    if (out[0].msg.t === 'reader.position' && out[0].msg.position.format === 'pdf') {
      expect(out[0].msg.position.offsetY).toBe(120)
    } else {
      throw new Error('expected pdf reader.position')
    }
  })

  it('coalesces EPUB reader.position events within 100ms', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'producer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'BROADCAST',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 1,
        position: { format: 'epub', cfi: 'cfi/a', ts: 1 }
      }
    })
    actor.send({
      type: 'BROADCAST',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 2,
        position: { format: 'epub', cfi: 'cfi/b', ts: 2 }
      }
    })
    vi.advanceTimersByTime(100)
    const out = events.filter((e) => e.type === 'OUTGOING_SYNC')
    expect(out).toHaveLength(1)
    if (out[0].msg.t === 'reader.position' && out[0].msg.position.format === 'epub') {
      expect(out[0].msg.position.cfi).toBe('cfi/b')
    } else {
      throw new Error('expected epub reader.position')
    }
  })

  it('emits annotation events immediately (no coalesce)', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'producer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'BROADCAST',
      msg: { v: 1, t: 'annotation.add', id: 'a1', range: {}, color: 'y', ts: 1 }
    })
    expect(events.filter((e) => e.type === 'OUTGOING_SYNC')).toHaveLength(1)
  })
})

describe('syncActor (consumer)', () => {
  it('drops reader.position with ts <= lastAppliedTs (per type)', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'consumer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 10,
        position: { format: 'pdf', page: 1, offsetY: 0, ts: 10 }
      }
    })
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 5,
        position: { format: 'pdf', page: 1, offsetY: 0, ts: 5 }
      }
    })
    expect(events.filter((e) => e.type === 'APPLY_TO_READER')).toHaveLength(1)
  })

  it('applies tts.state independent of reader.position ts', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'consumer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: {
        v: 1,
        t: 'reader.position',
        bookId: 'b',
        ts: 100,
        position: { format: 'pdf', page: 1, offsetY: 0, ts: 100 }
      }
    })
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: {
        v: 1,
        t: 'tts.state',
        isPlaying: true,
        position: { sentenceIdx: 0, charOffset: 0 },
        voiceId: 'v',
        rate: 1,
        ts: 50
      }
    })
    expect(events.filter((e) => e.type === 'TTS_SYNC')).toHaveLength(1)
  })

  it('is idempotent on annotation.add by id', () => {
    const events: any[] = []
    const actor = createActor(syncActor, { input: { mode: 'consumer' } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: { v: 1, t: 'annotation.add', id: 'a1', range: {}, color: 'y', ts: 1 }
    })
    actor.send({
      type: 'SYNC_RECEIVED',
      msg: { v: 1, t: 'annotation.add', id: 'a1', range: {}, color: 'y', ts: 2 }
    })
    expect(events.filter((e) => e.type === 'APPLY_TO_READER')).toHaveLength(1)
  })
})
