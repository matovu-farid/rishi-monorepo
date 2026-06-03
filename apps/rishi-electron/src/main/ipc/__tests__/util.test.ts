// Pins the `shell:openExternal` allow-list. This is a security boundary:
// a renderer (potentially compromised by XSS in book content) can only
// ask the OS to open URLs whose protocol is in a small allow-list. A
// regression here is a renderer-to-OS escape (file://, javascript:,
// vscode://, chrome-extension://, ...).
import { describe, it, expect, vi } from 'vitest'

// `util.ts` imports `electron` at module top. Stub it so the test does
// not require an Electron host; we only exercise the pure URL helper.
vi.mock('electron', () => ({
  app: { isPackaged: false },
  shell: { openExternal: vi.fn() }
}))

vi.mock('../../../preload/ipc-contract.js', () => ({
  handle: vi.fn()
}))

import { isOpenExternalUrlAllowed } from '../util.js'

describe('shell:openExternal allow-list (isOpenExternalUrlAllowed)', () => {
  it('allows the documented protocols', () => {
    expect(isOpenExternalUrlAllowed('https://example.com')).toBe(true)
    expect(isOpenExternalUrlAllowed('http://example.com')).toBe(true)
    expect(isOpenExternalUrlAllowed('mailto:user@example.com')).toBe(true)
  })

  it('rejects renderer-to-OS escape protocols', () => {
    // The list is illustrative, not exhaustive: anything outside the
    // allow-list must be rejected.
    expect(isOpenExternalUrlAllowed('file:///etc/passwd')).toBe(false)
    expect(isOpenExternalUrlAllowed('javascript:alert(1)')).toBe(false)
    expect(isOpenExternalUrlAllowed('vscode://file/etc/passwd')).toBe(false)
    expect(isOpenExternalUrlAllowed('chrome-extension://abc/popup.html')).toBe(false)
    expect(isOpenExternalUrlAllowed('ms-windows-store://')).toBe(false)
    expect(isOpenExternalUrlAllowed('ftp://example.com/x')).toBe(false)
  })

  it('rejects malformed URLs without throwing', () => {
    expect(isOpenExternalUrlAllowed('not a url')).toBe(false)
    expect(isOpenExternalUrlAllowed('')).toBe(false)
  })
})
