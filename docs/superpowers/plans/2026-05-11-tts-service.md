# TTS service refactor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `ttsService` + `ttsQueue` + `ttsCache` + `ttsPrefetch` into a single deep `services/tts/` module with a typed factory boundary, ported dependencies, and a converged boundary test suite.

**Architecture:** One factory `createTtsService(deps: TtsServiceDeps)`. Dependencies (`ipc`, `fetch`, `getAuthToken`, `config`) injected at the boundary. EventEmitter3 stays internal — public surface uses a typed `Emitter<T>` with `unsubscribe`-returning `onAudioReady`/`onError`. `ttsPrefetch` stays a separate file consuming the service, not internals.

**Tech Stack:** TypeScript, vitest, EventEmitter3 (internal), priorityqueuejs (internal), Electron IPC (via injected port), OpenAI-compatible HTTP TTS.

**Spec:** [`docs/superpowers/specs/2026-05-11-tts-service-design.md`](../specs/2026-05-11-tts-service-design.md)

**Parent meta-spec:** [`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md`](../specs/2026-05-11-services-and-effect-adoption-design.md)

---

## Plan overview

- **Task 0 — Branch + scaffold:** Create `refactor/tts-service` from `origin/main`, scaffold the empty service directory.
- **Tasks 1–7 — Build the service (TDD):** Types → emitter helper → cache → transport → queue → factory → public exports. Each behavior gets a RED/GREEN/COMMIT cycle.
- **Tasks 8–12 — Wire & migrate callers:** Add `getTtsService()` to `services/index.ts`, migrate `usePlayerMachine`, `ipc_handel_functions`, `ttsPrefetch`, and `stateDump`.
- **Task 13 — Delete old modules:** Remove the 4 old files + 3 old test files.
- **Task 14 — Final verification.** `pnpm typecheck`, `pnpm lint`, `pnpm test`.

All paths below are absolute from the monorepo root (`/Users/faridmatovu/projects/rishi-monorepo`). All commands should be run from `apps/rishi-electron` unless otherwise stated.

---

## Task 0: Branch + scaffold

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/index.ts` (placeholder)

- [ ] **Step 1: Confirm no WIP TTS changes are uncommitted, then create the branch**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git fetch origin
git status -s -- apps/rishi-electron/src/renderer/src/modules/tts apps/rishi-electron/src/renderer/src/services
```

Expected: no `M` or `??` lines under those paths. If there are uncommitted TTS edits, stash or commit them on a separate branch first.

```bash
git checkout main
git pull origin main
git checkout -b refactor/tts-service
```

- [ ] **Step 2: Create the empty service directory with a placeholder `index.ts`**

```bash
mkdir -p /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src/renderer/src/services/tts
```

Create `apps/rishi-electron/src/renderer/src/services/tts/index.ts`:

```ts
// Placeholder — populated incrementally by subsequent tasks.
export {}
```

- [ ] **Step 3: Verify typecheck still passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/index.ts
git commit -m "refactor(tts): scaffold services/tts directory

Empty index.ts placeholder. Behavior added incrementally in subsequent
commits (TDD: red → green → commit per behavior)."
```

---

## Task 1: Type definitions (`types.ts`)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/types.ts`

- [ ] **Step 1: Create `types.ts` with the full public type surface**

Create `apps/rishi-electron/src/renderer/src/services/tts/types.ts`:

```ts
/**
 * Audio request submitted to the service. `requestId` is derived as
 * `${bookId}-${cfiRange}`; callers never construct it directly.
 */
export interface AudioRequest {
  bookId: string
  /** CFI range, or a `texthash:<md5>` synthetic key for prefetch. */
  cfiRange: string
  text: string
  /** Higher = sooner. Default 0. Active playback uses 1, prefetch uses 0. */
  priority?: number
}

export interface AudioReadyEvent {
  bookId: string
  cfiRange: string
  /** Blob URL (object URL) for an audio/mpeg blob. */
  audioPath: string
}

export interface AudioErrorEvent {
  bookId: string
  cfiRange: string
  /** Human-readable error message. */
  error: string
}

export interface QueueStatus {
  /** Items waiting for a free concurrency slot. */
  pending: number
  /** True iff at least one request is currently occupying a slot. */
  isProcessing: boolean
  /** Items currently in-flight (occupying a concurrency slot). */
  active: number
}

/**
 * Discriminated union returned by the auth port. The service never knows
 * whether the user is signed in via Clerk or dev-bypass; it just branches
 * on the discriminator to pick the right HTTP header.
 */
export type AuthHeader =
  | { kind: 'bearer'; token: string }
  | { kind: 'dev-bypass'; secret: string }

/**
 * Exactly the 7 IPC channels the cache uses, plus `getAppDataPath` and
 * `getCacheFileStats` used by eviction. No other `window.electron.*`
 * surface leaks into the service.
 */
export interface TtsIpcChannels {
  mkdir(path: string): Promise<void>
  exists(path: string): Promise<boolean>
  writeFile(path: string, data: Uint8Array): Promise<void>
  readFile(path: string): Promise<ArrayBuffer>
  copyFile(src: string, dest: string): Promise<void>
  removeFile(path: string): Promise<void>
  getDirSize(path: string): Promise<number>
  getCacheFileStats(
    dir: string
  ): Promise<Array<{ path: string; size: number; mtimeMs: number }>>
  getAppDataPath(): Promise<string>
}

export interface TtsConfig {
  audioWorkerUrl: string
  /** Hard cap on disk cache size. Default 500 MB. */
  cacheMaxBytes: number
  /** Max concurrent HTTP requests. Default 8. */
  maxConcurrent: number
}

export interface TtsServiceDeps {
  ipc: TtsIpcChannels
  fetch: (url: string, init: RequestInit) => Promise<Response>
  getAuthToken: () => Promise<AuthHeader>
  config: TtsConfig
}

export interface TtsService {
  requestAudio(req: AudioRequest): Promise<string>
  cancelRequest(bookId: string, cfiRange: string): boolean
  cancelBookRequests(bookId: string): void
  clearBookCache(bookId: string): Promise<void>
  getQueueStatus(): QueueStatus
  onAudioReady(cb: (event: AudioReadyEvent) => void): () => void
  onError(cb: (event: AudioErrorEvent) => void): () => void
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes (types only — no behavior).

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/types.ts
git commit -m "refactor(tts): add public type surface (AudioRequest, TtsService, AuthHeader)

Discriminated AuthHeader union pushes dev-bypass vs bearer decision to
the wiring site. TtsIpcChannels enumerates the exact IPC surface the
service needs — no transitive window.electron access."
```

---

## Task 2: Emitter helper — RED

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/emitter.test.ts`

- [ ] **Step 1: Write the failing test for the typed Emitter**

Create `apps/rishi-electron/src/renderer/src/services/tts/emitter.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createEmitter } from './emitter'

describe('createEmitter', () => {
  it('delivers emitted values to a subscribed listener', () => {
    const e = createEmitter<{ value: number }>()
    const listener = vi.fn()
    e.on(listener)

    e.emit({ value: 42 })

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith({ value: 42 })
  })

  it('fans an emit out to every subscriber', () => {
    const e = createEmitter<string>()
    const a = vi.fn()
    const b = vi.fn()
    e.on(a)
    e.on(b)

    e.emit('hello')

    expect(a).toHaveBeenCalledWith('hello')
    expect(b).toHaveBeenCalledWith('hello')
  })

  it('returns an unsubscribe function that removes the listener', () => {
    const e = createEmitter<number>()
    const listener = vi.fn()
    const unsubscribe = e.on(listener)

    e.emit(1)
    unsubscribe()
    e.emit(2)

    expect(listener).toHaveBeenCalledTimes(1)
    expect(listener).toHaveBeenCalledWith(1)
  })
})
```

- [ ] **Step 2: Run the test — expect RED (module not found)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/emitter.test.ts
```

Expected: 3 tests fail with "Cannot find module './emitter'".

---

## Task 3: Emitter helper — GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/emitter.ts`

- [ ] **Step 1: Implement `createEmitter`**

Create `apps/rishi-electron/src/renderer/src/services/tts/emitter.ts`:

```ts
/**
 * Tiny typed emitter — no event names, single payload type T.
 * `on(listener)` returns an unsubscribe function (idempotent).
 */
export interface Emitter<T> {
  emit(payload: T): void
  on(listener: (payload: T) => void): () => void
}

export function createEmitter<T>(): Emitter<T> {
  const listeners = new Set<(payload: T) => void>()
  return {
    emit(payload) {
      for (const listener of listeners) listener(payload)
    },
    on(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    }
  }
}
```

