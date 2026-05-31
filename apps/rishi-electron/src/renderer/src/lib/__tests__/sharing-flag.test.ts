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
