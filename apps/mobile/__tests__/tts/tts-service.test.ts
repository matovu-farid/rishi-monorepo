/**
 * Mobile TTS service tests. We test the `buildTtsService` factory by
 * injecting fake ports (ipc + fetch + auth + makeAudioUri) — the shared
 * TTS service contract is covered by `packages/shared/src/tts/`
 * tests verbatim.
 *
 * Goal: prove the mobile wiring delivers the same behaviour callers
 * already rely on (cache miss → fetch, cache hit → no fetch, prefetch
 * dedup, cancellation, queue status) with the mobile-specific file URI
 * shape replacing electron's blob: URLs.
 */

// Mock the mobile-only modules so this file can run under jest's node env.
jest.mock('expo-file-system', () => ({
  File: class {},
  Directory: class {},
  Paths: { cache: { uri: 'file:///cache' } },
}))

jest.mock('@/lib/auth', () => ({
  getSessionToken: jest.fn().mockResolvedValue('mock-token'),
  WORKER_API_URL: 'https://api.example.com',
}))

jest.mock('@/lib/tts/file-adapter', () => ({
  mobileTtsIpc: makeFakeIpc(),
  makeAudioUriMobile: jest.fn(
    async (_bytes: Uint8Array, ctx: { bookId: string; cfiRange: string }) =>
      `file:///cache/tts-playback/${ctx.bookId}/${ctx.cfiRange}.mp3`,
  ),
}))

import { buildTtsService, _resetTtsServiceForTests } from '@/lib/tts/tts-service'
import type { TtsIpcChannels, AuthHeader } from '@rishi/shared/tts/types'

// ─── Helpers (mirrors shared/src/tts/cache.test.ts makeIpc) ───────────────────
function makeFakeIpc(): TtsIpcChannels {
  const files = new Map<string, Uint8Array>()
  const dirs = new Set<string>()
  return {
    mkdir: jest.fn(async (path: string) => {
      dirs.add(path)
    }),
    exists: jest.fn(async (path: string) => files.has(path) || dirs.has(path)),
    writeFile: jest.fn(async (path: string, data: Uint8Array) => {
      files.set(path, new Uint8Array(data))
    }),
    readFile: jest.fn(async (path: string) => {
      const f = files.get(path)
      if (!f) throw new Error(`ENOENT: ${path}`)
      return f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength) as ArrayBuffer
    }),
    copyFile: jest.fn(async (src: string, dest: string) => {
      const f = files.get(src)
      if (!f) throw new Error(`ENOENT: ${src}`)
      files.set(dest, new Uint8Array(f))
    }),
    removeFile: jest.fn(async (path: string) => {
      files.delete(path)
      dirs.delete(path)
      for (const k of [...files.keys()]) {
        if (k.startsWith(path + '/')) files.delete(k)
      }
    }),
    getDirSize: jest.fn(async (path: string) => {
      let total = 0
      for (const [k, v] of files) {
        if (k === path || k.startsWith(path + '/')) total += v.byteLength
      }
      return total
    }),
    getCacheFileStats: jest.fn(async (dir: string) => {
      const out: Array<{ path: string; size: number; mtimeMs: number }> = []
      let i = 0
      for (const [k, v] of files) {
        if (k.startsWith(dir + '/')) {
          out.push({ path: k, size: v.byteLength, mtimeMs: 1000 + i++ })
        }
      }
      return out
    }),
    getAppDataPath: jest.fn(async () => 'file:///cache'),
  }
}

function makeFetch(audioBytes: Uint8Array, status = 200) {
  const calls: Array<{ url: string; init: RequestInit }> = []
  const fetch = jest.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init })
    return new Response(status === 200 ? (audioBytes as BodyInit) : 'err', {
      status,
      headers: new Headers(),
    })
  })
  return { fetch, calls }
}

function makeAuth(auth: AuthHeader) {
  return jest.fn(async () => auth)
}

const config = {
  audioWorkerUrl: 'https://api.example.com/api/audio/speech',
  cacheMaxBytes: 1024 * 1024,
  maxConcurrent: 4,
}

