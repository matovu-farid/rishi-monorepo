import { describe, it, expect, vi } from 'vitest'
import { render, act } from '@testing-library/react'
import { IndexingStatusIndicator } from './IndexingStatusIndicator'
import type { ImportProgressEvent } from '@/services/book-import'

const subscribers = new Set<(e: ImportProgressEvent) => void>()
const emit = (e: ImportProgressEvent): void => subscribers.forEach((cb) => cb(e))

vi.mock('@/services', () => ({
  getBookImportService: () => ({
    onImportProgress: (cb: (e: ImportProgressEvent) => void) => {
      subscribers.add(cb)
      return () => subscribers.delete(cb)
    }
  })
}))

describe('IndexingStatusIndicator', () => {
  it('renders nothing when idle', () => {
    const { container } = render(<IndexingStatusIndicator />)
    expect(container.textContent).toBe('')
  })

  it('shows "Indexing..." while an indexing event is in flight', () => {
    const { container } = render(<IndexingStatusIndicator />)
    act(() => {
      emit({ kind: 'indexing', bookId: 42, reason: 'vectors-missing' })
    })
    expect(container.textContent).toContain('Indexing...')
  })

  it('hides itself when indexing completes successfully', () => {
    const { container } = render(<IndexingStatusIndicator />)
    act(() => emit({ kind: 'indexing', bookId: 42, reason: 'chunks-missing' }))
    expect(container.textContent).toContain('Indexing...')
    act(() => emit({ kind: 'indexed', bookId: 42, ok: true }))
    expect(container.textContent).toBe('')
  })

  it('shows "Indexing failed" when indexing completes with ok=false', () => {
    const { container } = render(<IndexingStatusIndicator />)
    act(() => emit({ kind: 'indexing', bookId: 42, reason: 'vectors-missing' }))
    act(() => emit({ kind: 'indexed', bookId: 42, ok: false }))
    expect(container.textContent).toContain('Indexing failed')
  })
})
