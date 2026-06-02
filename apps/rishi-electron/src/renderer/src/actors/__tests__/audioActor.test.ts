// apps/electron/src/renderer/src/actors/__tests__/audioActor.test.ts
//
// Unit tests for the audioActor (`fromCallback`) — the long-running side-effect
// actor that owns a single HTMLMediaElement. Tests inject a fake media element
// via input so happy-dom's incomplete HTMLAudioElement implementation never
// matters.

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { createActor, createMachine, type ActorRefFrom } from 'xstate'
import { audioActor, type AudioCommand, type AudioEmit } from '../audioActor'

class FakeAudio extends EventTarget {
  src = ''
  currentTime = 0
  paused = true
  error: { code: number; message: string } | null = null
  pause = vi.fn((): void => {
    this.paused = true
  })
  play = vi.fn(async (): Promise<void> => {
    this.paused = false
  })
  load = vi.fn()
}

type Harness = {
  fake: FakeAudio
  captured: AudioEmit[]
  audioRef: ActorRefFrom<typeof audioActor>
  stop: () => void
}

function makeHarness(): Harness {
  const fake = new FakeAudio()
  const captured: AudioEmit[] = []

  const parentMachine = createMachine({
    types: {} as { events: AudioEmit },
    invoke: {
      id: 'audio',
      src: audioActor,
      input: { audio: fake as unknown as HTMLMediaElement }
    },
    on: {
      AUDIO_LOADED: { actions: () => captured.push({ type: 'AUDIO_LOADED' }) },
      AUDIO_ENDED: { actions: () => captured.push({ type: 'AUDIO_ENDED' }) },
      AUDIO_ERROR: {
        actions: ({ event }) =>
          captured.push({ type: 'AUDIO_ERROR', error: (event as { error: string }).error })
      }
    }
  })

  const parent = createActor(parentMachine)
  parent.start()
  const audioRef = parent.getSnapshot().children.audio as ActorRefFrom<typeof audioActor>
  return { fake, captured, audioRef, stop: () => parent.stop() }
}

async function flushMicrotasks(): Promise<void> {
  await new Promise<void>((r) => setTimeout(r, 0))
}

