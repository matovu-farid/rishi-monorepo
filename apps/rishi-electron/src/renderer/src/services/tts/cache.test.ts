import { describe, it, expect, vi } from 'vitest'
import type { TtsIpcChannels } from './types'
import { createCache } from './cache'

/**
 * Build a fake TtsIpcChannels backed by an in-memory file map.
 * Exposes spy access via vi.fn() so tests can assert on call sequence.
 */
export function makeIpc(initial: Record<string, Uint8Array> = {}): {
  ipc: TtsIpcChannels
  files: Map<string, Uint8Array>
} {
  const files = new Map<string, Uint8Array>(Object.entries(initial))
  const dirs = new Set<string>()
  const ipc: TtsIpcChannels = {
    mkdir: vi.fn(async (path) => {
      dirs.add(path)
    }),
    exists: vi.fn(async (path) => files.has(path) || dirs.has(path)),
    writeFile: vi.fn(async (path, data) => {
      files.set(path, new Uint8Array(data))
    }),
    readFile: vi.fn(async (path) => {
      const f = files.get(path)
      if (!f) throw new Error(`ENOENT: ${path}`)
      return f.buffer.slice(f.byteOffset, f.byteOffset + f.byteLength) as ArrayBuffer
    }),
    copyFile: vi.fn(async (src, dest) => {
      const f = files.get(src)
      if (!f) throw new Error(`ENOENT: ${src}`)
      files.set(dest, new Uint8Array(f))
    }),
    removeFile: vi.fn(async (path) => {
      files.delete(path)
      dirs.delete(path)
      // recursive rm: also drop any keys under this prefix
      for (const k of [...files.keys()]) {
        if (k.startsWith(path + '/')) files.delete(k)
      }
    }),
    getDirSize: vi.fn(async (path) => {
      let total = 0
      for (const [k, v] of files) {
        if (k === path || k.startsWith(path + '/')) total += v.byteLength
      }
      return total
    }),
    getCacheFileStats: vi.fn(async (dir) => {
      const out: Array<{ path: string; size: number; mtimeMs: number }> = []
      let i = 0
      for (const [k, v] of files) {
        if (k.startsWith(dir + '/')) {
          out.push({ path: k, size: v.byteLength, mtimeMs: 1000 + i++ })
        }
      }
      return out
    }),
    getAppDataPath: vi.fn(async () => '/userData')
  }
  return { ipc, files }
}

describe('cache.audioPath', () => {
  it('resolves to `<appData>/tts-cache/<bookId>/<md5(cfiRange)>.mp3` and creates the book dir on first use', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })

    const path = await cache.audioPath('book-1', 'epubcfi(/6/4!/4/2,/1:0,/1:10)')

    // md5('epubcfi(/6/4!/4/2,/1:0,/1:10)') — we don't pin the literal hash; just structure.
    expect(path).toMatch(/^\/userData\/tts-cache\/book-1\/[a-f0-9]{32}\.mp3$/)
    expect(ipc.mkdir).toHaveBeenCalledWith('/userData/tts-cache')
    expect(ipc.mkdir).toHaveBeenCalledWith('/userData/tts-cache/book-1')
  })
})

describe('cache.saveAudio', () => {
  it('writes the bytes under the CFI key and copies to the text-hash key', async () => {
    const { ipc, files } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })
    const bytes = new Uint8Array([1, 2, 3, 4])

    const path = await cache.saveAudio('book-1', 'cfi-x', bytes, 'hello world')

    expect(path).toMatch(/\.mp3$/)
    expect(ipc.writeFile).toHaveBeenCalledTimes(1)
    // copyFile to text-hash mirror
    expect(ipc.copyFile).toHaveBeenCalledTimes(1)
    // Both keys present in the in-memory FS
    expect([...files.keys()].filter((k) => k.endsWith('.mp3'))).toHaveLength(2)
  })

  it('rejects empty audio buffers without writing', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })

    await expect(cache.saveAudio('book-1', 'cfi-x', new Uint8Array(0))).rejects.toThrow(
      'Audio blob is zero bytes'
    )
    expect(ipc.writeFile).not.toHaveBeenCalled()
  })

  it('does not duplicate the text-hash copy when cfiRange already starts with texthash:', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })
    const bytes = new Uint8Array([1, 2, 3])

    await cache.saveAudio('book-1', 'texthash:abc', bytes, 'hello')

    expect(ipc.writeFile).toHaveBeenCalledTimes(1)
    expect(ipc.copyFile).not.toHaveBeenCalled()
  })
})
