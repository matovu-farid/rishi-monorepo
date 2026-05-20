import { describe, it, expect, beforeEach } from 'vitest'
import {
  registerPdfCanvas,
  unregisterPdfCanvas,
  getActivePdfCanvas,
  __resetPdfCanvasRegistryForTest
} from './pdfCanvasRegistry'

describe('pdfCanvasRegistry', () => {
  beforeEach(() => __resetPdfCanvasRegistryForTest())

  it('returns null when nothing registered', () => {
    expect(getActivePdfCanvas()).toBeNull()
  })

  it('returns the most recently registered canvas', () => {
    const a = document.createElement('canvas')
    const b = document.createElement('canvas')
    registerPdfCanvas(1, a)
    registerPdfCanvas(2, b)
    expect(getActivePdfCanvas()).toBe(b)
  })

  it('falls back to a previous page after unregister', () => {
    const a = document.createElement('canvas')
    const b = document.createElement('canvas')
    registerPdfCanvas(1, a)
    registerPdfCanvas(2, b)
    unregisterPdfCanvas(2)
    expect(getActivePdfCanvas()).toBe(a)
  })

  it('returns null after all pages unregistered', () => {
    const a = document.createElement('canvas')
    registerPdfCanvas(1, a)
    unregisterPdfCanvas(1)
    expect(getActivePdfCanvas()).toBeNull()
  })
})