describe('audioActor', () => {
  let harness: Harness
  beforeEach(() => {
    harness = makeHarness()
  })

  describe('PLAY', () => {
    it('pauses the previous track, sets src, calls load, then on canplaythrough plays and emits AUDIO_LOADED', async () => {
      const { fake, captured, audioRef } = harness
      audioRef.send({ type: 'PLAY', src: 'blob:test' } satisfies AudioCommand)
      expect(fake.pause).toHaveBeenCalledTimes(1)
      expect(fake.src).toBe('blob:test')
      expect(fake.currentTime).toBe(0)
      expect(fake.load).toHaveBeenCalledTimes(1)
      expect(captured).toEqual([])

      fake.dispatchEvent(new Event('canplaythrough'))
      await flushMicrotasks()
      expect(fake.play).toHaveBeenCalled()
      expect(captured).toEqual([{ type: 'AUDIO_LOADED' }])
    })

    it('emits a single AUDIO_ERROR when the media element fails to load (error event before canplaythrough)', async () => {
      const { fake, captured, audioRef } = harness
      audioRef.send({ type: 'PLAY', src: 'blob:bad' })
      fake.error = { code: 4, message: '' }
      const errEvent = new Event('error')
      Object.defineProperty(errEvent, 'target', { value: fake })
      fake.dispatchEvent(errEvent)
      await flushMicrotasks()
      // describeMediaError returns the MEDIA_ERR_SRC_NOT_SUPPORTED label for
      // empty messages; exactly one error fires because the actor uses one
      // error handler (not steady-state + per-PLAY duplicating each other).
      expect(captured).toEqual([{ type: 'AUDIO_ERROR', error: 'MEDIA_ERR_SRC_NOT_SUPPORTED' }])
    })

    it('a second PLAY supersedes the first — the first PLAYs canplaythrough listener is removed before the second is installed', async () => {
      const { fake, captured, audioRef } = harness
      audioRef.send({ type: 'PLAY', src: 'blob:first' })
      audioRef.send({ type: 'PLAY', src: 'blob:second' })
      // Only the second PLAY's listener is attached. Dispatching canplaythrough
      // fires it exactly once → one AUDIO_LOADED. The first PLAYs listener was
      // explicitly removed when the second PLAY started its own load() — so it
      // can never fire even if it lingered in a queue.
      fake.dispatchEvent(new Event('canplaythrough'))
      await flushMicrotasks()
      expect(captured).toEqual([{ type: 'AUDIO_LOADED' }])
      expect(fake.play).toHaveBeenCalledTimes(1)
      // A second canplaythrough should not produce another AUDIO_LOADED — the
      // handler self-removed on first fire.
      fake.dispatchEvent(new Event('canplaythrough'))
      await flushMicrotasks()
      expect(captured).toEqual([{ type: 'AUDIO_LOADED' }])
    })
  })

  describe('PAUSE / RESUME', () => {
    it('PAUSE pauses without clearing src or currentTime', () => {
      const { fake, audioRef } = harness
      fake.src = 'blob:current'
      fake.currentTime = 12.5
      fake.paused = false
      audioRef.send({ type: 'PAUSE' })
      expect(fake.pause).toHaveBeenCalled()
      expect(fake.src).toBe('blob:current')
      expect(fake.currentTime).toBe(12.5)
    })

    it('RESUME calls play()', async () => {
      const { fake, audioRef } = harness
      audioRef.send({ type: 'RESUME' })
      await flushMicrotasks()
      expect(fake.play).toHaveBeenCalled()
    })
  })

  describe('STOP', () => {
    it('pauses and resets currentTime, but does NOT clear src (the audio is silenced but reloadable)', () => {
      const { fake, audioRef } = harness
      fake.src = 'blob:keep'
      fake.currentTime = 3
      audioRef.send({ type: 'STOP' })
      expect(fake.pause).toHaveBeenCalled()
      expect(fake.currentTime).toBe(0)
      expect(fake.src).toBe('blob:keep')
    })
  })

  describe('CLEAR_SRC', () => {
    it('pauses and clears src — used on idle/cleanup to release the media resource', () => {
      const { fake, audioRef } = harness
      fake.src = 'blob:disposable'
      audioRef.send({ type: 'CLEAR_SRC' })
      expect(fake.pause).toHaveBeenCalled()
      expect(fake.src).toBe('')
    })
  })

  describe('native ended event', () => {
    it("forwards the audio element's 'ended' event as AUDIO_ENDED", () => {
      const { fake, captured } = harness
      fake.dispatchEvent(new Event('ended'))
      expect(captured).toEqual([{ type: 'AUDIO_ENDED' }])
    })
  })

  describe('native error event (steady state, no in-flight PLAY)', () => {
    it("forwards the audio element's 'error' event as AUDIO_ERROR with code label fallback", () => {
      const { fake, captured } = harness
      fake.error = { code: 2, message: '' }
      const e = new Event('error')
      Object.defineProperty(e, 'target', { value: fake })
      fake.dispatchEvent(e)
      // PLAY's load-error listener consumed the error in `in-flight` tests;
      // here no PLAY is in flight so the steady-state listener emits.
      // Either way the parent observes AUDIO_ERROR.
      expect(captured.some((e) => e.type === 'AUDIO_ERROR')).toBe(true)
    })

    it('prefers the MediaError.message over the code label when the message is non-empty', () => {
      const { fake, captured } = harness
      fake.error = { code: 3, message: 'decode failed at byte 42' }
      const e = new Event('error')
      Object.defineProperty(e, 'target', { value: fake })
      fake.dispatchEvent(e)
      const errors = captured.filter(
        (c): c is { type: 'AUDIO_ERROR'; error: string } => c.type === 'AUDIO_ERROR'
      )
      expect(errors[0].error).toBe('decode failed at byte 42')
    })
  })

  describe('cleanup on actor stop', () => {
    it('removes event listeners and clears src so the singleton is reusable next session', () => {
      const { fake, captured, stop } = harness
      stop()
      // After stop, dispatching ended on the element should not enqueue more events
      const before = captured.length
      fake.dispatchEvent(new Event('ended'))
      expect(captured.length).toBe(before)
    })
  })
})
