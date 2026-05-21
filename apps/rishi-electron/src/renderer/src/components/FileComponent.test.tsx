import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { Book } from '@/lib/api'

// Avoid the dropzone effect / handleDroppedFiles import surface
vi.mock('@/modules/handleDroppedFiles', () => ({
  resolveDroppedFilePaths: vi.fn(() => []),
  DroppedFilesError: class extends Error {},
  getFilesFromDropEvent: vi.fn(async () => [])
}))

// Avoid prefetching TTS during tests
vi.mock('@/modules/ttsPrefetch', () => ({
  prefetchTTSForBooks: vi.fn(async () => {})
}))

// Stub services used in useEffect side-effects
vi.mock('@/services', () => ({
  getBookImportService: () => ({ importBatch: vi.fn(async () => []) }),
  getVoiceChatService: () => ({ prewarmKey: vi.fn() })
}))

// Stub reader caches (their internals require a Worker setup)
vi.mock('@/services/reader-cache/pdf-cache', () => ({
  evictPdf: vi.fn()
}))
vi.mock('@/services/reader-cache/epub-cache', () => ({
  evictEpub: vi.fn()
}))

vi.mock('sonner', () => ({
  toast: Object.assign(vi.fn(), {
    success: vi.fn(),
    error: vi.fn(),
    warning: vi.fn()
  })
}))

// HelpMenu calls window.electron.getAppVersion which is not in test-setup.ts —
// stub the whole component to avoid needing that IPC mock.
vi.mock('./HelpMenu', () => ({
  HelpMenu: () => null
}))

import FileComponent from './FileComponent'

function makeBook(over: Partial<Book> = {}): Book {
  return {
    id: 1,
    title: 'Book One',
    author: 'Author A',
    kind: 'pdf',
    cover: [],
    filepath: '/tmp/one.pdf',
    publisher: '',
    location: '',
    coverKind: '',
    format: 'pdf',
    syncVersion: 0,
    isDirty: 0,
    isDeleted: 0,
    version: 1,
    ...(over as object)
  } as Book
}

function renderWithClient(ui: React.ReactNode) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0, staleTime: 0 } }
  })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

beforeEach(() => {
  ;(window.electron.getBooks as unknown as ReturnType<typeof vi.fn>).mockResolvedValue([
    makeBook({ id: 1, title: 'Alpha', author: 'A' }),
    makeBook({ id: 2, title: 'Beta', author: 'B' })
  ])
  ;(window.electron.deleteBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
  // openBook is called when a book button is clicked; needed so any effect-time
  // invocations (e.g. auto-open on newBookId) don't throw.
  ;(window.electron as unknown as Record<string, ReturnType<typeof vi.fn>>).openBook =
    vi.fn().mockResolvedValue(undefined)
  localStorage.clear()
})

describe('FileComponent — base render', () => {
  it('shows the library after loading and renders book titles', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => expect(screen.getByText('Alpha')).toBeInTheDocument())
    expect(screen.getByText('Beta')).toBeInTheDocument()
  })
})

export { renderWithClient, makeBook }