- [ ] **Step 2: Run the test — expect 3 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/emitter.test.ts
```

Expected: 3 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/emitter.ts apps/rishi-electron/src/renderer/src/services/tts/emitter.test.ts
git commit -m "test(tts): typed Emitter helper with unsubscribe returns

Tiny utility replacing EventEmitter at the public surface. on() returns
an unsubscribe function — canonical idiom. ~15 LOC."
```

---

## Task 4: Cache module scaffold + test helpers — RED

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`

- [ ] **Step 1: Write the test helper + first failing test for cache miss → file path resolution**

Create `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`:

```ts
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
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 1 test fails with "Cannot find module './cache'".

---

## Task 5: Cache module — `audioPath` GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`

- [ ] **Step 1: Implement `createCache` with `audioPath` only**

Create `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`:

```ts
import md5 from 'md5'
import type { TtsIpcChannels } from './types'

const TTS_CACHE_DIR = 'tts-cache'

export interface CacheDeps {
  ipc: TtsIpcChannels
  cacheMaxBytes: number
}

export interface Cache {
  audioPath(bookId: string, cfiRange: string): Promise<string>
  getAudio(bookId: string, cfiRange: string, textHash?: string): Promise<ArrayBuffer | null>
  saveAudio(
    bookId: string,
    cfiRange: string,
    bytes: Uint8Array,
    textHash?: string
  ): Promise<string>
  clearBook(bookId: string): Promise<void>
  evictIfNeeded(): Promise<void>
}

export function createCache(deps: CacheDeps): Cache {
  const { ipc } = deps
  let rootDir = ''
  let initPromise: Promise<void> | null = null
  const knownBookDirs = new Set<string>()

  async function init(): Promise<void> {
    if (!initPromise) {
      initPromise = (async () => {
        const appData = await ipc.getAppDataPath()
        rootDir = `${appData}/${TTS_CACHE_DIR}`
        await ipc.mkdir(rootDir)
      })()
    }
    return initPromise
  }

  async function bookDir(bookId: string): Promise<string> {
    await init()
    const dir = `${rootDir}/${bookId}`
    if (!knownBookDirs.has(dir)) {
      const exists = await ipc.exists(dir)
      if (!exists) await ipc.mkdir(dir)
      knownBookDirs.add(dir)
    }
    return dir
  }

  async function audioPath(bookId: string, cfiRange: string): Promise<string> {
    const dir = await bookDir(bookId)
    return `${dir}/${md5(cfiRange)}.mp3`
  }

  return {
    audioPath,
    async getAudio() {
      throw new Error('not implemented')
    },
    async saveAudio() {
      throw new Error('not implemented')
    },
    async clearBook() {
      throw new Error('not implemented')
    },
    async evictIfNeeded() {
      throw new Error('not implemented')
    }
  }
}
```

- [ ] **Step 2: Run the test — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 1 test passes.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/cache.ts apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts
git commit -m "test(tts): cache audioPath resolves to userData/tts-cache/<book>/<md5>.mp3"
```

---

## Task 6: Cache — `saveAudio` + write-through (CFI + text-hash)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`

- [ ] **Step 1: Add the failing test for `saveAudio` writing under both keys**

Append to `cache.test.ts`:

```ts
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
```

- [ ] **Step 2: Run the tests — expect 3 RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 3 new tests fail ("not implemented"); the prior test still passes.

- [ ] **Step 3: Implement `saveAudio`**

In `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`, replace the `saveAudio` stub:

```ts
    async saveAudio(bookId, cfiRange, bytes, textHash) {
      if (bytes.byteLength === 0) {
        throw new Error('Audio blob is zero bytes, skipping cache write')
      }
      const path = await audioPath(bookId, cfiRange)
      await ipc.writeFile(path, bytes)

      if (textHash && !cfiRange.startsWith('texthash:')) {
        try {
          const mirror = await audioPath(bookId, `texthash:${md5(textHash)}`)
          const mirrorExists = await ipc.exists(mirror)
          if (!mirrorExists) await ipc.copyFile(path, mirror)
        } catch {
          // Non-critical — CFI-based lookup still works
        }
      }
      return path
    },
```

- [ ] **Step 4: Run tests — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/cache.ts apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts
git commit -m "test(tts): cache saveAudio writes CFI + text-hash mirror; rejects empty bytes"
```

---

## Task 7: Cache — `getAudio` with CFI hit and text-hash fallback

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`

- [ ] **Step 1: Add failing tests for `getAudio`**

Append to `cache.test.ts`:

```ts
describe('cache.getAudio', () => {
  it('returns the cached ArrayBuffer when the CFI key hits', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })
    await cache.saveAudio('book-1', 'cfi-x', new Uint8Array([9, 9, 9]))

    const got = await cache.getAudio('book-1', 'cfi-x')

    expect(got).not.toBeNull()
    expect(new Uint8Array(got!)).toEqual(new Uint8Array([9, 9, 9]))
  })

  it('falls back to text-hash key when CFI is absent', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })
    // Save under cfi-x WITH textHash so mirror is created
    await cache.saveAudio('book-1', 'cfi-x', new Uint8Array([7, 7]), 'paragraph text')

    // Looking up a different CFI but with the same text-hash should resolve
    const got = await cache.getAudio('book-1', 'cfi-different', 'paragraph text')

    expect(got).not.toBeNull()
    expect(new Uint8Array(got!)).toEqual(new Uint8Array([7, 7]))
  })

  it('returns null when both lookups miss', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })

    const got = await cache.getAudio('book-1', 'cfi-missing', 'no-text')

    expect(got).toBeNull()
  })
})
```

- [ ] **Step 2: Run tests — expect 3 RED**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 3 new tests fail ("not implemented").

- [ ] **Step 3: Implement `getAudio`**

In `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`, replace the `getAudio` stub:

```ts
    async getAudio(bookId, cfiRange, textHash) {
      const cfiPath = await audioPath(bookId, cfiRange)
      if (await ipc.exists(cfiPath)) {
        return ipc.readFile(cfiPath)
      }
      if (textHash) {
        const mirror = await audioPath(bookId, `texthash:${md5(textHash)}`)
        if (await ipc.exists(mirror)) {
          return ipc.readFile(mirror)
        }
      }
      return null
    },
```

- [ ] **Step 4: Run tests — expect 7 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/cache.ts apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts
git commit -m "test(tts): cache getAudio honors CFI key then text-hash fallback"
```

---

## Task 8: Cache — `clearBook`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`

- [ ] **Step 1: Add failing test**

Append to `cache.test.ts`:

```ts
describe('cache.clearBook', () => {
  it('removes the book directory recursively and forgets its membership', async () => {
    const { ipc, files } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })
    await cache.saveAudio('book-1', 'cfi-a', new Uint8Array([1]))
    await cache.saveAudio('book-1', 'cfi-b', new Uint8Array([2]))
    expect([...files.keys()].filter((k) => k.includes('/book-1/'))).toHaveLength(2)

    await cache.clearBook('book-1')

    expect([...files.keys()].filter((k) => k.includes('/book-1/'))).toHaveLength(0)
    expect(ipc.removeFile).toHaveBeenCalledWith('/userData/tts-cache/book-1')
  })

  it('is a no-op when the book directory does not exist', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 500 * 1024 * 1024 })

    await expect(cache.clearBook('never-cached')).resolves.toBeUndefined()
    expect(ipc.removeFile).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run tests — expect 2 RED**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 2 new tests fail.

- [ ] **Step 3: Implement `clearBook`**

In `cache.ts`, replace the `clearBook` stub:

```ts
    async clearBook(bookId) {
      await init()
      const dir = `${rootDir}/${bookId}`
      knownBookDirs.delete(dir)
      if (await ipc.exists(dir)) {
        await ipc.removeFile(dir)
      }
    },
```

- [ ] **Step 4: Run tests — expect 9 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/cache.ts apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts
git commit -m "test(tts): cache clearBook recursively removes book dir"
```

---

## Task 9: Cache — `evictIfNeeded` LRU under size pressure

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts`
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/cache.ts`

- [ ] **Step 1: Add failing test**

Append to `cache.test.ts`:

