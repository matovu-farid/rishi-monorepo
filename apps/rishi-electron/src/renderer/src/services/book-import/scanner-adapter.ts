import type { DiscoveredBook, ScanProgress, ScannerPort } from './types'

/** Minimal slice of `window.electron` the adapter needs. */
export interface ScannerIpc {
  scanForBooks(mode: 'default' | 'full'): Promise<void>
  cancelScan(): Promise<void>
}

/** Shape of `window.electron.on` we depend on (returns an unsubscribe). */
export type WindowEventsOn = (
  channel: 'scan-result' | 'scan-progress' | 'scan-complete',
  listener: (...args: unknown[]) => void
) => () => void

/**
 * Wrap the raw IPC + event channels into a typed `ScannerPort`. Used by the
 * wiring site in `services/index.ts`; tests inject `makeScanner()` directly.
 */
export function createScannerPort(ipc: ScannerIpc, on: WindowEventsOn): ScannerPort {
  return {
    start: (mode) => ipc.scanForBooks(mode),
    cancel: () => ipc.cancelScan(),
    on(kind: 'result' | 'progress' | 'complete', listener: (...args: unknown[]) => void) {
      const channel =
        kind === 'result' ? 'scan-result' : kind === 'progress' ? 'scan-progress' : 'scan-complete'
      return on(channel, (...args: unknown[]) => {
        if (kind === 'complete') listener()
        else if (kind === 'result')
          (listener as (b: DiscoveredBook) => void)(args[0] as DiscoveredBook)
        else (listener as (p: ScanProgress) => void)(args[0] as ScanProgress)
      })
    }
  } as ScannerPort
}
