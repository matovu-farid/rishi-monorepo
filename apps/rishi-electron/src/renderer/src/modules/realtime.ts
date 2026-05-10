import { getRealtimeClientSecret } from '@/lib/api'

const KEY_TTL_MS = 9 * 60 * 1000
let _cachedKey: string | null = null
let _cachedKeyTime = 0
let _prefetchPromise: Promise<string> | null = null

export async function getOrFetchKey(): Promise<string> {
  if (_cachedKey && Date.now() - _cachedKeyTime < KEY_TTL_MS) {
    return _cachedKey
  }
  if (_prefetchPromise) return _prefetchPromise
  _prefetchPromise = getRealtimeClientSecret()
    .then((key) => {
      _cachedKey = key
      _cachedKeyTime = Date.now()
      _prefetchPromise = null
      return key
    })
    .catch((err) => {
      _prefetchPromise = null
      throw err
    })
  return _prefetchPromise
}

export function prefetchRealtimeKey() {
  void getOrFetchKey()
}
