import { describe, it, expect, vi } from 'vitest'
import { createQueue } from './queue'

/** Build a fake transport that resolves with the given bytes after N rejects. */
export function makeTransport(opts: {
  bytes?: Uint8Array
  failNTimes?: number
  reject?: Error
}) {
  const bytes = opts.bytes ?? new Uint8Array([0xff, 0xfb, 0x90])
  let calls = 0
  let failsLeft = opts.failNTimes ?? 0
  const fetchAudio = vi.fn(async (): Promise<ArrayBuffer> => {
    calls++
    if (opts.reject) throw opts.reject
    if (failsLeft > 0) {
      failsLeft--
      throw new Error('transient')
    }
    return bytes.buffer.slice(
      bytes.byteOffset,
      bytes.byteOffset + bytes.byteLength
    ) as ArrayBuffer
  })
  return { fetchAudio, callCount: () => calls }
}

/** Build a fake cache that always misses, captures saves in-memory. */
export function makeCacheStub() {
  const saves: Array<{ bookId: string; cfiRange: string; bytes: Uint8Array }> = []
  return {
    audioPath: vi.fn(async (b: string, c: string) => `/cache/${b}/${c}.mp3`),
    getAudio: vi.fn(async () => null),
    saveAudio: vi.fn(async (bookId: string, cfiRange: string, bytes: Uint8Array) => {
      saves.push({ bookId, cfiRange, bytes })
      return `/cache/${bookId}/${cfiRange}.mp3`
    }),
    clearBook: vi.fn(async () => {}),
    evictIfNeeded: vi.fn(async () => {}),
    saves
  }
}

describe('queue.enqueue', () => {
  it('fetches audio when cache misses and resolves with bytes', async () => {
    const transport = makeTransport({ bytes: new Uint8Array([1, 2, 3]) })
    const cache = makeCacheStub()
    const queue = createQueue({
      cache,
      fetchAudio: transport.fetchAudio,
      maxConcurrent: 8,
      maxRetries: 3,
      backoffBaseMs: 1
    })

    const bytes = await queue.enqueue({
      bookId: 'book-1',
      cfiRange: 'cfi-x',
      text: 'hello',
      priority: 1
    })

    expect(new Uint8Array(bytes)).toEqual(new Uint8Array([1, 2, 3]))
    expect(transport.callCount()).toBe(1)
    expect(cache.saveAudio).toHaveBeenCalledTimes(1)
  })
})
