let activeFrame: HTMLIFrameElement | null = null

export function registerEpubFrame(frame: HTMLIFrameElement): void {
  activeFrame = frame
}

export function clearEpubFrame(): void {
  activeFrame = null
}

export function getActiveEpubFrame(): HTMLIFrameElement | null {
  return activeFrame
}
