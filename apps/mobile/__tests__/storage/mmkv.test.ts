/**
 * Tests for the MMKV-backed Zustand persist adapter.
 *
 * The real `react-native-mmkv` module is a JSI native binding that does NOT
 * load under plain Node / ts-jest. We mock the module here so the adapter
 * code paths are exercised without a RN runtime. The fallback in-memory
 * backend is also tested independently.
 */

// ── Mock react-native-mmkv ────────────────────────────────────────────────────
type StoreBackend = { [k: string]: string | number | boolean | ArrayBuffer }

function buildFakeMMKV(initial: StoreBackend = {}) {
  const store: StoreBackend = { ...initial }
  return {
    id: 'fake',
    get length() {
      return Object.keys(store).length
    },
    get size() {
      return 0
    },
    get byteSize() {
      return 0
    },
    get isReadOnly() {
      return false
    },
    get isEncrypted() {
      return false
    },
    set: (key: string, value: string | number | boolean | ArrayBuffer) => {
      store[key] = value
    },
    getString: (key: string): string | undefined => {
      const v = store[key]
      return typeof v === 'string' ? v : undefined
    },
    getNumber: (_key: string): number | undefined => undefined,
    getBoolean: (_key: string): boolean | undefined => undefined,
    getBuffer: (_key: string): ArrayBuffer | undefined => undefined,
    contains: (key: string) => key in store,
    remove: (key: string) => {
      if (key in store) {
        delete store[key]
        return true
      }
      return false
    },
    getAllKeys: () => Object.keys(store),
    clearAll: () => {
      for (const k of Object.keys(store)) delete store[k]
    },
    recrypt: (_k: string | undefined) => undefined,
    encrypt: () => undefined,
    decrypt: () => undefined,
    trim: () => undefined,
    addOnValueChangedListener: () => ({ remove: () => undefined }),
    importAllFrom: () => 0,
  }
}

let currentFake: ReturnType<typeof buildFakeMMKV>

jest.mock('react-native-mmkv', () => ({
  createMMKV: (_config: unknown) => currentFake,
}))

