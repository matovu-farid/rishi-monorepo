import { describe, expect, it, vi } from 'vitest'
import { createEpubSyncBridge } from '../epubSyncBridge'

describe('createEpubSyncBridge', () => {
  it('producer broadcasts cfi when it changes', () => {
    const broadcasts: any[] = []
    let cb: ((s: { cfi: string }) => void) | null = null
    const ref = {
      subscribe: (fn: (s: { cfi: string }) => void) => { cb = fn; return () => {} },
      send: vi.fn()
    }
    const bridge = createEpubSyncBridge({
      mode: 'producer',
      bookId: 'b',
      epubMachineRef: ref,
      onBroadcast: (m) => broadcasts.push(m)
    })
    cb?.({ cfi: 'cfi/a' })
    cb?.({ cfi: 'cfi/a' })
    cb?.({ cfi: 'cfi/b' })
    expect(broadcasts).toHaveLength(2)
    expect(broadcasts[0].position).toMatchObject({ format: 'epub', cfi: 'cfi/a' })
    expect(broadcasts[1].position).toMatchObject({ format: 'epub', cfi: 'cfi/b' })
    bridge.dispose()
  })

  it('consumer dispatches NAVIGATE_TO on incoming epub reader.position', () => {
    const ref = { subscribe: () => () => {}, send: vi.fn() }
    const bridge = createEpubSyncBridge({
      mode: 'consumer', bookId: 'b', epubMachineRef: ref, onBroadcast: () => {}
    })
    bridge.applyIncoming({
      v: 1, t: 'reader.position', bookId: 'b', ts: 1,
      position: { format: 'epub', cfi: 'cfi/target', ts: 1 }
    })
    expect(ref.send).toHaveBeenCalledWith({ type: 'NAVIGATE_TO', cfi: 'cfi/target' })
    bridge.dispose()
  })

  it('ignores PDF-format positions', () => {
    const ref = { subscribe: () => () => {}, send: vi.fn() }
    const bridge = createEpubSyncBridge({
      mode: 'consumer', bookId: 'b', epubMachineRef: ref, onBroadcast: () => {}
    })
    bridge.applyIncoming({
      v: 1, t: 'reader.position', bookId: 'b', ts: 1,
      position: { format: 'pdf', page: 3, offsetY: 0, ts: 1 }
    })
    expect(ref.send).not.toHaveBeenCalled()
    bridge.dispose()
  })
})
