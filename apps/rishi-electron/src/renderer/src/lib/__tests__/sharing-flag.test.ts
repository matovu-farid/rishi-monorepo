import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'

// happy-dom binds Storage methods onto the localStorage instance via a Proxy
// (see node_modules/happy-dom/lib/storage/Storage.js — ClassMethodBinder),
// so patching Storage.prototype.getItem does not affect localStorage.getItem.
// Spy on the instance method instead. (Deviation from plan note: "augment
// with localStorage shim".)

describe('isSharingEnabled', () => {
  let getItemSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    getItemSpy = vi.spyOn(window.localStorage, 'getItem').mockReturnValue(null)
  })

  afterEach(() => {
    getItemSpy.mockRestore()
    vi.resetModules()
    vi.unstubAllEnvs()
  })

  it('returns false when build flag absent and localStorage not set', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '')
    const { isSharingEnabled } = await import('../sharing-flag')
    expect(isSharingEnabled()).toBe(false)
  })

  it('returns true when VITE_SHARING_ENABLED=1', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    const { isSharingEnabled } = await import('../sharing-flag')
    expect(isSharingEnabled()).toBe(true)
  })

  it('returns true when localStorage override is "1" even if build flag absent', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '')
    getItemSpy.mockReturnValue('1')
    const { isSharingEnabled } = await import('../sharing-flag')
    expect(isSharingEnabled()).toBe(true)
  })

  it('returns false when localStorage override is "0"', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '')
    getItemSpy.mockReturnValue('0')
    const { isSharingEnabled } = await import('../sharing-flag')
    expect(isSharingEnabled()).toBe(false)
  })
})

describe('isSharingEnabledForUser', () => {
  let getItemSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    getItemSpy = vi.spyOn(window.localStorage, 'getItem').mockReturnValue(null)
  })

  afterEach(() => {
    getItemSpy.mockRestore()
    vi.resetModules()
    vi.unstubAllEnvs()
  })

  it('returns false when isSharingEnabled() is false regardless of pct or userId', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '100')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    expect(isSharingEnabledForUser('user-abc')).toBe(false)
    expect(isSharingEnabledForUser('user-xyz')).toBe(false)
  })

  it('returns true when pct >= 100 and feature is enabled', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '100')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    expect(isSharingEnabledForUser('user-abc')).toBe(true)
    expect(isSharingEnabledForUser('different-user')).toBe(true)
  })

  it('returns false for all users when pct = 0 even if enabled', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '0')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    expect(isSharingEnabledForUser('user-abc')).toBe(false)
    expect(isSharingEnabledForUser('another')).toBe(false)
  })

  it('defaults to pct=100 when VITE_SHARING_ROLLOUT_PCT is unset/empty', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    expect(isSharingEnabledForUser('user-abc')).toBe(true)
  })

  it('is deterministic: same userId yields the same result across calls', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '37')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    const first = isSharingEnabledForUser('user-deterministic-123')
    for (let i = 0; i < 20; i++) {
      expect(isSharingEnabledForUser('user-deterministic-123')).toBe(first)
    }
  })

  it('distributes roughly to pct (50% +/- 10%) across many userIds', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '50')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    let hits = 0
    const N = 1000
    for (let i = 0; i < N; i++) {
      // Mix the index into a longer string so the hash sees varied byte spread.
      const id = `user-${i}-${Math.random().toString(36).slice(2)}`
      if (isSharingEnabledForUser(id)) hits++
    }
    const ratio = hits / N
    expect(ratio).toBeGreaterThan(0.4)
    expect(ratio).toBeLessThan(0.6)
  })

  it('produces a mix of true/false across different userIds (not all clustered)', async () => {
    vi.stubEnv('VITE_SHARING_ENABLED', '1')
    vi.stubEnv('VITE_SHARING_ROLLOUT_PCT', '50')
    const { isSharingEnabledForUser } = await import('../sharing-flag')
    const results = new Set<boolean>()
    for (let i = 0; i < 50; i++) {
      results.add(isSharingEnabledForUser(`user-${i}`))
      if (results.size === 2) break
    }
    expect(results.size).toBe(2)
  })
})