describe('mmkv storage adapter', () => {
  beforeEach(() => {
    jest.resetModules()
    currentFake = buildFakeMMKV()
  })

  describe('createStorage()', () => {
    it('exposes get/set/remove against the real MMKV when available', () => {
      const { createStorage } = require('@/lib/storage/mmkv')
      const storage = createStorage('test-bucket')
      storage.setItem('k1', 'hello')
      expect(storage.getItem('k1')).toBe('hello')
      // Bucket prefixing: the underlying backend should see the namespaced key.
      expect(currentFake.getString('test-bucket:k1')).toBe('hello')
      storage.removeItem('k1')
      expect(storage.getItem('k1')).toBeNull()
    })

    it('returns null for missing keys (Zustand persist contract)', () => {
      const { createStorage } = require('@/lib/storage/mmkv')
      const storage = createStorage('test-bucket')
      expect(storage.getItem('missing')).toBeNull()
    })

    it('isolates buckets — two storages with different ids do not share keys', () => {
      // The fake we built above is a singleton, so the bucket isolation is
      // actually enforced inside the adapter via the namespace prefix. Verify
      // both writes survive.
      const { createStorage } = require('@/lib/storage/mmkv')
      const a = createStorage('bucket-a')
      const b = createStorage('bucket-b')
      a.setItem('shared-key', 'A')
      b.setItem('shared-key', 'B')
      expect(a.getItem('shared-key')).toBe('A')
      expect(b.getItem('shared-key')).toBe('B')
    })
  })

  describe('persistMMKV (Zustand StateStorage adapter)', () => {
    it('is a StateStorage object with getItem/setItem/removeItem', () => {
      const { persistMMKV } = require('@/lib/storage/mmkv')
      expect(typeof persistMMKV.getItem).toBe('function')
      expect(typeof persistMMKV.setItem).toBe('function')
      expect(typeof persistMMKV.removeItem).toBe('function')
    })

    it('round-trips JSON-shaped values for Zustand persist', () => {
      const { persistMMKV } = require('@/lib/storage/mmkv')
      const payload = JSON.stringify({ state: { count: 7 }, version: 0 })
      persistMMKV.setItem('zustand:prefs', payload)
      expect(persistMMKV.getItem('zustand:prefs')).toBe(payload)
      persistMMKV.removeItem('zustand:prefs')
      expect(persistMMKV.getItem('zustand:prefs')).toBeNull()
    })
  })

  describe('in-memory fallback', () => {
    afterEach(() => {
      // `jest.doMock(..., throw)` persists across tests, so without an
      // explicit restore the next suite's `createMMKV()` call would also
      // throw and silently drop to the in-memory fallback. Restore the
      // top-of-file mock that returns `currentFake`.
      jest.resetModules()
      jest.doMock('react-native-mmkv', () => ({
        createMMKV: (_config: unknown) => currentFake,
      }))
    })

    it('falls back to an in-memory Map when MMKV creation throws', () => {
      jest.resetModules()
      // Force the next createMMKV() call to throw — simulates Node / unsupported env
      jest.doMock('react-native-mmkv', () => ({
        createMMKV: () => {
          throw new Error('No JSI runtime')
        },
      }))
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage } = require('@/lib/storage/mmkv')
      const storage = createStorage('fallback-bucket')
      storage.setItem('k', 'v')
      expect(storage.getItem('k')).toBe('v')
      storage.removeItem('k')
      expect(storage.getItem('k')).toBeNull()
    })
  })

  // DAT-005 (#118): every bucket must carry a `schemaVersion` sentinel so
  // future key-shape changes don't silently corrupt stored state. A bucket
  // built without a recorded version writes the current default on first
  // touch; a bucket that finds an older version on disk should be able to
  // run a migrator before the consumer sees the data.
  describe('DAT-005 — bucket schema-version sentinel', () => {
    it('writes the schemaVersion sentinel on first construction', () => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage, CURRENT_SCHEMA_VERSION } = require('@/lib/storage/mmkv')
      createStorage('versioned-bucket')
      // Sentinel persists under the bucket prefix with a reserved key.
      expect(currentFake.getString('versioned-bucket:__schema_version__')).toBe(
        String(CURRENT_SCHEMA_VERSION),
      )
    })

    it('exposes the recorded schemaVersion via getSchemaVersion()', () => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage, CURRENT_SCHEMA_VERSION } = require('@/lib/storage/mmkv')
      const bucket = createStorage('versioned-bucket-2')
      expect(typeof bucket.getSchemaVersion).toBe('function')
      expect(bucket.getSchemaVersion()).toBe(CURRENT_SCHEMA_VERSION)
    })

    it('runs the provided migrator when the on-disk version is older', () => {
      // Pre-seed an older version sentinel BEFORE the module loads so the
      // captured backend sees the legacy data.
      currentFake.set('migrate-bucket:__schema_version__', '0')
      currentFake.set('migrate-bucket:legacy-key', 'legacy-value')

      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage, CURRENT_SCHEMA_VERSION } = require('@/lib/storage/mmkv')
      const migrate = jest.fn((_from: number, _to: number, _bucket: unknown) => {
        // A real migrator would rewrite legacy keys. We just observe call.
      })
      const bucket = createStorage('migrate-bucket', { migrate })
      expect(migrate).toHaveBeenCalledTimes(1)
      expect(migrate).toHaveBeenCalledWith(0, CURRENT_SCHEMA_VERSION, bucket)
      // After migration the sentinel is bumped to the current version.
      expect(currentFake.getString('migrate-bucket:__schema_version__')).toBe(
        String(CURRENT_SCHEMA_VERSION),
      )
    })

    it('does NOT run the migrator when the on-disk version matches', () => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage, CURRENT_SCHEMA_VERSION } = require('@/lib/storage/mmkv')
      // Pre-seed the current version. Module is already loaded but
      // createStorage reads on every call.
      currentFake.set(
        'same-bucket:__schema_version__',
        String(CURRENT_SCHEMA_VERSION),
      )
      const migrate = jest.fn()
      createStorage('same-bucket', { migrate })
      expect(migrate).not.toHaveBeenCalled()
    })

    it('preserves the sentinel across bucket.clear() (clear() is a data wipe, not a schema rollback)', () => {
      // eslint-disable-next-line @typescript-eslint/no-require-imports
      const { createStorage, CURRENT_SCHEMA_VERSION } = require('@/lib/storage/mmkv')
      const bucket = createStorage('cleared-bucket')
      bucket.setItem('a', '1')
      bucket.setItem('b', '2')
      bucket.clear()
      // User data gone…
      expect(bucket.getItem('a')).toBeNull()
      expect(bucket.getItem('b')).toBeNull()
      // …but the schema version stays so re-population doesn't trigger a
      // ghost migration on the next bucket construction.
      expect(currentFake.getString('cleared-bucket:__schema_version__')).toBe(
        String(CURRENT_SCHEMA_VERSION),
      )
    })
  })
})