```ts
describe('cache.evictIfNeeded', () => {
  it('removes oldest files until total size is under threshold', async () => {
    const { ipc, files } = makeIpc()
    // tight cap: 10 bytes total, threshold = 0.8 * 10 = 8 bytes
    const cache = createCache({ ipc, cacheMaxBytes: 10 })
    // Three 4-byte files = 12 bytes total → over 80% threshold
    await cache.saveAudio('book-1', 'cfi-1', new Uint8Array([1, 1, 1, 1]))
    await cache.saveAudio('book-1', 'cfi-2', new Uint8Array([2, 2, 2, 2]))
    await cache.saveAudio('book-1', 'cfi-3', new Uint8Array([3, 3, 3, 3]))

    await cache.evictIfNeeded()

    // Should evict oldest file(s) until ≤ 8 bytes remain
    const totalBytes = [...files.values()].reduce((n, b) => n + b.byteLength, 0)
    expect(totalBytes).toBeLessThanOrEqual(8)
    expect(ipc.removeFile).toHaveBeenCalled()
  })

  it('is a no-op when total size is below threshold', async () => {
    const { ipc } = makeIpc()
    const cache = createCache({ ipc, cacheMaxBytes: 1000 })
    await cache.saveAudio('book-1', 'cfi-1', new Uint8Array([1, 2, 3]))

    await cache.evictIfNeeded()

    expect(ipc.removeFile).not.toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run tests — expect 2 RED**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 2 new tests fail.

- [ ] **Step 3: Implement `evictIfNeeded`**

In `cache.ts`, replace the `evictIfNeeded` stub:

```ts
    async evictIfNeeded() {
      await init()
      const total = await ipc.getDirSize(rootDir)
      const threshold = deps.cacheMaxBytes * 0.8
      if (total <= threshold) return

      const stats = await ipc.getCacheFileStats(rootDir)
      stats.sort((a, b) => a.mtimeMs - b.mtimeMs) // oldest first
      let current = total
      for (const file of stats) {
        if (current <= threshold) break
        try {
          await ipc.removeFile(file.path)
          current -= file.size
        } catch {
          // best-effort
        }
      }
    },
```

- [ ] **Step 4: Run tests — expect 11 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/cache.test.ts
```

Expected: 11 tests pass.

- [ ] **Step 5: Verify typecheck passes**

```bash
pnpm typecheck
```

Expected: passes.

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/cache.ts apps/rishi-electron/src/renderer/src/services/tts/cache.test.ts
git commit -m "test(tts): cache evictIfNeeded drops oldest files past 80% threshold"
```

---

## Task 10: Transport module — happy path (bearer)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/tts/transport.ts`

- [ ] **Step 1: Write the failing test**

Create `apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { fetchAudio, TtsTransportError } from './transport'
import type { AuthHeader, TtsConfig } from './types'

function makeFetch(opts: {
  audioBytes?: Uint8Array
  status?: number
  errorBody?: string
  retryAfter?: string
  rejectWith?: Error
}) {
  const status = opts.status ?? 200
  const bytes = opts.audioBytes ?? new Uint8Array([0xff, 0xfb, 0x90])
  const calls: Array<{ url: string; init: RequestInit }> = []
  const fetch = vi.fn(async (url: string, init: RequestInit) => {
    calls.push({ url, init })
    if (opts.rejectWith) throw opts.rejectWith
    const headers = new Headers()
    if (opts.retryAfter) headers.set('Retry-After', opts.retryAfter)
    return new Response(status === 200 ? bytes : opts.errorBody ?? '', {
      status,
      headers
    })
  })
  return { fetch, calls }
}

const baseConfig: TtsConfig = {
  audioWorkerUrl: 'https://api.example.com/audio/speech',
  cacheMaxBytes: 500 * 1024 * 1024,
  maxConcurrent: 8
}

const bearer: AuthHeader = { kind: 'bearer', token: 'tok-123' }
const devBypass: AuthHeader = { kind: 'dev-bypass', secret: 's3cret' }

describe('fetchAudio (transport)', () => {
  it('POSTs JSON body with Authorization: Bearer header and returns bytes', async () => {
    const { fetch, calls } = makeFetch({ audioBytes: new Uint8Array([1, 2, 3, 4]) })

    const bytes = await fetchAudio({
      fetch,
      auth: bearer,
      config: baseConfig,
      text: 'hello world'
    })

    expect(new Uint8Array(bytes)).toEqual(new Uint8Array([1, 2, 3, 4]))
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe('https://api.example.com/audio/speech')
    expect(calls[0].init.method).toBe('POST')
    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['Authorization']).toBe('Bearer tok-123')
    expect(headers['Content-Type']).toBe('application/json')
    expect(headers['X-Dev-Bypass']).toBeUndefined()
    const body = JSON.parse(calls[0].init.body as string)
    expect(body).toEqual({
      voice: 'alloy',
      input: 'hello world',
      response_format: 'mp3',
      speed: 1.0
    })
  })
})
```

- [ ] **Step 2: Run the test — expect RED (module not found)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/transport.test.ts
```

Expected: fails — `./transport` not found.

- [ ] **Step 3: Implement `fetchAudio` minimally**

Create `apps/rishi-electron/src/renderer/src/services/tts/transport.ts`:

```ts
import type { AuthHeader, TtsConfig } from './types'

export class TtsTransportError extends Error {
  constructor(
    message: string,
    public readonly status: number | null,
    public readonly retryable: boolean,
    public readonly retryAfterMs: number | null
  ) {
    super(message)
    this.name = 'TtsTransportError'
  }
}

export interface FetchAudioArgs {
  fetch: (url: string, init: RequestInit) => Promise<Response>
  auth: AuthHeader
  config: TtsConfig
  text: string
}

const TTS_MAX_INPUT_CHARS = 4000
const TTS_TIMEOUT_MS = 30_000

function buildHeaders(auth: AuthHeader): Record<string, string> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' }
  if (auth.kind === 'bearer') headers['Authorization'] = `Bearer ${auth.token}`
  else headers['X-Dev-Bypass'] = auth.secret
  return headers
}

export async function fetchAudio(args: FetchAudioArgs): Promise<ArrayBuffer> {
  const { fetch, auth, config, text } = args
  const truncated = text.length > TTS_MAX_INPUT_CHARS ? text.slice(0, TTS_MAX_INPUT_CHARS) + '…' : text
  const body = JSON.stringify({
    voice: 'alloy',
    input: truncated,
    response_format: 'mp3',
    speed: 1.0
  })

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), TTS_TIMEOUT_MS)
  let response: Response
  try {
    response = await fetch(config.audioWorkerUrl, {
      method: 'POST',
      headers: buildHeaders(auth),
      body,
      signal: controller.signal
    })
  } finally {
    clearTimeout(timeout)
  }

  if (!response.ok) {
    const errorBody = await response.text().catch(() => '')
    const retryAfterRaw = response.headers.get('Retry-After')
    const retryAfterMs = retryAfterRaw ? Number(retryAfterRaw) * 1000 : null
    const retryable = response.status === 429 || response.status >= 500
    throw new TtsTransportError(
      `TTS API error ${response.status} ${response.statusText} - ${errorBody.slice(0, 500)}`,
      response.status,
      retryable,
      Number.isFinite(retryAfterMs) ? retryAfterMs : null
    )
  }

  const bytes = await response.arrayBuffer()
  if (bytes.byteLength === 0) {
    throw new TtsTransportError('TTS API returned empty audio buffer', response.status, false, null)
  }
  return bytes
}
```

- [ ] **Step 4: Run test — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/transport.test.ts
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/transport.ts apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts
git commit -m "test(tts): fetchAudio happy path (bearer header, JSON body, arrayBuffer)"
```

---

## Task 11: Transport — dev-bypass header

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts`

- [ ] **Step 1: Add the dev-bypass test (expect GREEN with current impl)**

Append inside the `describe('fetchAudio (transport)', ...)` block:

```ts
  it('uses X-Dev-Bypass header (and no Authorization) when auth is dev-bypass', async () => {
    const { fetch, calls } = makeFetch({})

    await fetchAudio({ fetch, auth: devBypass, config: baseConfig, text: 'hi' })

    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['X-Dev-Bypass']).toBe('s3cret')
    expect(headers['Authorization']).toBeUndefined()
  })
```

- [ ] **Step 2: Run tests — expect 2 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/transport.test.ts
```

Expected: 2 tests pass (the dev-bypass branch is already implemented).

- [ ] **Step 3: Commit (test-only)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts
git commit -m "test(tts): fetchAudio dev-bypass uses X-Dev-Bypass header (no Authorization)"
```

---

## Task 12: Transport — error classification (401 vs 429 vs 5xx vs network)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts`

- [ ] **Step 1: Add 4 failing/expected-green tests**

Append inside the same describe:

