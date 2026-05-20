import 'vitest-canvas-mock'
import { describe, it, expect } from 'vitest'
import { encodeCanvasToWebp, downscaleTarget } from './encode'

describe('downscaleTarget', () => {
  it('returns source size when smaller than max', () => {
    expect(downscaleTarget(800, 600, 1024)).toEqual({ width: 800, height: 600 })
  })

  it('scales width to max and keeps aspect ratio', () => {
    expect(downscaleTarget(2000, 1500, 1024)).toEqual({ width: 1024, height: 768 })
  })

  it('does not upscale', () => {
    expect(downscaleTarget(500, 400, 2048)).toEqual({ width: 500, height: 400 })
  })
})

describe('encodeCanvasToWebp', () => {
  it('returns a webp data URL whose length is non-trivial', async () => {
    const canvas = document.createElement('canvas')
    canvas.width = 200
    canvas.height = 100
    const ctx = canvas.getContext('2d')!
    ctx.fillStyle = '#f00'
    ctx.fillRect(0, 0, 200, 100)

    const result = await encodeCanvasToWebp(canvas, { maxWidth: 1024, quality: 0.75 })

    expect(result.dataUrl.startsWith('data:image/webp;base64,')).toBe(true)
    expect(result.width).toBe(200)
    expect(result.height).toBe(100)
    expect(result.bytes).toBeGreaterThan(50)
  })

  it('downscales when source exceeds maxWidth', async () => {
    const canvas = document.createElement('canvas')
    canvas.width = 2000
    canvas.height = 1000
    const result = await encodeCanvasToWebp(canvas, { maxWidth: 1024, quality: 0.75 })
    expect(result.width).toBe(1024)
    expect(result.height).toBe(512)
  })
})