describe('mobile TTS service — buildTtsService', () => {
  beforeEach(() => {
    _resetTtsServiceForTests()
  })

  it('cache miss → fetch → returns mobile file URI and writes to cache', async () => {
    const ipc = makeFakeIpc()
    const { fetch, calls } = makeFetch(new Uint8Array([1, 2, 3, 4]))
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })

    const uri = await service.requestAudio({
      bookId: 'book-1',
      cfiRange: 'cfi-x',
      text: 'hello',
      priority: 1,
    })

    expect(uri).toMatch(/^file:\/\//)
    expect(uri).toContain('book-1')
    expect(calls).toHaveLength(1)
    // The bearer header must be attached to the upstream POST.
    expect(calls[0].init.headers).toMatchObject({
      Authorization: 'Bearer t',
    })
    // Cache write is fire-and-forget; drain microtasks.
    await new Promise((r) => setTimeout(r, 0))
    expect(ipc.writeFile).toHaveBeenCalled()
  })

  it('cache hit → no HTTP call', async () => {
    const ipc = makeFakeIpc()
    // Pre-populate by saving via the cache module the same way service does.
    const { createCache } = await import('@rishi/shared/tts/cache')
    const cache = createCache({ ipc, cacheMaxBytes: config.cacheMaxBytes })
    await cache.saveAudio('book-1', 'cfi-x', new Uint8Array([9, 9, 9]))

    const { fetch, calls } = makeFetch(new Uint8Array())
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })

    const uri = await service.requestAudio({
      bookId: 'book-1',
      cfiRange: 'cfi-x',
      text: 'hello',
      priority: 0,
    })

    expect(uri).toMatch(/^file:\/\//)
    expect(calls).toHaveLength(0)
  })

  it('emits onAudioReady with the mobile file URI', async () => {
    const ipc = makeFakeIpc()
    const { fetch } = makeFetch(new Uint8Array([1]))
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })
    const handler = jest.fn()
    service.onAudioReady(handler)

    await service.requestAudio({
      bookId: 'b',
      cfiRange: 'c',
      text: 'x',
      priority: 0,
    })

    expect(handler).toHaveBeenCalledTimes(1)
    expect(handler).toHaveBeenCalledWith(
      expect.objectContaining({
        bookId: 'b',
        cfiRange: 'c',
        audioPath: expect.stringMatching(/^file:\/\//),
      }),
    )
  })

  it('queue status returns shape {pending, isProcessing, active}', () => {
    const ipc = makeFakeIpc()
    const { fetch } = makeFetch(new Uint8Array())
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })

    expect(service.getQueueStatus()).toEqual({
      pending: 0,
      isProcessing: false,
      active: 0,
    })
  })

  it('rejects when auth port throws and emits onError', async () => {
    const ipc = makeFakeIpc()
    const { fetch, calls } = makeFetch(new Uint8Array())
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: jest.fn(async () => {
        throw new Error('no session')
      }),
      config,
    })
    const errHandler = jest.fn()
    service.onError(errHandler)

    await expect(
      service.requestAudio({
        bookId: 'b',
        cfiRange: 'c',
        text: 'x',
        priority: 0,
      }),
    ).rejects.toThrow('no session')

    expect(calls).toHaveLength(0)
    expect(errHandler).toHaveBeenCalledWith(
      expect.objectContaining({ bookId: 'b', cfiRange: 'c', error: 'no session' }),
    )
  })

  it('cancelBookRequests interrupts in-flight requests for that book only', async () => {
    const ipc = makeFakeIpc()
    // Block fetch on a never-resolving promise.
    const fetch = jest.fn(() => new Promise<Response>(() => {})) as unknown as (
      url: string,
      init: RequestInit,
    ) => Promise<Response>
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })

    const a = service.requestAudio({
      bookId: 'A',
      cfiRange: 'c1',
      text: 'x',
      priority: 0,
    })
    const b = service.requestAudio({
      bookId: 'B',
      cfiRange: 'c2',
      text: 'y',
      priority: 0,
    })
    await new Promise((r) => setTimeout(r, 0))

    service.cancelBookRequests('A')

    await expect(a).rejects.toThrow('Request cancelled')
    const winner = await Promise.race([
      b.then(() => 'resolved'),
      new Promise<string>((r) => setTimeout(() => r('pending'), 10)),
    ])
    expect(winner).toBe('pending')
  })

  it('clearBookCache removes the book directory', async () => {
    const ipc = makeFakeIpc()
    const { createCache } = await import('@rishi/shared/tts/cache')
    const cache = createCache({ ipc, cacheMaxBytes: config.cacheMaxBytes })
    await cache.saveAudio('book-X', 'cfi-1', new Uint8Array([1]))

    const { fetch } = makeFetch(new Uint8Array())
    const service = buildTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config,
    })
    await service.clearBookCache('book-X')

    // removeFile should have been called on the book directory.
    expect(ipc.removeFile).toHaveBeenCalledWith(expect.stringContaining('/book-X'))
  })
})
