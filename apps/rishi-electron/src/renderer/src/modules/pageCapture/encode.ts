// apps/rishi-electron/src/renderer/src/modules/pageCapture/encode.ts

export interface EncodeOptions {
  maxWidth: number
  quality: number
}

export interface EncodeResult {
  dataUrl: string
  width: number
  height: number
  bytes: number
}

export function downscaleTarget(
  srcW: number,
  srcH: number,
  maxWidth: number
): { width: number; height: number } {
  if (srcW <= maxWidth) return { width: srcW, height: srcH }
  const scale = maxWidth / srcW
  return { width: maxWidth, height: Math.round(srcH * scale) }
}

export async function encodeCanvasToWebp(
  source: HTMLCanvasElement,
  opts: EncodeOptions
): Promise<EncodeResult> {
  const { width, height } = downscaleTarget(source.width, source.height, opts.maxWidth)

  let target: HTMLCanvasElement
  if (width === source.width && height === source.height) {
    target = source
  } else {
    target = document.createElement('canvas')
    target.width = width
    target.height = height
    const ctx = target.getContext('2d')
    if (!ctx) throw new Error('encodeCanvasToWebp: 2D context unavailable')
    ctx.imageSmoothingQuality = 'high'
    ctx.drawImage(source, 0, 0, width, height)
  }

  const blob: Blob = await new Promise((resolve, reject) =>
    target.toBlob(
      (b) => (b ? resolve(b) : reject(new Error('toBlob returned null'))),
      'image/webp',
      opts.quality
    )
  )

  const dataUrl = await new Promise<string>((resolve, reject) => {
    const reader = new FileReader()
    reader.onerror = () => reject(reader.error)
    reader.onload = () => resolve(String(reader.result))
    reader.readAsDataURL(blob)
  })

  return { dataUrl, width, height, bytes: blob.size }
}
