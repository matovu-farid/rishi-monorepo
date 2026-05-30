import type { SyncMsg } from '@rishi/sharing-protocol/sync'

export type EpubMachineLike = {
  subscribe: (cb: (s: { cfi: string }) => void) => () => void
  send: (e: { type: 'NAVIGATE_TO'; cfi: string }) => void
}

export type EpubSyncBridge = {
  applyIncoming: (m: SyncMsg) => void
  dispose: () => void
}

export type EpubSyncBridgeInput = {
  mode: 'producer' | 'consumer'
  bookId: string
  epubMachineRef: EpubMachineLike
  onBroadcast: (m: SyncMsg) => void
}

export function createEpubSyncBridge(input: EpubSyncBridgeInput): EpubSyncBridge {
  let lastCfi: string | null = null
  const unsub =
    input.mode === 'producer'
      ? input.epubMachineRef.subscribe((s) => {
          if (!s.cfi || s.cfi === lastCfi) return
          lastCfi = s.cfi
          input.onBroadcast({
            v: 1,
            t: 'reader.position',
            bookId: input.bookId,
            ts: Date.now(),
            position: { format: 'epub', cfi: s.cfi, ts: Date.now() }
          })
        })
      : () => {}

  return {
    applyIncoming: (m: SyncMsg) => {
      if (input.mode !== 'consumer') return
      if (m.t !== 'reader.position') return
      if (m.bookId !== input.bookId) return
      if (m.position.format !== 'epub') return
      input.epubMachineRef.send({ type: 'NAVIGATE_TO', cfi: m.position.cfi })
    },
    dispose: () => unsub()
  }
}
