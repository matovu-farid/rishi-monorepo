import { describe, it, expect, vi } from 'vitest'
import { drawPageCurl } from './drawPageCurl'

/** Build a minimal CanvasRenderingContext2D mock. */
function createMockCtx(): CanvasRenderingContext2D {
  const ctx: Record<string, any> = {
    clearRect: vi.fn(),
    save: vi.fn(),
    restore: vi.fn(),
    beginPath: vi.fn(),
    closePath: vi.fn(),
    rect: vi.fn(),
    clip: vi.fn(),
    fillRect: vi.fn(),
    fillStyle: '',
    globalCompositeOperation: 'source-over',
    createLinearGradient: vi.fn(() => ({
      addColorStop: vi.fn()
    })),
    moveTo: vi.fn(),
    lineTo: vi.fn(),
    bezierCurveTo: vi.fn(),
    stroke: vi.fn(),
    strokeStyle: '',
    lineWidth: 1,
    setTransform: vi.fn()
  }
  return ctx as unknown as CanvasRenderingContext2D
}

describe('drawPageCurl', () => {
  it('clears the canvas on every call', () => {
    const ctx = createMockCtx()
    drawPageCurl(ctx, 800, 600, 0.5, 'right', '#fff')
    expect(ctx.clearRect).toHaveBeenCalledWith(0, 0, 800, 600)
  })

  it('handles progress = 0 without errors', () => {
    const ctx = createMockCtx()
    expect(() => drawPageCurl(ctx, 800, 600, 0, 'right', '#fff')).not.toThrow()
  })

  it('handles progress = 1 without errors', () => {
    const ctx = createMockCtx()
    expect(() => drawPageCurl(ctx, 800, 600, 1, 'left', '#fff')).not.toThrow()
  })

  it('clamps progress below 0', () => {
    const ctx = createMockCtx()
    expect(() => drawPageCurl(ctx, 800, 600, -0.5, 'right', '#fff')).not.toThrow()
  })

  it('clamps progress above 1', () => {
    const ctx = createMockCtx()
    expect(() => drawPageCurl(ctx, 800, 600, 1.5, 'left', '#fff')).not.toThrow()
  })

  it('creates gradients for the curl at non-zero progress', () => {
    const ctx = createMockCtx()
    drawPageCurl(ctx, 800, 600, 0.5, 'right', '#fff')
    // At 0.5 progress curlW > 1, so gradients are created for flat page + shadows + curl
    expect(ctx.createLinearGradient).toHaveBeenCalled()
  })

  it('handles left direction', () => {
    const ctx = createMockCtx()
    expect(() => drawPageCurl(ctx, 800, 600, 0.5, 'left', '#eee')).not.toThrow()
    expect(ctx.save).toHaveBeenCalled()
    expect(ctx.restore).toHaveBeenCalled()
  })

  it('draws fold crease strokes at visible progress', () => {
    const ctx = createMockCtx()
    drawPageCurl(ctx, 800, 600, 0.5, 'right', '#fff')
    expect(ctx.stroke).toHaveBeenCalled()
  })
})
