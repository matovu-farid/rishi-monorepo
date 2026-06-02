import { describe, expect, it, vi } from 'vitest'
import { createPdfSyncBridge } from '../pdfSyncBridge'

describe('createPdfSyncBridge', () => {
  it('translates PAGE_CHANGED to reader.position broadcasts (producer mode)', () => {
    const broadcasts: any[] = []
    let subscriber: ((s: { currentPage: number; currentOffset: number }) => void) | null = null
    const pdfRef = {
      subscribe: (cb: (s: { currentPage: number; currentOffset: number }) => void) => {
        subscriber = cb
        return () => {}
      },
      send: vi.fn(),
      scrollToOffset: vi.fn()
    }
    const bridge = createPdfSyncBridge({
      mode: 'producer',
      bookId: 'b',
      pdfMachineRef: pdfRef,
      onBroadcast: (m) => broadcasts.push(m)
    })
    subscriber?.({ currentPage: 7, currentOffset: 42 })
    expect(broadcasts).toHaveLength(1)
    expect(broadcasts[0]).toMatchObject({
      v: 1,
      t: 'reader.position',
      bookId: 'b',
      position: { format: 'pdf', page: 7, offsetY: 42 }
    })
    bridge.dispose()
  })

  it('applies incoming pdf reader.position via SEEK_REQUESTED + scrollToOffset', () => {
    const pdfRef = {
      subscribe: () => () => {},
      send: vi.fn(),
      scrollToOffset: vi.fn()
    }
    const bridge = createPdfSyncBridge({
      mode: 'consumer',
      bookId: 'b',
      pdfMachineRef: pdfRef,
      onBroadcast: () => {}
    })
    bridge.applyIncoming({
      v: 1,
      t: 'reader.position',
      bookId: 'b',
      ts: 1,
      position: { format: 'pdf', page: 12, offsetY: 88, ts: 1 }
    })
    expect(pdfRef.send).toHaveBeenCalledWith({ type: 'SEEK_REQUESTED', page: 12 })
    expect(pdfRef.scrollToOffset).toHaveBeenCalledWith(88)
    bridge.dispose()
  })

  it('ignores EPUB-format positions', () => {
    const pdfRef = { subscribe: () => () => {}, send: vi.fn(), scrollToOffset: vi.fn() }
    const bridge = createPdfSyncBridge({
      mode: 'consumer',
      bookId: 'b',
      pdfMachineRef: pdfRef,
      onBroadcast: () => {}
    })
    bridge.applyIncoming({
      v: 1,
      t: 'reader.position',
      bookId: 'b',
      ts: 1,
      position: { format: 'epub', cfi: 'cfi/x', ts: 1 }
    })
    expect(pdfRef.send).not.toHaveBeenCalled()
    expect(pdfRef.scrollToOffset).not.toHaveBeenCalled()
    bridge.dispose()
  })
})