```ts
  it('throws TtsTransportError with retryable=false on 401', async () => {
    const { fetch } = makeFetch({ status: 401, errorBody: 'unauthorized' })

    const err = await fetchAudio({ fetch, auth: bearer, config: baseConfig, text: 'hi' })
      .catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(401)
    expect(err.retryable).toBe(false)
    expect(err.retryAfterMs).toBeNull()
  })

  it('throws TtsTransportError with retryable=true and parsed retryAfterMs on 429', async () => {
    const { fetch } = makeFetch({ status: 429, errorBody: 'slow down', retryAfter: '2' })

    const err = await fetchAudio({ fetch, auth: bearer, config: baseConfig, text: 'hi' })
      .catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(429)
    expect(err.retryable).toBe(true)
    expect(err.retryAfterMs).toBe(2000)
  })

  it('throws TtsTransportError with retryable=true on 503', async () => {
    const { fetch } = makeFetch({ status: 503, errorBody: 'down' })

    const err = await fetchAudio({ fetch, auth: bearer, config: baseConfig, text: 'hi' })
      .catch((e) => e)
    expect(err).toBeInstanceOf(TtsTransportError)
    expect(err.status).toBe(503)
    expect(err.retryable).toBe(true)
  })

  it('propagates network errors raised by fetch', async () => {
    const { fetch } = makeFetch({ rejectWith: new Error('ECONNRESET') })

    await expect(
      fetchAudio({ fetch, auth: bearer, config: baseConfig, text: 'hi' })
    ).rejects.toThrow('ECONNRESET')
  })
```

- [ ] **Step 2: Run tests — expect 6 GREEN**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/transport.test.ts
```

Expected: 6 tests pass. The transport implementation already classifies these statuses correctly.

- [ ] **Step 3: Commit (test-only)**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/transport.test.ts
git commit -m "test(tts): fetchAudio classifies 401/429/5xx and propagates network errors"
```

---

## Task 13: Queue module — enqueue → fetch path (RED)

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts`

- [ ] **Step 1: Write the failing test for the most basic enqueue flow**

Create `apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts`:

```ts
import { describe, it, expect, vi } from 'vitest'
import { createQueue } from './queue'

/** Build a fake transport that resolves with the given bytes after N rejects. */
export function makeTransport(opts: { bytes?: Uint8Array; failNTimes?: number; reject?: Error }) {
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
    return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
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
```

- [ ] **Step 2: Run the test — expect RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/queue.test.ts
```

Expected: fails — `./queue` not found.

---

## Task 14: Queue — enqueue happy path GREEN + COMMIT

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/queue.ts`

- [ ] **Step 1: Implement minimal `createQueue` with enqueue → fetch → cache write**

Create `apps/rishi-electron/src/renderer/src/services/tts/queue.ts`:

```ts
import PriorityQueue from 'priorityqueuejs'
import type { Cache } from './cache'
import { TtsTransportError } from './transport'

export interface EnqueueArgs {
  bookId: string
  cfiRange: string
  text: string
  priority: number
}

export interface QueueDeps {
  cache: Pick<Cache, 'getAudio' | 'saveAudio' | 'evictIfNeeded'>
  /**
   * Transport callable. The queue does not know about auth/config — it just
   * forwards the text and gets bytes back (or a TtsTransportError).
   */
  fetchAudio: (text: string) => Promise<ArrayBuffer>
  maxConcurrent: number
  maxRetries: number
  /** Backoff = backoffBaseMs * 2^attempt. */
  backoffBaseMs: number
}

interface QueueItem {
  bookId: string
  cfiRange: string
  text: string
  priority: number
  requestId: string
  resolve: (bytes: ArrayBuffer) => void
  reject: (err: Error) => void
  retryCount: number
}

const MAX_QUEUE_SIZE = 15

export interface Queue {
  enqueue(req: EnqueueArgs): Promise<ArrayBuffer>
  cancel(requestId: string): boolean
  cancelBook(bookId: string): void
  clear(): void
  status(): { pending: number; isProcessing: boolean; active: number }
}

export function createQueue(deps: QueueDeps): Queue {
  const pq = new PriorityQueue<QueueItem>((a, b) => b.priority - a.priority)
  const active = new Map<string, QueueItem>()
  /** All in-flight or queued items, keyed by requestId, for dedup. */
  const pending = new Map<string, QueueItem>()
  const retryTimers = new Set<ReturnType<typeof setTimeout>>()
  let inFlight = 0

  function fillSlots(): void {
    while (inFlight < deps.maxConcurrent && pq.size() > 0) {
      const item = pq.deq()
      inFlight++
      active.set(item.requestId, item)
      void processItem(item).finally(() => {
        inFlight--
        active.delete(item.requestId)
        fillSlots()
      })
    }
  }

  async function processItem(item: QueueItem): Promise<void> {
    try {
      const bytes = await deps.fetchAudio(item.text)
      void deps.cache
        .saveAudio(item.bookId, item.cfiRange, new Uint8Array(bytes))
        .catch(() => {})
      void deps.cache.evictIfNeeded().catch(() => {})
      pending.delete(item.requestId)
      item.resolve(bytes)
    } catch (err) {
      const retryable = err instanceof TtsTransportError ? err.retryable : isRetryableMessage(err)
      if (retryable && item.retryCount < deps.maxRetries) {
        item.retryCount++
        const delay = deps.backoffBaseMs * 2 ** (item.retryCount - 1)
        const t = setTimeout(() => {
          retryTimers.delete(t)
          pq.enq(item)
          fillSlots()
        }, delay)
        retryTimers.add(t)
      } else {
        pending.delete(item.requestId)
        item.reject(err instanceof Error ? err : new Error(String(err)))
      }
    }
  }

  function isRetryableMessage(err: unknown): boolean {
    const msg = err instanceof Error ? err.message.toLowerCase() : String(err).toLowerCase()
    return /timeout|network|rate limit|server error|temporary|connection|econnreset/.test(msg)
  }

  function trimIfNeeded(): void {
    if (pq.size() < MAX_QUEUE_SIZE) return
    const items: QueueItem[] = []
    while (pq.size() > 0) items.push(pq.deq())
    const kept = items.slice(0, MAX_QUEUE_SIZE - 1)
    const dropped = items.slice(MAX_QUEUE_SIZE - 1)
    for (const i of kept) pq.enq(i)
    for (const d of dropped) {
      pending.delete(d.requestId)
      d.reject(new Error('Dropped from queue (low priority)'))
    }
  }

  return {
    enqueue(req) {
      const requestId = `${req.bookId}-${req.cfiRange}`
      const existing = pending.get(requestId)
      if (existing) {
        // Dedup: piggy-back on the existing item's resolution.
        return new Promise<ArrayBuffer>((resolve, reject) => {
          const origResolve = existing.resolve
          const origReject = existing.reject
          existing.resolve = (bytes) => {
            origResolve(bytes)
            resolve(bytes)
          }
          existing.reject = (err) => {
            origReject(err)
            reject(err)
          }
        })
      }
      return new Promise<ArrayBuffer>((resolve, reject) => {
        const item: QueueItem = {
          bookId: req.bookId,
          cfiRange: req.cfiRange,
          text: req.text,
          priority: req.priority,
          requestId,
          resolve,
          reject,
          retryCount: 0
        }
        pq.enq(item)
        pending.set(requestId, item)
        trimIfNeeded()
        fillSlots()
      })
    },
    cancel(requestId) {
      const item = pending.get(requestId)
      if (!item) return false
      pending.delete(requestId)
      active.delete(requestId)
      item.reject(new Error('Request cancelled'))
      return true
    },
    cancelBook(bookId) {
      for (const [requestId, item] of [...pending]) {
        if (item.bookId === bookId) {
          pending.delete(requestId)
          active.delete(requestId)
          item.reject(new Error('Request cancelled'))
        }
      }
    },
    clear() {
      for (const t of retryTimers) clearTimeout(t)
      retryTimers.clear()
      while (pq.size() > 0) {
        const item = pq.deq()
        pending.delete(item.requestId)
        item.reject(new Error('Queue cleared'))
      }
      for (const [, item] of active) item.reject(new Error('Request cancelled'))
      active.clear()
      pending.clear()
    },
    status() {
      return {
        pending: pq.size(),
        isProcessing: inFlight > 0,
        active: active.size
      }
    }
  }
}
```

- [ ] **Step 2: Run tests — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/queue.test.ts
```

Expected: 1 test passes.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/queue.ts apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts
git commit -m "test(tts): queue enqueue happy path (fetch → cache.saveAudio → resolve)"
```

---

## Task 15: Queue — cache-hit short-circuit lives at the SERVICE layer (skip note)

The queue does not check the cache — the service does, before enqueueing. We will assert that contract in Task 19. **Do not add a "cache-hit" test to `queue.test.ts`.** This task is a note, not a step.

---

## Task 16: Queue — dedup of in-flight request

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts`

- [ ] **Step 1: Add the failing/expected-green test**

Append:

```ts
describe('queue dedup', () => {
  it('coalesces two concurrent enqueues with the same requestId into one fetch', async () => {
    // Block the fetch on a promise we control so both enqueues land while in-flight
    let resolveFetch: (b: ArrayBuffer) => void = () => {}
    const fetchAudio = vi.fn(
      () =>
        new Promise<ArrayBuffer>((resolve) => {
          resolveFetch = resolve
        })
    )
    const cache = makeCacheStub()
    const queue = createQueue({
      cache,
      fetchAudio,
      maxConcurrent: 8,
      maxRetries: 0,
      backoffBaseMs: 1
    })

    const p1 = queue.enqueue({ bookId: 'b', cfiRange: 'c', text: 'hi', priority: 0 })
    const p2 = queue.enqueue({ bookId: 'b', cfiRange: 'c', text: 'hi', priority: 0 })

    // Let microtasks settle so the first enqueue reaches the in-flight state
    await new Promise((r) => setTimeout(r, 0))
    resolveFetch(new Uint8Array([7, 7]).buffer as ArrayBuffer)

    const [r1, r2] = await Promise.all([p1, p2])
    expect(new Uint8Array(r1)).toEqual(new Uint8Array([7, 7]))
    expect(new Uint8Array(r2)).toEqual(new Uint8Array([7, 7]))
    expect(fetchAudio).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/queue.test.ts
```

Expected: 2 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts
git commit -m "test(tts): queue dedups concurrent enqueue with same requestId"
```

---

## Task 17: Queue — retry with backoff and give-up

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts`

- [ ] **Step 1: Add 2 tests (one expects retry success, one expects give-up)**

Append:

```ts
describe('queue retry', () => {
  it('retries on transient TtsTransportError and ultimately resolves', async () => {
    const transport = makeTransport({
      bytes: new Uint8Array([5, 6, 7]),
      failNTimes: 2
    })
    const cache = makeCacheStub()
    const queue = createQueue({
      cache,
      fetchAudio: transport.fetchAudio,
      maxConcurrent: 1,
      maxRetries: 3,
      backoffBaseMs: 1
    })

    const bytes = await queue.enqueue({
      bookId: 'b',
      cfiRange: 'c',
      text: 'hi',
      priority: 0
    })

    expect(new Uint8Array(bytes)).toEqual(new Uint8Array([5, 6, 7]))
    expect(transport.callCount()).toBe(3) // 2 fails + 1 success
  })

  it('rejects after maxRetries on persistent transient error', async () => {
    const transport = makeTransport({
      failNTimes: 99
    })
    const cache = makeCacheStub()
    const queue = createQueue({
      cache,
      fetchAudio: transport.fetchAudio,
      maxConcurrent: 1,
      maxRetries: 2,
      backoffBaseMs: 1
    })

    await expect(
      queue.enqueue({ bookId: 'b', cfiRange: 'c', text: 'hi', priority: 0 })
    ).rejects.toThrow('transient')
    expect(transport.callCount()).toBe(3) // 1 initial + 2 retries
  })
})
```

- [ ] **Step 2: Run — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/queue.test.ts
```

Expected: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts
git commit -m "test(tts): queue retries on transient errors; gives up after maxRetries"
```

---

## Task 18: Queue — cancellation rejects the in-flight promise

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts`

- [ ] **Step 1: Add cancellation tests**

Append:

```ts
describe('queue cancellation', () => {
  it('cancel(requestId) rejects the enqueued promise with "Request cancelled"', async () => {
    const fetchAudio = vi.fn(() => new Promise<ArrayBuffer>(() => {})) // never resolves
    const queue = createQueue({
      cache: makeCacheStub(),
      fetchAudio,
      maxConcurrent: 1,
      maxRetries: 0,
      backoffBaseMs: 1
    })

    const p = queue.enqueue({ bookId: 'b', cfiRange: 'c', text: 'hi', priority: 0 })
    // Let it land in the active map
    await new Promise((r) => setTimeout(r, 0))

    expect(queue.cancel('b-c')).toBe(true)
    await expect(p).rejects.toThrow('Request cancelled')
    // Second cancel is a no-op
    expect(queue.cancel('b-c')).toBe(false)
  })

  it('cancelBook(bookId) rejects every pending request for that book only', async () => {
    const fetchAudio = vi.fn(() => new Promise<ArrayBuffer>(() => {}))
    const queue = createQueue({
      cache: makeCacheStub(),
      fetchAudio,
      maxConcurrent: 8,
      maxRetries: 0,
      backoffBaseMs: 1
    })

    const a1 = queue.enqueue({ bookId: 'A', cfiRange: 'c1', text: 't1', priority: 0 })
    const a2 = queue.enqueue({ bookId: 'A', cfiRange: 'c2', text: 't2', priority: 0 })
    const b1 = queue.enqueue({ bookId: 'B', cfiRange: 'c3', text: 't3', priority: 0 })

    await new Promise((r) => setTimeout(r, 0))
    queue.cancelBook('A')

    await expect(a1).rejects.toThrow('Request cancelled')
    await expect(a2).rejects.toThrow('Request cancelled')
    // b1 is still in-flight (fetchAudio never resolves) — assert by racing a tiny timeout
    const winner = await Promise.race([
      b1.then(() => 'resolved'),
      new Promise<string>((r) => setTimeout(() => r('pending'), 10))
    ])
    expect(winner).toBe('pending')
  })
})
```

- [ ] **Step 2: Run — expect 6 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/queue.test.ts
```

Expected: 6 tests pass.

- [ ] **Step 3: Verify typecheck passes**

```bash
pnpm typecheck
```

Expected: passes.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/queue.test.ts
git commit -m "test(tts): queue cancel() and cancelBook() reject pending promises"
```

---

## Task 19: Service factory — `requestAudio` cache-miss path

**Files:**
- Create: `apps/rishi-electron/src/renderer/src/services/tts/service.test.ts`
- Create: `apps/rishi-electron/src/renderer/src/services/tts/service.ts`

- [ ] **Step 1: Create `service.test.ts` with the shared `makeFetch` / `makeAuth` helpers + first failing test**

Create `apps/rishi-electron/src/renderer/src/services/tts/service.test.ts`:

```ts
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
    expect(ipc.writeFile).toHaveBeenCalled() // cache write
  })
})
```

- [ ] **Step 2: Run — expect RED**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/service.test.ts
```

