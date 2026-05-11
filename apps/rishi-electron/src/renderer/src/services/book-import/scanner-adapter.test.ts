import { describe, it, expect, vi } from 'vitest'
import type { DiscoveredBook, ScanProgress } from './types'
import { createScannerPort, type ScannerIpc, type WindowEventsOn } from './scanner-adapter'

/**
 * Build a fake `window.electron` IPC + on() wrapper.
 * `emit(channel, payload)` simulates an IPC event from main.
 */
function makeFakeIpc(): {
  ipc: ScannerIpc
  on: WindowEventsOn
  emit(channel: 'scan-result' | 'scan-progress' | 'scan-complete', payload?: unknown): void
  startCalls(): string[]
  cancelCalls(): number
} {
  const startCalls: string[] = []
  let cancelCount = 0
  const listeners = new Map<string, Set<(...args: unknown[]) => void>>()

  const ipc: ScannerIpc = {
    scanForBooks: vi.fn(async (mode: string) => {
      startCalls.push(mode)
    }),
    cancelScan: vi.fn(async () => {
      cancelCount++
    })
  }

  const on: WindowEventsOn = (channel, listener) => {
    if (!listeners.has(channel)) listeners.set(channel, new Set())
    listeners.get(channel)!.add(listener)
    return () => {
      listeners.get(channel)?.delete(listener)
    }
  }

  return {
    ipc,
    on,
    emit(channel, payload) {
      for (const l of listeners.get(channel) ?? []) l(payload)
    },
    startCalls: () => startCalls,
    cancelCalls: () => cancelCount
  }
}

describe('createScannerPort', () => {
  it('forwards start(mode) to ipc.scanForBooks and cancel() to ipc.cancelScan', async () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)

    await scanner.start('default')
    await scanner.cancel()

    expect(fake.startCalls()).toEqual(['default'])
    expect(fake.cancelCalls()).toBe(1)
  })

  it('on("result") delivers DiscoveredBook payloads from the scan-result channel', () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)
    const received: DiscoveredBook[] = []
    scanner.on('result', (b) => received.push(b))

    const book: DiscoveredBook = {
      filepath: '/Books/sample.epub',
      filename: 'sample.epub',
      title: 'Sample',
      author: 'A',
      format: 'epub',
      fileSize: 1024,
      folder: '/Books',
      fileHash: null
    }
    fake.emit('scan-result', book)

    expect(received).toEqual([book])
  })

  it('on("progress") delivers ScanProgress; on("complete") fires with no arg; unsubscribe stops delivery', () => {
    const fake = makeFakeIpc()
    const scanner = createScannerPort(fake.ipc, fake.on)
    const progress: ScanProgress[] = []
    const completes: number[] = []
    const unsubProgress = scanner.on('progress', (p) => progress.push(p))
    scanner.on('complete', () => completes.push(1))

    fake.emit('scan-progress', { folder: '/Books', scanned: 1, total: 10 })
    fake.emit('scan-complete')

    expect(progress).toEqual([{ folder: '/Books', scanned: 1, total: 10 }])
    expect(completes).toEqual([1])

    unsubProgress()
    fake.emit('scan-progress', { folder: '/Books', scanned: 2, total: 10 })
    expect(progress).toEqual([{ folder: '/Books', scanned: 1, total: 10 }]) // unchanged
  })
})
