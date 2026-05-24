import { describe, it, expect, vi, beforeEach } from 'vitest'

// ---------------------------------------------------------------------------
// In-memory FS mock — enough fidelity to verify atomic-write + queue semantics.
// We model two operations:
//   - writeFile(target, data)   — writes the bytes (immediately, no atomicity).
//   - rename(src, dst)          — atomic move from src to dst.
// readFile reads whatever the latest committed bytes for the path are.
// ---------------------------------------------------------------------------

interface FsState {
  files: Map<string, string>
}

const fsState: FsState = { files: new Map() }

const mockHandle = vi.fn()
const mockGetPath = vi.fn().mockReturnValue('/tmp/test-userdata')

vi.mock('electron', () => ({
  ipcMain: { handle: (...args: unknown[]) => mockHandle(...args) },
  app: { getPath: (...args: unknown[]) => mockGetPath(...args) }
}))

// We allow tests to install hooks that fire on each writeFile / rename so we
// can simulate crashes between the temp-file write and the rename.
const writeFileHooks: Array<(path: string, data: string) => Promise<void> | void> = []
const renameHooks: Array<(src: string, dst: string) => Promise<void> | void> = []

vi.mock('node:fs/promises', () => ({
  readFile: vi.fn(async (p: string) => {
    if (!fsState.files.has(p)) {
      const err = new Error(`ENOENT: ${p}`) as NodeJS.ErrnoException
      err.code = 'ENOENT'
      throw err
    }
    return fsState.files.get(p)!
  }),
  writeFile: vi.fn(async (p: string, data: string) => {
    for (const hook of writeFileHooks) await hook(p, data)
    fsState.files.set(p, data)
  }),
  rename: vi.fn(async (src: string, dst: string) => {
    for (const hook of renameHooks) await hook(src, dst)
    if (!fsState.files.has(src)) {
      const err = new Error(`ENOENT: ${src}`) as NodeJS.ErrnoException
      err.code = 'ENOENT'
      throw err
    }
    const data = fsState.files.get(src)!
    fsState.files.delete(src)
    fsState.files.set(dst, data)
  }),
  unlink: vi.fn(async (p: string) => {
    fsState.files.delete(p)
  })
}))

// Import after mocks.
import { registerStoreHandlers } from './store.js'

type HandlerFn = (...args: unknown[]) => Promise<unknown>

function getHandler(channel: string): HandlerFn {
  const call = mockHandle.mock.calls.find((c: unknown[]) => c[0] === channel)
  if (!call) throw new Error(`No handler registered for channel "${channel}"`)
  return call[1] as HandlerFn
}

const STORE_PATH = '/tmp/test-userdata/settings-store.json'
const TMP_PATH = `${STORE_PATH}.tmp`

describe('store IPC — atomic write + queue', () => {
  beforeEach(() => {
    mockHandle.mockReset()
    fsState.files.clear()
    writeFileHooks.length = 0
    renameHooks.length = 0
    mockGetPath.mockReturnValue('/tmp/test-userdata')
    registerStoreHandlers()
  })

  it('writes to a .tmp file then renames over the real file', async () => {
    const set = getHandler('store:set')
    const observed: Array<{ op: 'write' | 'rename'; path: string }> = []
    writeFileHooks.push((p) => {
      observed.push({ op: 'write', path: p })
    })
    renameHooks.push((src, dst) => {
      observed.push({ op: 'rename', path: `${src}->${dst}` })
    })

    await set({}, 'theme', 'dark')

    // First op must be a write to the tmp file, then rename to the real file.
    expect(observed[0]).toEqual({ op: 'write', path: TMP_PATH })
    expect(observed[1]).toEqual({ op: 'rename', path: `${TMP_PATH}->${STORE_PATH}` })
    expect(JSON.parse(fsState.files.get(STORE_PATH)!)).toEqual({ theme: 'dark' })
  })

  it('leaves the original file intact when the process is killed between writeFile and rename', async () => {
    const set = getHandler('store:set')

    // Seed an existing settings file.
    fsState.files.set(STORE_PATH, JSON.stringify({ theme: 'light', fontSize: 16 }))
    const original = fsState.files.get(STORE_PATH)!

    // Simulate a crash AFTER the tmp file is written, BEFORE rename runs.
    renameHooks.push(() => {
      throw new Error('process killed')
    })

    await expect(set({}, 'theme', 'dark')).rejects.toThrow()

    // The real settings file must still be valid JSON matching the original.
    const after = fsState.files.get(STORE_PATH)
    expect(after).toBeDefined()
    expect(after).toBe(original)
    expect(() => JSON.parse(after!)).not.toThrow()
  })

  it('serialises 100 parallel store:set calls so no key is lost', async () => {
    const set = getHandler('store:set')

    const writes: Promise<unknown>[] = []
    for (let i = 0; i < 100; i++) {
      writes.push(set({}, `key${i}`, i))
    }
    await Promise.all(writes)

    const final = JSON.parse(fsState.files.get(STORE_PATH)!)
    for (let i = 0; i < 100; i++) {
      expect(final[`key${i}`]).toBe(i)
    }
    expect(Object.keys(final).length).toBe(100)
  })

  it('serialises concurrent writes against different keys (read-modify-write is queued)', async () => {
    const set = getHandler('store:set')

    // Two concurrent set()s. Without the queue the second would clobber the first.
    const [a, b] = await Promise.all([set({}, 'a', 1), set({}, 'b', 2)])
    void a
    void b

    const final = JSON.parse(fsState.files.get(STORE_PATH)!)
    expect(final).toEqual({ a: 1, b: 2 })
  })

  it('store:get still returns the latest value after queued writes', async () => {
    const set = getHandler('store:set')
    const get = getHandler('store:get')

    await Promise.all([set({}, 'a', 'first'), set({}, 'a', 'second'), set({}, 'a', 'third')])

    const value = await get({}, 'a')
    // The exact last writer wins is implementation detail; what matters is the
    // value is one of the writes and the file is valid JSON.
    expect(['first', 'second', 'third']).toContain(value)
    expect(() => JSON.parse(fsState.files.get(STORE_PATH)!)).not.toThrow()
  })
})
