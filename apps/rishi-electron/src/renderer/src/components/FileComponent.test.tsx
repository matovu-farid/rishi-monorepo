import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'
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

describe('FileComponent — entering Select mode', () => {
  it('toolbar Select button enters Select mode and shows the action bar', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    expect(screen.getByRole('toolbar', { name: /selection actions/i })).toBeInTheDocument()
    expect(screen.getByText('0 selected')).toBeInTheDocument()
  })

  it('clicking a cover in Select mode toggles selection (does not open the book)', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.click(screen.getByLabelText('Select Alpha'))

    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(window.electron.openBook).not.toHaveBeenCalled()
  })
})

describe('FileComponent — modifier-click selection', () => {
  it('Cmd+click on a cover (not in Select mode) auto-enters Select mode with that book selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    const alpha = screen.getByText('Alpha').closest('div')!.querySelector('button')!
    fireEvent.click(alpha, { metaKey: true })

    expect(screen.getByText('1 selected')).toBeInTheDocument()
    expect(window.electron.openBook).not.toHaveBeenCalled()
  })

  it('Shift+click extends selection across display order', async () => {
    ;(window.electron.getBooks as ReturnType<typeof vi.fn>).mockResolvedValue([
      makeBook({ id: 10, title: 'Alpha' }),
      makeBook({ id: 20, title: 'Beta' }),
      makeBook({ id: 30, title: 'Gamma' })
    ])
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Gamma'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Gamma'), { shiftKey: true })

    expect(screen.getByText('3 selected')).toBeInTheDocument()
  })
})

describe('FileComponent — context menu', () => {
  it('right-click → Select enters Select mode with that book selected', async () => {
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))

    const alphaCard = screen.getByText('Alpha').closest('div')!
    fireEvent.contextMenu(alphaCard)

    // After right-click, two buttons are named exactly "Select":
    // the toolbar Select button (rendered earlier) and the new context-menu
    // Select item. Pick the context-menu one (it's the last in document order).
    const items = screen.getAllByRole('button', { name: 'Select' })
    fireEvent.click(items[items.length - 1])

    expect(screen.getByText('1 selected')).toBeInTheDocument()
  })
})

describe('FileComponent — bulk delete', () => {
  it('confirming bulk delete calls deleteBook per selected id and shows success toast', async () => {
    const { toast } = await import('sonner')
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Beta'))

    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    // Confirm modal appears
    expect(screen.getByText('Delete 2 books?')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))

    await waitFor(() => {
      expect(window.electron.deleteBook).toHaveBeenCalledTimes(2)
    })
    expect(window.electron.deleteBook).toHaveBeenCalledWith(1)
    expect(window.electron.deleteBook).toHaveBeenCalledWith(2)
    expect((toast as unknown as { success: ReturnType<typeof vi.fn> }).success).toHaveBeenCalledWith(
      'Deleted 2 books'
    )
  })

  it('partial failure shows a warning toast with the right counts', async () => {
    const { toast } = await import('sonner')
    ;(window.electron.deleteBook as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error('boom'))

    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Alpha'))
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByLabelText('Select Alpha'))
    fireEvent.click(screen.getByLabelText('Select Beta'))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))

    await waitFor(() => {
      expect(
        (toast as unknown as { warning: ReturnType<typeof vi.fn> }).warning
      ).toHaveBeenCalledWith('Deleted 1 of 2 — 1 failed')
    })
  })
})

describe('FileComponent — Select All scope', () => {
  it('Select All selects only currently-filtered books (search active)', async () => {
    ;(window.electron.getBooks as ReturnType<typeof vi.fn>).mockResolvedValue([
      makeBook({ id: 1, title: 'Apple', author: 'A' }),
      makeBook({ id: 2, title: 'Banana', author: 'A' }),
      makeBook({ id: 3, title: 'Apricot', author: 'B' })
    ])
    renderWithClient(<FileComponent />)
    await waitFor(() => screen.getByText('Banana'))

    fireEvent.change(screen.getByPlaceholderText(/search library/i), {
      target: { value: 'Ap' }
    })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    fireEvent.click(screen.getByRole('button', { name: /select all/i }))

    expect(screen.getByText('2 selected')).toBeInTheDocument()
  })
})

export { renderWithClient, makeBook }
