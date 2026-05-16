import { useCallback, useState } from 'react'
import type { CurlDirection } from './drawPageCurl'

export interface ReaderGestureResult {
  progress: number
  direction: CurlDirection
  active: boolean
  pointerHandlers: {
    onPointerDown: (e: React.PointerEvent) => void
    onPointerMove: (e: React.PointerEvent) => void
    onPointerUp: (e: React.PointerEvent) => void
    onPointerCancel: (e: React.PointerEvent) => void
  }
  wheelHandlers: {
    onWheel: (e: React.WheelEvent) => void
  }
  autoTurn: (dir: CurlDirection) => void
}

export function useReaderGesture(_callbacks: {
  onNavigate: (dir: CurlDirection) => boolean
  onCommit: (dir: CurlDirection) => void
  onUndoNavigate: (dir: CurlDirection) => void
}): ReaderGestureResult {
  const [progress] = useState(0)
  const [direction] = useState<CurlDirection>('right')
  const [active] = useState(false)

  const noop = useCallback(() => {}, [])
  return {
    progress,
    direction,
    active,
    pointerHandlers: {
      onPointerDown: noop,
      onPointerMove: noop,
      onPointerUp: noop,
      onPointerCancel: noop
    },
    wheelHandlers: { onWheel: noop },
    autoTurn: noop
  }
}
