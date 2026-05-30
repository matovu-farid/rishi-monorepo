import { describe, expect, it, vi } from 'vitest'
import { createActor } from 'xstate'
import { micActor } from '../micActor'

function makeFakeMedia() {
  const track = { enabled: true, stop: vi.fn(), kind: 'audio' } as unknown as MediaStreamTrack
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] } as unknown as MediaStream
  const getUserMedia = vi.fn(async () => stream)
  return { track, stream, getUserMedia }
}

describe('micActor', () => {
  it('emits LOCAL_TRACK_READY after getUserMedia resolves', async () => {
    const fake = makeFakeMedia()
    const events: any[] = []
    const actor = createActor(micActor, {
      input: { getUserMedia: fake.getUserMedia }
    })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    const ready = events.find((e) => e.type === 'LOCAL_TRACK_READY')
    expect(ready).toBeTruthy()
    expect(ready.track).toBe(fake.track)
  })

  it('disables track on self mute', async () => {
    const fake = makeFakeMedia()
    const actor = createActor(micActor, { input: { getUserMedia: fake.getUserMedia } })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({ type: 'SET_MUTED', muted: true, source: 'self' })
    expect(fake.track.enabled).toBe(false)
  })

  it('host mute blocks self unmute', async () => {
    const fake = makeFakeMedia()
    const actor = createActor(micActor, { input: { getUserMedia: fake.getUserMedia } })
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    actor.send({ type: 'SET_MUTED', muted: true, source: 'host' })
    actor.send({ type: 'SET_MUTED', muted: false, source: 'self' })
    expect(fake.track.enabled).toBe(false)
  })

  it('emits MIC_DENIED if getUserMedia rejects with NotAllowedError', async () => {
    const events: any[] = []
    const getUserMedia = vi.fn(async () => {
      const err: Error & { name?: string } = new Error('denied')
      err.name = 'NotAllowedError'
      throw err
    })
    const actor = createActor(micActor, { input: { getUserMedia } })
    actor.on('*', (e) => events.push(e))
    actor.start()
    await new Promise((r) => setTimeout(r, 0))
    expect(events.find((e) => e.type === 'MIC_DENIED')).toBeTruthy()
  })
})
