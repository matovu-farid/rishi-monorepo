function getVisibleArea(el: HTMLElement, window: Window): number {
  const rect = el.getBoundingClientRect()

  // Viewport bounds
  const viewWidth = window.innerWidth
  const viewHeight = window.innerHeight

  // Calculate intersection rectangle
  const visibleWidth = Math.max(0, Math.min(rect.right, viewWidth) - Math.max(rect.left, 0))
  const visibleHeight = Math.max(0, Math.min(rect.bottom, viewHeight) - Math.max(rect.top, 0))

  return visibleWidth * visibleHeight
}
export function getCurrrentPageNumber(window: Window): number {
  const windowHeight = window.innerHeight
  const canvasDivs = Array.from(
    document.querySelectorAll<HTMLDivElement>('[data-page-number]:has(> canvas)')
  )
  const visibleCanvasDivs = canvasDivs.filter((canvasDiv) => {
    const canvas = canvasDiv.querySelector<HTMLCanvasElement>('canvas')
    if (!canvas) return false
    const canvasRect = canvas.getBoundingClientRect()
    const isVisible = canvasRect.top <= windowHeight && canvasRect.bottom >= 0
    return isVisible
  })
  const canvasData = visibleCanvasDivs.flatMap((canvasDiv) => {
    // Treat both missing and empty `data-page-number` as "no value", so we
    // never feed `parseInt('')` (which yields NaN). A real page number is
    // always a non-empty string of digits.
    const rawPageNumber = canvasDiv.dataset.pageNumber
    const pageNumber = parseInt(
      rawPageNumber !== undefined && rawPageNumber !== '' ? rawPageNumber : '1'
    )
    const canvas = canvasDiv.querySelector<HTMLCanvasElement>('canvas')
    // The `visibleCanvasDivs` filter above only keeps divs with a canvas,
    // but DOM mutation between filter and map is theoretically possible —
    // skip rather than throw if the canvas vanished mid-frame.
    if (!canvas) return []
    return [{ pageNumber, canvas }]
  })

  if (canvasData.length === 0) return 1
  if (canvasData.length === 1) return canvasData[0].pageNumber

  // Multiple pages visible -- return the one with the largest visible area
  let bestPage = canvasData[0]
  let bestArea = getVisibleArea(bestPage.canvas, window)
  for (let i = 1; i < canvasData.length; i++) {
    const area = getVisibleArea(canvasData[i].canvas, window)
    if (area > bestArea) {
      bestArea = area
      bestPage = canvasData[i]
    }
  }
  return bestPage.pageNumber
}
