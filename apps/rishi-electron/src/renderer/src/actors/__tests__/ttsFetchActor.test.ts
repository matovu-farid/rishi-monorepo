// apps/electron/src/renderer/src/actors/__tests__/ttsFetchActor.test.ts
//
// Unit tests for the fetchTtsLogic fromPromise actor. The actor is a thin
// boundary around the injected `fetcher`; the test surface is:
//   - skip=true → resolves to { kind: 'skip' } after a 2s wait
//   - skip=false → calls fetcher with priority 1, resolves to { kind: 'play', src }
//   - fetcher rejecting propagates as actor onError

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { createActor } from 'xstate'
import { fetchTtsLogic, type TtsFetchInput } from '../ttsFetchActor'

function makeInput(overrides: Partial<TtsFetchInput> = {}): TtsFetchInput {
  return {
    bookId: 'book-1',
    cfiRange: 'cfi-1',
    text: 'hello',
    skip: false,
    fetcher: vi.fn(async () => 'blob:default'),
    ...overrides
  }
}

describe('fetchTtsLogic', () => {
  it("calls fetcher with priority 1 and resolves to { kind: 'play', src }", async () => {
    const fetcher = vi.fn(async () => 'blob:abc')
    const actor = createActor(fetchTtsLogic, { input: makeInput({ fetcher }) })
    const done = new Promise<unknown>((resolve) => {
      actor.subscribe({ complete: () => resolve(actor.getSnapshot().output) })
    })
    actor.start()
    expect(await done).toEqual({ kind: 'play', src: 'blob:abc' })
    expect(fetcher).toHaveBeenCalledWith({
      bookId: 'book-1',
      cfiRange: 'cfi-1',
      text: 'hello',
      priority: 1
    })
  })

  describe('skip path', () => {
    beforeEach(() => {
      vi.useFakeTimers()
    })
    afterEach(() => {
      vi.useRealTimers()
    })

    it("resolves to { kind: 'skip' } after a 2s pause, without calling the fetcher", async () => {
      const fetcher = vi.fn()
      const actor = createActor(fetchTtsLogic, { input: makeInput({ skip: true, fetcher }) })
      let output: unknown
      actor.subscribe({
        complete: () => {
          output = actor.getSnapshot().output
        }
      })
      actor.start()
      expect(output).toBeUndefined()
      await vi.advanceTimersByTimeAsync(2000)
      expect(output).toEqual({ kind: 'skip' })
      expect(fetcher).not.toHaveBeenCalled()
    })
  })

  it('surfaces fetcher rejections as actor error', async () => {
    const fetcher = vi.fn(async () => {
      throw new Error('fetch failed')
    })
    const actor = createActor(fetchTtsLogic, { input: makeInput({ fetcher }) })
    const failed = new Promise<unknown>((resolve) => {
      actor.subscribe({ error: (e) => resolve(e) })
    })
    actor.start()
    await expect(failed).resolves.toMatchObject({ message: 'fetch failed' })
  })
})
