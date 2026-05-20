import { describe, it, expect, beforeEach } from 'vitest'
import { registerEpubFrame, clearEpubFrame, getActiveEpubFrame } from './epubFrameRegistry'

describe('epubFrameRegistry', () => {
  beforeEach(() => clearEpubFrame())

  it('returns null when nothing registered', () => {
    expect(getActiveEpubFrame()).toBeNull()
  })

  it('returns the registered iframe', () => {
    const f = document.createElement('iframe')
    registerEpubFrame(f)
    expect(getActiveEpubFrame()).toBe(f)
  })

  it('replaces previous registration', () => {
    const a = document.createElement('iframe')
    const b = document.createElement('iframe')
    registerEpubFrame(a)
    registerEpubFrame(b)
    expect(getActiveEpubFrame()).toBe(b)
  })

  it('clears on demand', () => {
    registerEpubFrame(document.createElement('iframe'))
    clearEpubFrame()
    expect(getActiveEpubFrame()).toBeNull()
  })
})
