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
})