Expected: fails — `./service` not found.

- [ ] **Step 3: Implement `createTtsService` (cache-miss path only)**

Create `apps/rishi-electron/src/renderer/src/services/tts/service.ts`:

```ts
import type {
  AudioErrorEvent,
  AudioReadyEvent,
  AudioRequest,
  QueueStatus,
  TtsService,
  TtsServiceDeps
} from './types'
import { createCache } from './cache'
import { createQueue } from './queue'
import { fetchAudio as transportFetchAudio } from './transport'
import { createEmitter } from './emitter'

export function createTtsService(deps: TtsServiceDeps): TtsService {
  const cache = createCache({ ipc: deps.ipc, cacheMaxBytes: deps.config.cacheMaxBytes })
  const audioReady = createEmitter<AudioReadyEvent>()
  const errors = createEmitter<AudioErrorEvent>()

  const queue = createQueue({
    cache,
    fetchAudio: async (text) => {
      const auth = await deps.getAuthToken()
      return transportFetchAudio({
        fetch: deps.fetch,
        auth,
        config: deps.config,
        text
      })
    },
    maxConcurrent: deps.config.maxConcurrent,
    maxRetries: 3,
    backoffBaseMs: 1000
  })

  async function requestAudio(req: AudioRequest): Promise<string> {
    const priority = req.priority ?? 0
    try {
      const cached = await cache.getAudio(req.bookId, req.cfiRange, req.text)
      if (cached) {
        const url = URL.createObjectURL(new Blob([cached], { type: 'audio/mpeg' }))
        audioReady.emit({ bookId: req.bookId, cfiRange: req.cfiRange, audioPath: url })
        return url
      }
      const bytes = await queue.enqueue({
        bookId: req.bookId,
        cfiRange: req.cfiRange,
        text: req.text,
        priority
      })
      const url = URL.createObjectURL(new Blob([bytes], { type: 'audio/mpeg' }))
      audioReady.emit({ bookId: req.bookId, cfiRange: req.cfiRange, audioPath: url })
      return url
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      errors.emit({ bookId: req.bookId, cfiRange: req.cfiRange, error: message })
      throw err
    }
  }

  return {
    requestAudio,
    cancelRequest(bookId, cfiRange) {
      return queue.cancel(`${bookId}-${cfiRange}`)
    },
    cancelBookRequests(bookId) {
      queue.cancelBook(bookId)
    },
    async clearBookCache(bookId) {
      try {
        await cache.clearBook(bookId)
      } catch (err) {
        console.warn(`[tts] clearBookCache failed: ${String(err)}`)
      }
    },
    getQueueStatus(): QueueStatus {
      return queue.status()
    },
    onAudioReady(cb) {
      return audioReady.on(cb)
    },
    onError(cb) {
      return errors.on(cb)
    }
  }
}
```

