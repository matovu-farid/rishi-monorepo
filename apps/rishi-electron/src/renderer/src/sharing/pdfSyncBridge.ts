import type { SyncMsg } from '@rishi/sharing-protocol/sync'

export type PdfMachineLike = {
  subscribe: (cb: (s: { currentPage: number; currentOffset: number }) => void) => () => void
  send: (event: { type: 'SEEK_REQUESTED'; page: number }) => void
  scrollToOffset: (offsetY: number) => void
}

export type PdfSyncBridge = {
  applyIncoming: (m: SyncMsg) => void
  dispose: () => void
}

export type PdfSyncBridgeInput = {
  mode: 'producer' | 'consumer'
  bookId: string
  pdfMachineRef: PdfMachineLike
  onBroadcast: (m: SyncMsg) => void
}

export function createPdfSyncBridge(input: PdfSyncBridgeInput): PdfSyncBridge {
  let last = { page: -1, offsetY: -1 }
  const unsub =
    input.mode === 'producer'
      ? input.pdfMachineRef.subscribe((s) => {
          if (s.currentPage === last.page && s.currentOffset === last.offsetY) return
          last = { page: s.currentPage, offsetY: s.currentOffset }
          input.onBroadcast({
            v: 1,
            t: 'reader.position',
            bookId: input.bookId,
            ts: Date.now(),
            position: {
              format: 'pdf',
              page: s.currentPage,
              offsetY: s.currentOffset,
              ts: Date.now()
            }
          })
        })
      : () => {}

  return {
    applyIncoming: (m: SyncMsg) => {
      if (input.mode !== 'consumer') return
      if (m.t !== 'reader.position') return
      if (m.bookId !== input.bookId) return
      if (m.position.format !== 'pdf') return
      input.pdfMachineRef.send({ type: 'SEEK_REQUESTED', page: m.position.page })
      input.pdfMachineRef.scrollToOffset(m.position.offsetY)
    },
    dispose: () => unsub()
  }
}
