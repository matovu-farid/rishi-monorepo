import { useEffect, useRef } from 'react'
import { drawPageCurl, type CurlDirection } from './drawPageCurl'

interface Props {
  progress: number
  direction: CurlDirection
  pageColor: string
}

/**
 * PageCurlOverlay Component
 * Renders a canvas-based page curl animation overlaid on the reader.
 * The canvas is pointer-events: none so it doesn't intercept clicks.
 */
export function PageCurlOverlay({ progress, direction, pageColor }: Props) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const parent = canvas.parentElement
    if (!parent) return

    function draw() {
      const cvs = canvasRef.current
      if (!cvs) return
      const p = cvs.parentElement
      if (!p) return

      const { width: W, height: H } = p.getBoundingClientRect()
      const dpr = window.devicePixelRatio || 1
      cvs.width = W * dpr
      cvs.height = H * dpr

      const rawCtx = cvs.getContext('2d')
      if (!rawCtx) return
      const ctx: CanvasRenderingContext2D = rawCtx
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)

      drawPageCurl(ctx, W, H, progress, direction, pageColor)
    }

    draw()

    const observer = new ResizeObserver(() => {
      draw()
    })
    observer.observe(parent)

    return () => observer.disconnect()
  }, [progress, direction, pageColor])

  return (
    <canvas
      ref={canvasRef}
      style={{
        position: 'absolute',
        top: 0,
        left: 0,
        width: '100%',
        height: '100%',
        pointerEvents: 'none',
        zIndex: 10
      }}
    />
  )
}