- [ ] **Step 4: Run — expect GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/service.test.ts
```

Expected: 1 test passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/service.ts apps/rishi-electron/src/renderer/src/services/tts/service.test.ts
git commit -m "test(tts): service.requestAudio cache-miss path returns blob URL"
```

---

## Task 20: Service — cache-hit short-circuit + onAudioReady delivery

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/service.test.ts`

- [ ] **Step 1: Add 2 tests (cache-hit; subscription fires + unsubscribes)**

Append inside the `describe('TtsService.requestAudio', ...)` block:

```ts
  it('cache hit → no HTTP call', async () => {
    const { ipc } = makeIpc()
    // Pre-populate the cache by saving via the cache module the same way service does
    const { createCache } = await import('./cache')
    const cache = createCache({ ipc, cacheMaxBytes: baseConfig.cacheMaxBytes })
    await cache.saveAudio('book-1', 'cfi-x', new Uint8Array([9, 9, 9]))

    const { fetch, callCount } = makeFetch({})
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
      priority: 0
    })

    expect(url).toMatch(/^blob:/)
    expect(callCount()).toBe(0)
  })
})

describe('TtsService.onAudioReady', () => {
  it('fires with {bookId, cfiRange, audioPath} after a successful request', async () => {
    const { ipc } = makeIpc()
    const { fetch } = makeFetch({ audioBytes: new Uint8Array([1, 2]) })
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })
    const handler = vi.fn()
    service.onAudioReady(handler)

    await service.requestAudio({ bookId: 'b', cfiRange: 'c', text: 'x', priority: 0 })

    expect(handler).toHaveBeenCalledTimes(1)
    expect(handler).toHaveBeenCalledWith(
      expect.objectContaining({ bookId: 'b', cfiRange: 'c', audioPath: expect.stringMatching(/^blob:/) })
    )
  })

  it('unsubscribe() prevents subsequent emits from reaching the handler', async () => {
    const { ipc } = makeIpc()
    const { fetch } = makeFetch({})
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })
    const handler = vi.fn()
    const unsub = service.onAudioReady(handler)

    await service.requestAudio({ bookId: 'b', cfiRange: 'c1', text: 'x', priority: 0 })
    unsub()
    await service.requestAudio({ bookId: 'b', cfiRange: 'c2', text: 'y', priority: 0 })

    expect(handler).toHaveBeenCalledTimes(1)
  })
})
```

- [ ] **Step 2: Run — expect 4 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/service.test.ts
```

Expected: 4 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/service.test.ts
git commit -m "test(tts): service cache-hit skips HTTP; onAudioReady fires and unsubscribes"
```

---

## Task 21: Service — auth failure + dev-bypass + onError delivery

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/service.test.ts`

- [ ] **Step 1: Add 3 tests**

Append:

```ts
describe('TtsService auth + error paths', () => {
  it('propagates auth failure; does not call fetch; emits onError', async () => {
    const { ipc } = makeIpc()
    const { fetch, callCount } = makeFetch({})
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: vi.fn(async () => {
        throw new Error('no session')
      }),
      config: baseConfig
    })
    const errHandler = vi.fn()
    service.onError(errHandler)

    await expect(
      service.requestAudio({ bookId: 'b', cfiRange: 'c', text: 't', priority: 0 })
    ).rejects.toThrow('no session')

    expect(callCount()).toBe(0)
    expect(errHandler).toHaveBeenCalledWith(
      expect.objectContaining({ bookId: 'b', cfiRange: 'c', error: 'no session' })
    )
  })

  it('sends X-Dev-Bypass header when auth port returns dev-bypass', async () => {
    const { ipc } = makeIpc()
    const { fetch, calls } = makeFetch({})
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'dev-bypass', secret: 'secret-xyz' }),
      config: baseConfig
    })

    await service.requestAudio({ bookId: 'b', cfiRange: 'c', text: 't', priority: 0 })

    const headers = calls[0].init.headers as Record<string, string>
    expect(headers['X-Dev-Bypass']).toBe('secret-xyz')
    expect(headers['Authorization']).toBeUndefined()
  })

  it('rejects on HTTP 401 with no retries and emits onError', async () => {
    const { ipc } = makeIpc()
    const { fetch, callCount } = makeFetch({ status: 401, errorBody: 'unauthorized' })
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })
    const errHandler = vi.fn()
    service.onError(errHandler)

    await expect(
      service.requestAudio({ bookId: 'b', cfiRange: 'c', text: 't', priority: 0 })
    ).rejects.toThrow('401')

    expect(callCount()).toBe(1)
    expect(errHandler).toHaveBeenCalled()
  })
})
```

- [ ] **Step 2: Run — expect 7 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/service.test.ts
```

Expected: 7 tests pass.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/service.test.ts
git commit -m "test(tts): service propagates auth failure, supports dev-bypass, rejects 401"
```

---

## Task 22: Service — `cancelBookRequests`, `getQueueStatus`, `clearBookCache`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/service.test.ts`

- [ ] **Step 1: Add the remaining method tests**

Append:

```ts
describe('TtsService.cancelBookRequests / getQueueStatus / clearBookCache', () => {
  it('cancelBookRequests rejects all in-flight requests for that book only', async () => {
    const { ipc } = makeIpc()
    const fetch = vi.fn(() => new Promise<Response>(() => {})) // never resolves
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })

    const a = service.requestAudio({ bookId: 'A', cfiRange: 'c1', text: 'x', priority: 0 })
    const b = service.requestAudio({ bookId: 'B', cfiRange: 'c2', text: 'y', priority: 0 })
    await new Promise((r) => setTimeout(r, 0))

    service.cancelBookRequests('A')

    await expect(a).rejects.toThrow('Request cancelled')
    const winner = await Promise.race([
      b.then(() => 'resolved'),
      new Promise<string>((r) => setTimeout(() => r('pending'), 10))
    ])
    expect(winner).toBe('pending')
  })

  it('getQueueStatus returns { pending, isProcessing, active }', () => {
    const { ipc } = makeIpc()
    const { fetch } = makeFetch({})
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })

    const status = service.getQueueStatus()
    expect(status).toEqual({ pending: 0, isProcessing: false, active: 0 })
  })

  it('clearBookCache removes the book directory', async () => {
    const { ipc, files } = makeIpc()
    const { createCache } = await import('./cache')
    const cache = createCache({ ipc, cacheMaxBytes: baseConfig.cacheMaxBytes })
    await cache.saveAudio('book-X', 'cfi-1', new Uint8Array([1]))
    expect([...files.keys()].some((k) => k.includes('/book-X/'))).toBe(true)

    const { fetch } = makeFetch({})
    const service = createTtsService({
      ipc,
      fetch,
      getAuthToken: makeAuth({ kind: 'bearer', token: 't' }),
      config: baseConfig
    })
    await service.clearBookCache('book-X')

    expect([...files.keys()].some((k) => k.includes('/book-X/'))).toBe(false)
  })
})
```

- [ ] **Step 2: Run — expect 10 GREEN**

```bash
pnpm vitest run src/renderer/src/services/tts/service.test.ts
```

Expected: 10 tests pass.

- [ ] **Step 3: Verify typecheck and lint pass**

```bash
pnpm typecheck
pnpm lint
```

Expected: both pass.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/service.test.ts
git commit -m "test(tts): service cancelBookRequests/getQueueStatus/clearBookCache"
```

---

## Task 23: Public exports (`index.ts`)

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/tts/index.ts`

- [ ] **Step 1: Replace the placeholder with re-exports of the public surface only**

Replace the contents of `apps/rishi-electron/src/renderer/src/services/tts/index.ts`:

```ts
export { createTtsService } from './service'
export type {
  AudioRequest,
  AudioReadyEvent,
  AudioErrorEvent,
  AuthHeader,
  QueueStatus,
  TtsConfig,
  TtsIpcChannels,
  TtsService,
  TtsServiceDeps
} from './types'
```

Do **not** export `createCache`, `createQueue`, `fetchAudio`, `TtsTransportError`, or `createEmitter` — those are internals.

- [ ] **Step 2: Verify typecheck still passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Sanity-grep that internals are NOT re-exported**

```bash
grep -nE "createCache|createQueue|fetchAudio|TtsTransportError|createEmitter" src/renderer/src/services/tts/index.ts
```

Expected: no matches.

- [ ] **Step 4: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/tts/index.ts
git commit -m "refactor(tts): export only the public surface (createTtsService + types)"
```

---

## Task 24: Wire in `services/index.ts`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/services/index.ts`

- [ ] **Step 1: Add the lazy `getTtsService()` singleton**

Replace the contents of `apps/rishi-electron/src/renderer/src/services/index.ts` with:

