import 'vitest-canvas-mock'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const { toCanvasMock } = vi.hoisted(() => ({ toCanvasMock: vi.fn() }))
vi.mock('html-to-image', () => ({ toCanvas: toCanvasMock }))

import { captureCurrentPage, summarizeCurrentPage, CaptureError } from './index'
import { registerPdfCanvas, __resetPdfCanvasRegistryForTest } from './pdfCanvasRegistry'
import { registerEpubFrame, clearEpubFrame } from './epubFrameRegistry'

function makeCanvas(w: number, h: number, color = '#000'): HTMLCanvasElement {
  const cv = document.createElement('canvas')
  cv.width = w
  cv.height = h
  const ctx = cv.getContext('2d')!
  ctx.fillStyle = color
  ctx.fillRect(0, 0, w, h)
  return cv
}

beforeEach(() => {
  __resetPdfCanvasRegistryForTest()
  clearEpubFrame()
  toCanvasMock.mockReset()
})

describe('captureCurrentPage', () => {
  it('captures the active PDF canvas at low detail (max 1024w)', async () => {
    registerPdfCanvas(1, makeCanvas(2000, 1500, '#abc'))
    const res = await captureCurrentPage({ detail: 'low' })
    expect(res.width).toBe(1024)
    expect(res.dataUrl.startsWith('data:image/webp;base64,')).toBe(true)
  })

  it('captures the active PDF canvas at high detail (max 2048w)', async () => {
    registerPdfCanvas(1, makeCanvas(4000, 3000))
    const res = await captureCurrentPage({ detail: 'high' })
    expect(res.width).toBe(2048)
  })

  it('captures via html-to-image when only an EPUB frame is registered', async () => {
    const iframe = document.createElement('iframe')
    document.body.appendChild(iframe)
    iframe.srcdoc = '<body><p>hello</p></body>'
    await new Promise((r) => setTimeout(r, 10))
    registerEpubFrame(iframe)
    toCanvasMock.mockResolvedValue(makeCanvas(1600, 1200))

    const res = await captureCurrentPage({ detail: 'low' })
    expect(toCanvasMock).toHaveBeenCalledOnce()
    expect(res.width).toBe(1024)
  })

  it('rejects with NotReady when nothing registered', async () => {
    await expect(captureCurrentPage({ detail: 'low' })).rejects.toMatchObject({
      code: CaptureError.NotReady
    })
  })
})

describe('summarizeCurrentPage', () => {
  it('uses the EPUB iframe body when present', () => {
    const iframe = document.createElement('iframe')
    document.body.appendChild(iframe)
    iframe.contentDocument!.open()
    iframe.contentDocument!.write(
      '<body><figure><img width="200" height="200" src="x"/></figure></body>'
    )
    iframe.contentDocument!.close()
    registerEpubFrame(iframe)
    expect(summarizeCurrentPage()).toMatchObject({ figures: 1 })
  })

  it('returns zeros when nothing registered', () => {
    expect(summarizeCurrentPage()).toEqual({ equations: 0, figures: 0, images: 0 })
  })
})
