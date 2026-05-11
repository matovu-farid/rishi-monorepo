import { describe, it, expect, vi } from 'vitest'
import { createTtsService } from './service'
import type { AuthHeader, TtsConfig } from './types'
import { makeIpc } from './cache.test'

/**
 * Build a fake fetch that returns the given audio bytes on success. Tracks
 * call count and the most recent request init for header / body assertions.
 */
export function makeFetch(opts: {
  audioBytes?: Uint8Array
  status?: number
  errorBody?: string
  retryAfter?: string
}) {
  const status = opts.status ?? 200
  const bytes = opts.audioBytes ?? new Uint8Array([0xff, 0xfb, 0x90])
  const calls: Array<{ url: string; init: RequestInit }> = []
  const fetch = vi.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init })
    const headers = new Headers()
    if (opts.retryAfter) headers.set('Retry-After', opts.retryAfter)
    return new Response(status === 200 ? bytes : opts.errorBody ?? '', { status, headers })
  })
  return { fetch, calls, callCount: () => calls.length }
}

export const makeAuth = (auth: AuthHeader): (() => Promise<AuthHeader>) =>
  vi.fn(async () => auth)

export const baseConfig: TtsConfig = {
  audioWorkerUrl: 'https://api.example.com/audio/speech',
  cacheMaxBytes: 500 * 1024 * 1024,
  maxConcurrent: 8
}

describe('TtsService.requestAudio', () => {
  it('cache miss → fetch → returns blob URL and writes to cache', async () => {
    const { ipc } = makeIpc()
    const { fetch, callCount } = makeFetch({ audioBytes: new Uint8Array([1, 2, 3, 4]) })
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 'tok' }),
      config: baseConfig
    })

    const url = await service.requestAudio({
      bookId: 'book-1',
      cfiRange: 'cfi-x',
      text: 'hello',
      priority: 1
    })

    expect(url).toMatch(/^blob:/)
    expect(callCount()).toBe(1)
    // Cache write is fire-and-forget (`void deps.cache.saveAudio(...)`); let
    // microtasks drain so the writeFile mock has been invoked before asserting.
    await new Promise((r) => setTimeout(r, 0))
    expect(ipc.writeFile).toHaveBeenCalled() // cache write
  })
})