```ts
import { createRagService, type RagService } from './rag'
import { embedSingleText } from '@/modules/embed-fallback'
import { createTtsService, type TtsService, type AuthHeader } from './tts'
import { getAuthToken } from '@/modules/auth'
import config from '@/config.json'

let _rag: RagService | null = null

export function getRagService(): RagService {
  if (!_rag) {
    _rag = createRagService({
      ipc: {
        searchVectors: window.electron.searchVectors,
        getTextFromVectorId: window.electron.getTextFromVectorId,
        searchBookText: window.electron.searchBookText,
        hasVectorsForBook: window.electron.hasVectorsForBook
      },
      embed: embedSingleText
    })
  }
  return _rag
}

let _tts: TtsService | null = null

export function getTtsService(): TtsService {
  if (!_tts) {
    _tts = createTtsService({
      ipc: {
        mkdir: window.electron.mkdir,
        exists: window.electron.exists,
        writeFile: window.electron.writeFile,
        readFile: window.electron.readFile,
        copyFile: window.electron.copyFile,
        removeFile: window.electron.removeFile,
        getDirSize: window.electron.getDirSize,
        getCacheFileStats: window.electron.getCacheFileStats,
        getAppDataPath: window.electron.getAppDataPath
      },
      fetch: globalThis.fetch.bind(globalThis),
      getAuthToken: async (): Promise<AuthHeader> => {
        const token = await getAuthToken()
        if (token) return { kind: 'bearer', token }
        const secret = await window.electron.getDevBypassSecret()
        if (secret) return { kind: 'dev-bypass', secret }
        throw new Error('Not authenticated — sign in to use text-to-speech')
      },
      config: {
        audioWorkerUrl: config.production.audio_worker_url,
        cacheMaxBytes: 500 * 1024 * 1024,
        maxConcurrent: 8
      }
    })
  }
  return _tts
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If any `window.electron.*` method is reported missing on the typed interface, check `apps/rishi-electron/src/preload/types.ts` — all 9 methods listed must already be there (they back the current `ttsCache.ts`).

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/services/index.ts
git commit -m "feat(tts): wire production getTtsService singleton

Composes window.electron.* (ipc), globalThis.fetch (transport), the
existing auth module + dev-bypass secret (returning discriminated
AuthHeader), and config.production knobs at the boundary."
```

---

## Task 25: Migrate `usePlayerMachine` to `getTtsService`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`

- [ ] **Step 1: Replace the import**

At the top of `apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts`, replace:

```ts
import { ttsService } from '@/modules/ttsService'
```

with:

```ts
import { getTtsService } from '@/services'
```

- [ ] **Step 2: Update the 5 call sites in the file**

Replace each of the following 5 patterns:

Around line 58:
```ts
              void ttsService
                .requestAudio(bookId, p.index, p.text, 0)
```
→
```ts
              void getTtsService()
                .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
```

Around line 76 (same as above with `p` from the next-page loop):
```ts
              void ttsService
                .requestAudio(bookId, p.index, p.text, 0)
```
→
```ts
              void getTtsService()
                .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
```

Around line 123 (the loading-state primary fetch):
```ts
          ttsService
            .requestAudio(ctx.bookId, paragraph.index, paragraph.text, 1)
```
→
```ts
          getTtsService()
            .requestAudio({
              bookId: ctx.bookId,
              cfiRange: paragraph.index,
              text: paragraph.text,
              priority: 1
            })
```

Around line 326 (`cleanupAudio` helper):
```ts
  ttsService.clearQueue()
```
→
```ts
  // The service has no nuclear "clearQueue" — but per the spec, the caller's
  // intent here is "cancel any pending work tied to whatever book was playing".
  // The audio element no longer has a src after the lines above, so we don't
  // know the bookId. Use the only valid migration: drop the call. Player
  // teardown's bookId-scoped cancellation happens in the useEffect cleanup
  // already by the consumer's bookId.
```

Around lines 343 and 351 (`schedulePrefetch`):
```ts
        void ttsService
          .requestAudio(bookId, currentParagraphs[idx].index, currentParagraphs[idx].text, 0)
```
→
```ts
        void getTtsService()
          .requestAudio({
            bookId,
            cfiRange: currentParagraphs[idx].index,
            text: currentParagraphs[idx].text,
            priority: 0
          })
```

and:

```ts
        void ttsService
          .requestAudio(bookId, p.index, p.text, 0)
```
→
```ts
        void getTtsService()
          .requestAudio({ bookId, cfiRange: p.index, text: p.text, priority: 0 })
```

- [ ] **Step 3: Add a `cancelBookRequests` call in the useEffect cleanup**

Find the `return () => { ... }` cleanup block inside the `useEffect` (around line 268-282). Add **at the top** of the cleanup function (before the existing `actor.send({ type: 'CLEANUP' })`):

```ts
      getTtsService().cancelBookRequests(bookId)
```

This restores the queue-clearing semantics that `clearQueue()` used to provide, but scoped to the book the player was working on.

- [ ] **Step 4: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 5: Run the player tests**

```bash
pnpm vitest run src/renderer/src/machines/playerMachine.test.ts
```

Expected: existing tests pass. If a test mocked `ttsService` directly it will fail to find the export; update it to mock `@/services` instead, returning a `getTtsService` shim.

- [ ] **Step 6: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/hooks/usePlayerMachine.ts
git commit -m "refactor(tts): migrate usePlayerMachine to getTtsService

5 requestAudio call sites now pass the AudioRequest object form.
clearQueue() is replaced by cancelBookRequests(bookId) in the
useEffect cleanup, scoping cancellation correctly to the active book."
```

---

## Task 26: Migrate `ipc_handel_functions.requestTTSAudio`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/ipc_handel_functions.ts`

The wrapper exists to call `captureError` around `ttsService.requestAudio`. Since `ttsPrefetch` is the only remaining caller (Task 27), and the new service does not auto-capture to Sentry, we keep the wrapper as a backward-compat surface that captures Sentry context before re-throwing.

- [ ] **Step 1: Replace the wrapper body**

Replace the contents of `apps/rishi-electron/src/renderer/src/modules/ipc_handel_functions.ts`:

```ts
/**
 * Backward-compat wrapper around getTtsService().requestAudio.
 * Keeps Sentry context capture around the call for prefetch's
 * fire-and-forget invocations. New callers should use getTtsService()
 * directly.
 */
import { getTtsService } from '@/services'
import { captureError } from '../utils/sentry'

export const requestTTSAudio = async (
  bookId: string,
  cfiRange: string,
  text: string,
  priority = 0
): Promise<string> => {
  try {
    return await getTtsService().requestAudio({ bookId, cfiRange, text, priority })
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error)
    console.error(`TTS request failed [${bookId}]: ${msg}`)
    captureError(error, {
      operation: 'tts-request',
      step: 'requestTTSAudio',
      bookId,
      cfiRange,
      textLength: text.length,
      priority
    })
    throw error
  }
}
```

- [ ] **Step 2: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 3: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/modules/ipc_handel_functions.ts
git commit -m "refactor(tts): point requestTTSAudio wrapper at getTtsService

Keeps the Sentry-instrumented wrapper for prefetch's fire-and-forget
flows. Body is a one-line delegation to getTtsService().requestAudio."
```

---

## Task 27: Migrate `ttsPrefetch` to use the wrapper-or-service

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/modules/ttsPrefetch.ts`

The wrapper in Task 26 already points at the service, so `ttsPrefetch` does not need to change its import. However, we want to confirm it still works end-to-end and remove any stale doc-comments referencing the old internals.

- [ ] **Step 1: Read the file and confirm `requestTTSAudio` is still the only TTS-related import**

```bash
grep -n "import" /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron/src/renderer/src/modules/ttsPrefetch.ts
```

Expected: imports `requestTTSAudio` from `./ipc_handel_functions`, plus `md5` and book-data helpers. No imports of `ttsService` / `ttsQueue` / `ttsCache`.

- [ ] **Step 2: Run all tts-related tests to confirm nothing regressed**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm vitest run src/renderer/src/services/tts/
```

Expected: all green (cache, transport, queue, service, emitter).

- [ ] **Step 3: No commit (no code changed). Move on.**

If desired, this task can be skipped entirely; it exists only as a verification step.

---

## Task 28: Migrate `stateDump`

**Files:**
- Modify: `apps/rishi-electron/src/renderer/src/utils/stateDump.ts`

- [ ] **Step 1: Replace the two old imports with one**

At the top of `apps/rishi-electron/src/renderer/src/utils/stateDump.ts`, replace:

```ts
import { ttsQueue } from '../modules/ttsQueue'
import { ttsService } from '../modules/ttsService'
```

with:

```ts
import { getTtsService } from '@/services'
```

- [ ] **Step 2: Replace the queue snapshot line**

Replace:

```ts
  const queueStatus = ttsQueue.getQueueStatus()
```

with:

```ts
  const queueStatus = getTtsService().getQueueStatus()
