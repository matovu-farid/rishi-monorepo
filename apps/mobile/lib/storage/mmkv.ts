/**
 * MMKV-backed persistence shim.
 *
 * Exposes:
 *   - `createStorage(bucketId, opts?)` — a tiny key/value adapter scoped to a
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
 *
 * Data hardening:
 *   - DAT-005 (#118): every bucket carries a `__schema_version__` sentinel
 *     so future key-shape changes can run a migration via the optional
 *     `migrate(from, to, bucket)` hook on createStorage.
 *   - DAT-020 (#132): `clear()` is two-phase. We write a
 *     `__clear_in_progress__` sentinel BEFORE removing user keys; if the
 *     process dies mid-loop, the next `createStorage()` call detects the
 *     sentinel and finishes the clear. `_clearAll()` (full backend wipe)
 *     uses MMKV's native `clearAll()` so the whole file is reset
 *     atomically by the binding.
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

/**
 * Current bucket schema version. Bump this when the on-disk key shape
 * for a bucket changes and a migration is required. The new version is
 * written by `createStorage()` on first construction; older readers see
 * the sentinel and pass it to the migrator hook.
 *
 * Migration policy:
 *   - v1 — initial. Sentinel-less buckets created before the DAT-005 fix
 *     are treated as v0 so a `migrate(0, 1, bucket)` call lets the
 *     consumer rewrite legacy keys before any read happens.
 */
export const CURRENT_SCHEMA_VERSION = 1

/** Reserved internal keys — must NOT collide with user-defined keys. */
const SCHEMA_VERSION_KEY = '__schema_version__'
const CLEAR_IN_PROGRESS_KEY = '__clear_in_progress__'

export interface StorageBucket {
  getItem(key: string): string | null
  setItem(key: string, value: string): void
  removeItem(key: string): void
  /** Drop every key in this bucket. Useful for tests / "sign-out wipe". */
  clear(): void
  /** Current persisted schema version for this bucket. */
  getSchemaVersion(): number
}

export interface CreateStorageOptions {
  /**
   * Called when the on-disk schema version for this bucket is older than
   * {@link CURRENT_SCHEMA_VERSION}. Implementations should rewrite legacy
   * keys to the new shape. After the migrator returns, the sentinel is
   * bumped to {@link CURRENT_SCHEMA_VERSION}. Errors in the migrator are
   * intentionally NOT swallowed — better to crash than persist a half-
   * migrated bucket.
   */
  migrate?: (fromVersion: number, toVersion: number, bucket: StorageBucket) => void
}

function isInternalKey(suffix: string): boolean {
  return suffix === SCHEMA_VERSION_KEY || suffix === CLEAR_IN_PROGRESS_KEY
}

export function createStorage(
  bucketId: string,
  opts: CreateStorageOptions = {},
): StorageBucket {
  const prefix = `${bucketId}:`

  // ── Helper: scoped remove for every user key under this prefix.
  // Used by both bucket.clear() and the interrupted-clear recovery path.
  const wipeUserKeys = (): void => {
    for (const k of backend.getAllKeys()) {
      if (!k.startsWith(prefix)) continue
      const suffix = k.slice(prefix.length)
      if (isInternalKey(suffix)) continue
      backend.remove(k)
    }
  }

  // DAT-020 (#132): if a previous clear() crashed mid-iteration, finish it
  // BEFORE the consumer can observe stale keys. This is the recovery half of
  // the two-phase clear protocol.
  if (backend.getString(prefix + CLEAR_IN_PROGRESS_KEY) != null) {
    wipeUserKeys()
    backend.remove(prefix + CLEAR_IN_PROGRESS_KEY)
  }

  // DAT-005 (#118): read schema-version sentinel, run migrator if outdated.
  const storedRaw = backend.getString(prefix + SCHEMA_VERSION_KEY)
  let storedVersion = storedRaw == null ? 0 : Number.parseInt(storedRaw, 10)
  if (!Number.isFinite(storedVersion) || storedVersion < 0) storedVersion = 0

  const bucket: StorageBucket = {
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
      // DAT-020 (#132): two-phase clear so a process crash mid-iteration
      // can be detected and finished by the next createStorage() call.
      //   Phase 1: write the in-progress sentinel.
      //   Phase 2: remove every user key under this prefix.
      //   Phase 3: clear the sentinel.
      // The __schema_version__ key is intentionally preserved — clear()
      // is a data wipe, not a schema rollback.
      backend.set(prefix + CLEAR_IN_PROGRESS_KEY, '1')
      wipeUserKeys()
      backend.remove(prefix + CLEAR_IN_PROGRESS_KEY)
    },
    getSchemaVersion() {
      const v = backend.getString(prefix + SCHEMA_VERSION_KEY)
      const n = v == null ? 0 : Number.parseInt(v, 10)
      return Number.isFinite(n) ? n : 0
    },
  }

  if (storedVersion < CURRENT_SCHEMA_VERSION) {
    if (opts.migrate) {
      opts.migrate(storedVersion, CURRENT_SCHEMA_VERSION, bucket)
    }
    backend.set(prefix + SCHEMA_VERSION_KEY, String(CURRENT_SCHEMA_VERSION))
  }

  return bucket
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
 * DAT-020 (#132): uses the binding's native `clearAll()` (one atomic
 * call) so a crash cannot leave a half-wiped backend. Per-bucket scoped
 * clears use the two-phase protocol in `bucket.clear()`.
 *
 * @internal
 */
export function _clearAll(): void {
  backend.clearAll()
}
