/**
 * MMKV-backed persistence shim.
 *
 * Exposes:
 *   - `createStorage(bucketId)` — a tiny key/value adapter scoped to a
 *     namespace prefix. Used by stores that just need a synchronous
 *     get/set/remove (e.g. `tutorialStore`'s hints map).
 *   - `persistMMKV` — a Zustand `StateStorage` adapter compatible with
 *     the `persist(...)` middleware. Drop-in replacement for the
 *     electron `createJSONStorage(() => localStorage)` pattern.
 *
 * Implementation notes:
 *   - `react-native-mmkv` v4 ships a functional `createMMKV(config)` factory.
 *     We call it once at module load; if it throws (e.g. running under
 *     plain Node in Jest with no JSI binding), we fall back to an
 *     in-memory `Map` so unit tests and SSR don't crash.
 *   - All bucketed keys are stored in a single MMKV instance prefixed
 *     with `${bucketId}:` so multiple "logical" stores share one
 *     on-disk file. This matches MMKV best practice (one file per app
 *     unless you genuinely need multi-process isolation).
 */
import { createMMKV } from 'react-native-mmkv'

// ── Minimal MMKV-like surface we actually use ─────────────────────────────────
interface MMKVLike {
  set(key: string, value: string): void
  getString(key: string): string | undefined
  remove(key: string): boolean
  getAllKeys(): string[]
  clearAll(): void
}

function buildMemoryBackend(): MMKVLike {
  const store = new Map<string, string>()
  return {
    set(key, value) {
      store.set(key, value)
    },
    getString(key) {
      return store.get(key)
    },
    remove(key) {
      return store.delete(key)
    },
    getAllKeys() {
      return Array.from(store.keys())
    },
    clearAll() {
      store.clear()
    },
  }
}

// Construct the default MMKV instance at module load. If the JSI binding
// is unavailable (Node, Jest without RN host, web SSR), drop to memory.
let backend: MMKVLike
try {
  // createMMKV requires an `id`; everything we store lives in one
  // shared bucket keyed by `${bucketId}:${userKey}`.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const real = createMMKV({ id: 'rishi.mobile.default' } as any) as unknown as MMKVLike
  // Smoke-test that the binding actually returned something usable. The
  // call above may *return* a stub on mocked environments — we trust the
  // mock to behave; for real RN runtime this is the production MMKV.
  if (real == null || typeof real.set !== 'function') {
    backend = buildMemoryBackend()
  } else {
    backend = real
  }
} catch {
  backend = buildMemoryBackend()
}

// ── Public bucket adapter ─────────────────────────────────────────────────────
export interface StorageBucket {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
  /** Drop every key in this bucket. Useful for tests / "sign-out wipe". */
  clear(): void
}

export function createStorage(bucketId: string): StorageBucket {
  const prefix = `${bucketId}:`
  return {
    getItem(key) {
      const v = backend.getString(prefix + key)
      return v ?? null
    },
    setItem(key, value) {
      backend.set(prefix + key, value)
    },
    removeItem(key) {
      backend.remove(prefix + key)
    },
    clear() {
      for (const k of backend.getAllKeys()) {
        if (k.startsWith(prefix)) backend.remove(k)
      }
    },
  }
}

// ── Zustand `persist` middleware adapter ─────────────────────────────────────
//
// Zustand's `StateStorage` interface allows sync OR async return values.
// MMKV is sync, so we return sync values directly — `persist(...)` accepts
// this.
//
// The default bucket id is `rishi.mobile` so existing electron `persist`
// configs that read/write a single key like `"zustand:prefs"` map to
// `rishi.mobile:zustand:prefs` on disk without collision.
const defaultBucket = createStorage('rishi.mobile')

export const persistMMKV = {
  getItem: (key: string): string | null => defaultBucket.getItem(key),
  setItem: (key: string, value: string): void => defaultBucket.setItem(key, value),
  removeItem: (key: string): void => defaultBucket.removeItem(key),
}

/**
 * Test helper: drop every key the storage has written. Production code
 * should not call this — use the `clear()` method on a bucket returned
 * from `createStorage()` for scoped wipes.
 *
 * @internal
 */
export function _clearAll(): void {
  backend.clearAll()
}
