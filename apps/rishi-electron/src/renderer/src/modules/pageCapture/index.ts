import { toCanvas } from 'html-to-image'
import { getActivePdfCanvas } from './pdfCanvasRegistry'
import { getActiveEpubFrame } from './epubFrameRegistry'
import { encodeCanvasToWebp, type EncodeResult } from './encode'
import { summarizeVisuals, type VisualSummary } from '@/lib/visualHeuristic'

export const CaptureError = {
  NotReady: 'NOT_READY',
  Failed: 'FAILED'
} as const
export type CaptureErrorCode = (typeof CaptureError)[keyof typeof CaptureError]

export class PageCaptureError extends Error {
  constructor(
    public code: CaptureErrorCode,
    message: string
  ) {
    super(message)
    this.name = 'PageCaptureError'
  }
}

export interface CaptureOptions {
  detail: 'low' | 'high'
}

export type CaptureResult = EncodeResult

const MAX_WIDTH = { low: 1024, high: 2048 } as const
const QUALITY = 0.75

export async function captureCurrentPage(opts: CaptureOptions): Promise<CaptureResult> {
  const maxWidth = MAX_WIDTH[opts.detail]

  const pdfCanvas = getActivePdfCanvas()
  if (pdfCanvas) {
    return encodeCanvasToWebp(pdfCanvas, { maxWidth, quality: QUALITY })
  }

  const frame = getActiveEpubFrame()
  if (frame) {
    const body = frame.contentDocument?.body
    if (!body) {
      throw new PageCaptureError(CaptureError.NotReady, 'EPUB iframe body unavailable')
    }
    let canvas: HTMLCanvasElement
    try {
      canvas = await toCanvas(body, { cacheBust: true, pixelRatio: 1 })
    } catch (err) {
      throw new PageCaptureError(
        CaptureError.Failed,
        `html-to-image failed: ${(err as Error).message}`
      )
    }
    return encodeCanvasToWebp(canvas, { maxWidth, quality: QUALITY })
  }

  throw new PageCaptureError(CaptureError.NotReady, 'No PDF canvas or EPUB iframe registered')
}

export function summarizeCurrentPage(): VisualSummary {
  const pdfCanvas = getActivePdfCanvas()
  if (pdfCanvas) {
    const textLayer = pdfCanvas.parentElement?.querySelector('.react-pdf__Page__textContent')
    if (textLayer) return summarizeVisuals(textLayer)
    return { equations: 0, figures: 0, images: 0 }
  }
  const frame = getActiveEpubFrame()
  if (frame?.contentDocument?.body) {
    return summarizeVisuals(frame.contentDocument.body)
  }
  return { equations: 0, figures: 0, images: 0 }
}