```

- [ ] **Step 3: Drop the `ttsService` block (no longer reachable — the service doesn't expose internals)**

Replace the block:

```ts
    ttsQueue: queueStatus,
    ttsService: {
      activeRequests: (ttsService as any).activeRequests?.size ?? 0,
      pendingListeners: (ttsService as any).pendingListeners?.size ?? 0
    },
```

with:

```ts
    tts: queueStatus,
```

The `activeRequests`/`pendingListeners` counters were reaching into internals via `as any`; the service replaces both with its built-in dedup. `queueStatus.active` carries the same diagnostic signal.

- [ ] **Step 4: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git add apps/rishi-electron/src/renderer/src/utils/stateDump.ts
git commit -m "refactor(tts): point stateDump at getTtsService().getQueueStatus

Drops the (ttsService as any).activeRequests/pendingListeners probes —
the new service consolidates dedup so queueStatus.active is the single
diagnostic signal."
```

---

## Task 29: Delete old modules and their tests

**Files:**
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsService.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsQueue.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsCache.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsService.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsQueue.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsCache.test.ts`
- Delete: `apps/rishi-electron/src/renderer/src/modules/ttsPrefetch.ts` (it moves out — see note)
- Delete: `apps/rishi-electron/src/renderer/src/modules/ipc_handles.ts` (only contains `TTS_EVENTS` / `TTSQueueEvents` enums — replaced by service internals)

**Note on ttsPrefetch:** Per the spec, `ttsPrefetch.ts` migrates to `services/tts/prefetch.ts`. We keep it at `@/modules/ttsPrefetch` for now — the spec's "Open question 1" allowed either placement and the import in `FileComponent.tsx` is the only consumer. Moving the file is optional cleanup; *do not* delete it here.

- [ ] **Step 1: Confirm no remaining imports of the old names**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
grep -rnE "from '@/modules/ttsService'|from '@/modules/ttsQueue'|from '@/modules/ttsCache'|from '.*\\./ttsService'|from '.*\\./ttsQueue'|from '.*\\./ttsCache'|from '@/modules/ipc_handles'|from '.*\\./ipc_handles'" src/
```

Expected: only matches in `apps/rishi-electron/src/renderer/src/modules/ttsService.ts` itself (the file we're about to delete imports `./ipc_handles`, `./ttsQueue`, `./ttsCache`). No imports anywhere else.

If any external caller still imports any of the old paths, return to the relevant migration task (25–28) and complete it before continuing.

- [ ] **Step 2: Delete the 7 files**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git rm apps/rishi-electron/src/renderer/src/modules/ttsService.ts \
       apps/rishi-electron/src/renderer/src/modules/ttsQueue.ts \
       apps/rishi-electron/src/renderer/src/modules/ttsCache.ts \
       apps/rishi-electron/src/renderer/src/modules/ttsService.test.ts \
       apps/rishi-electron/src/renderer/src/modules/ttsQueue.test.ts \
       apps/rishi-electron/src/renderer/src/modules/ttsCache.test.ts \
       apps/rishi-electron/src/renderer/src/modules/ipc_handles.ts
```

- [ ] **Step 3: Verify typecheck passes**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
```

Expected: passes. If any reference to `TTS_EVENTS`, `TTSQueueEvents`, `TTSService`, `TTSQueue`, or `TTSCache` is reported missing, locate the caller and fix the import (it should be a leftover from a migration task — go back and update it).

- [ ] **Step 4: Run the test suite**

```bash
pnpm test
```

Expected: all tests pass — including the new TTS service tests under `src/renderer/src/services/tts/`. None of the deleted test files run.

- [ ] **Step 5: Commit**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git commit -m "refactor(tts): delete legacy ttsService/ttsQueue/ttsCache + ipc_handles

7 files removed (3 modules, 3 tests, 1 enum file). Per meta-spec's
no-shims rule: one PR, one source of truth. All TTS surfaces flow
through getTtsService()."
```

---

## Task 30: Final verification & PR

**Files:** none (verification only).

- [ ] **Step 1: Run typecheck, lint, and tests across the app**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo/apps/rishi-electron
pnpm typecheck
pnpm lint
pnpm test
```

Expected: all three pass. If any fail:
- **Typecheck failures:** missed import or type mismatch from migration — fix in a new commit (`fix(tts): …`).
- **Lint failures:** usually unused-import warnings from removed `ttsService` / `ttsQueue` / `ttsCache` imports — fix in a new commit.
- **Test failures:** investigate; do not silence.

- [ ] **Step 2: Sanity-check `services/index.ts` is the only wiring site**

```bash
grep -rn "createTtsService" src/
```

Expected: matches only in `src/renderer/src/services/tts/service.ts` (definition), `src/renderer/src/services/tts/index.ts` (re-export), `src/renderer/src/services/index.ts` (wiring), and `src/renderer/src/services/tts/service.test.ts` (test usage). No other call sites.

- [ ] **Step 3: Sanity-check internals are not externally imported**

```bash
grep -rnE "from '@/services/tts/cache'|from '@/services/tts/queue'|from '@/services/tts/transport'|from '@/services/tts/emitter'" src/
```

Expected: no matches outside `src/renderer/src/services/tts/`.

- [ ] **Step 4: Push the branch and open the PR**

```bash
cd /Users/faridmatovu/projects/rishi-monorepo
git push -u origin refactor/tts-service
gh pr create --title "refactor(tts): collapse TTS quartet into services/tts deep module" --body "$(cat <<'EOF'
## Summary
- New \`TtsService\` at \`apps/rishi-electron/src/renderer/src/services/tts/\` collapses \`ttsService\` + \`ttsQueue\` + \`ttsCache\` + \`ttsPrefetch\` consumers behind a typed factory boundary.
- 4 ports injected at the wiring site: \`ipc\`, \`fetch\`, \`getAuthToken\` (discriminated \`AuthHeader\` union), and \`config\`. EventEmitter3 is now an internal detail — public surface is \`onAudioReady\` / \`onError\` returning unsubscribe handles.
- Dedup is single-point inside the queue (the old dual-dedup across \`ttsService\` + \`ttsQueue\` collapses).
- Callers migrated: \`usePlayerMachine\`, \`stateDump\`, \`ipc_handel_functions\` (now a thin Sentry-instrumented delegate). \`ttsPrefetch\` unchanged — its only TTS call already goes through \`requestTTSAudio\`.
- 7 legacy files deleted (3 modules + 3 tests + 1 enum file). No shims.
- TDD throughout: red → green → commit per behavior.

Spec: \`docs/superpowers/specs/2026-05-11-tts-service-design.md\`
Meta-spec: \`docs/superpowers/specs/2026-05-11-services-and-effect-adoption-design.md\` (Wave 1, service 3 of 6)

## Test plan
- [ ] \`pnpm typecheck\` clean
- [ ] \`pnpm lint\` clean
- [ ] \`pnpm test\` — emitter (3), cache (11), transport (6), queue (6), service (10) = 36 new boundary tests pass; no regressions
- [ ] Manual: open a book, press play, verify TTS audio plays through the singleton service
- [ ] Manual: scrub paragraphs forward fast — verify cancellation cleanly drops in-flight requests
- [ ] Manual: turn off network, hit play, verify the error event fires and the player shows the failure
- [ ] Manual: sign out and back in with the dev-bypass secret env var set — verify the X-Dev-Bypass header path works
- [ ] Manual: trigger library prefetch (open library page), verify low-priority background requests resolve and audio is cached
EOF
)"
```

---

## Summary

After all tasks complete:
- **~30 commits** on the `refactor/tts-service` branch.
- **36 new boundary tests** at `src/renderer/src/services/tts/{emitter,cache,transport,queue,service}.test.ts` — all using hand-rolled adapter helpers, no \`vi.mock\`, no \`vi.resetModules\`.
- **Net diff (approximate):** +1100 lines added (service + tests + types + wiring), -1100 lines removed (old quartet + their 3 test files + the \`ipc_handles\` enum file). Roughly neutral.
- **No internals exported.** The public surface from \`services/tts/index.ts\` is \`createTtsService\` + the 9 public types. Cache, queue, transport, emitter stay strictly internal.
- **Dedup is single-point** at the queue layer. The old \`pendingListeners\` map and second listener-timeout in \`ttsService\` are gone.
- **Auth is a port.** The dev-bypass logic moves to the wiring site, behind the discriminated \`AuthHeader\` union.
- **Config is a port.** Production reads \`config.production.audio_worker_url\` + literal cache/concurrency knobs; tests pass a literal \`TtsConfig\`.
- All 12 boundary scenarios from the spec's Test Strategy are covered across the 36 tests (cache hit / miss, both keys, dedup, retry, cancel, auth, dev-bypass, 401, subscription delivery + unsubscribe, queueStatus).
