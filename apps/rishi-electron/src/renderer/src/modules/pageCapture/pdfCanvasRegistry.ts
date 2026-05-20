/**
 * Tracks the canvases that react-pdf has finished rendering for the currently
 * mounted document. The "active" canvas is the most recently registered one.
 */
const canvases = new Map<number, HTMLCanvasElement>()
let registrationOrder: number[] = []

export function registerPdfCanvas(pageNumber: number, canvas: HTMLCanvasElement): void {
  canvases.set(pageNumber, canvas)
  registrationOrder = registrationOrder.filter((n) => n !== pageNumber)
  registrationOrder.push(pageNumber)
}

export function unregisterPdfCanvas(pageNumber: number): void {
  canvases.delete(pageNumber)
  registrationOrder = registrationOrder.filter((n) => n !== pageNumber)
}

export function getActivePdfCanvas(): HTMLCanvasElement | null {
  for (let i = registrationOrder.length - 1; i >= 0; i--) {
    const cv = canvases.get(registrationOrder[i])
    if (cv) return cv
  }
  return null
}

/** Test-only reset. */
export function __resetPdfCanvasRegistryForTest(): void {
  canvases.clear()
  registrationOrder = []
}
