import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, fireEvent, act, within, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { BookDiscoveryModal } from './BookDiscoveryModal'
import type { DiscoveredBook, ImportResult } from '@/services'
import type { DiscoveryEvent } from '@/services/book-import/types'

function renderWithClient(ui: React.ReactElement) {
  const client = new QueryClient({
    defaultOptions: { queries: { retry: false } }
  })
  return render(<QueryClientProvider client={client}>{ui}</QueryClientProvider>)
}

const importBatch = vi.fn<(paths: string[]) => Promise<ImportResult[]>>()
const startDiscovery = vi.fn()
const cancelDiscovery = vi.fn<() => Promise<void>>()
const onDiscoveryEvent =
  vi.fn<(cb: (event: DiscoveryEvent) => void) => () => void>()
const openBook = vi.fn<(id: number) => Promise<void>>()

let discoveryListener: ((event: DiscoveryEvent) => void) | null = null

vi.mock('@/services', async () => {
  return {
    getBookImportService: () => ({
      importBatch,
      startDiscovery,
      cancelDiscovery,
      onDiscoveryEvent
    })
  }
})

vi.mock('@tanstack/react-query', async () => {
  const actual = await vi.importActual<typeof import('@tanstack/react-query')>(
    '@tanstack/react-query'
  )
  return {
    ...actual,
    useQueryClient: () => ({ invalidateQueries: vi.fn().mockResolvedValue(undefined) })
  }
})

vi.mock('sonner', () => ({
  toast: {
    promise: (p: Promise<unknown>) => {
      void p
    }
  }
}))

vi.mock('@/modules/chooseFiles', () => ({ chooseFiles: vi.fn().mockResolvedValue([]) }))

function makeBook(overrides: Partial<DiscoveredBook> & { filepath: string }): DiscoveredBook {
  return {
    filepath: overrides.filepath,
    filename: overrides.filename ?? overrides.filepath.split('/').pop()!,
    title: overrides.title ?? null,
    author: overrides.author ?? null,
    format: overrides.format ?? 'pdf',
    fileSize: overrides.fileSize ?? 1024,
    folder: overrides.folder ?? '/Users/x/Documents',
    fileHash: overrides.fileHash ?? null
  }
}

function emitBooks(books: DiscoveredBook[]) {
  if (!discoveryListener) throw new Error('no listener subscribed yet')
  act(() => {
    for (const book of books) discoveryListener!({ kind: 'book-found', book })
    discoveryListener!({ kind: 'complete', cancelled: false })
  })
}

beforeEach(() => {
  importBatch.mockReset().mockResolvedValue([])
  startDiscovery.mockReset()
  cancelDiscovery.mockReset().mockResolvedValue(undefined)
  discoveryListener = null
  onDiscoveryEvent.mockReset().mockImplementation((cb) => {
    discoveryListener = cb
    return () => {
      discoveryListener = null
    }
  })
  openBook.mockReset().mockResolvedValue(undefined)
  ;(window.electron as unknown as { openBook: typeof openBook }).openBook = openBook
  ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
    .fn()
    .mockResolvedValue([])
})

describe('BookDiscoveryModal selection behavior', () => {
  it('starts with nothing selected and the import button disabled', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    const importButton = screen.getByRole('button', { name: /import selected/i })
    expect(importButton).toBeDisabled()
    expect(importButton).toHaveTextContent('Import Selected (0)')
  })

  it('does NOT render a one-click "Import All" button', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])
    expect(screen.queryByRole('button', { name: /import all/i })).not.toBeInTheDocument()
  })

  it('toggling a per-book checkbox updates the selection count and enables import', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    const checkbox = screen.getByRole('checkbox', { name: /select a\.pdf/i })
    fireEvent.click(checkbox)

    const importButton = screen.getByRole('button', { name: /import selected/i })
    expect(importButton).toBeEnabled()
    expect(importButton).toHaveTextContent('Import Selected (1)')

    fireEvent.click(checkbox)
    expect(importButton).toHaveTextContent('Import Selected (0)')
    expect(importButton).toBeDisabled()
  })

  it('folder header checkbox selects every book in that folder only', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' }),
      makeBook({ filepath: '/other/c.pdf', folder: '/other' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))

    expect(screen.getByRole('button', { name: /import selected/i })).toHaveTextContent(
      'Import Selected (2)'
    )
    expect(screen.getByRole('checkbox', { name: /select a\.pdf/i })).toBeChecked()
    expect(screen.getByRole('checkbox', { name: /select b\.pdf/i })).toBeChecked()
    expect(screen.getByRole('checkbox', { name: /select c\.pdf/i })).not.toBeChecked()
  })

  it('folder header checkbox is indeterminate when only some books in folder are selected', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))

    const folderCheckbox = screen.getByRole('checkbox', {
      name: /select all books in \/docs/i
    }) as HTMLInputElement
    expect(folderCheckbox.indeterminate).toBe(true)
    expect(folderCheckbox.checked).toBe(false)
  })

  it('a small selection imports without confirmation', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    expect(importBatch).toHaveBeenCalledWith(['/docs/a.pdf'])
    expect(screen.queryByRole('dialog', { name: /confirm/i })).not.toBeInTheDocument()
  })

  it('a large selection requires confirmation before importing', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    const books = Array.from({ length: 25 }, (_, i) =>
      makeBook({ filepath: `/docs/book-${i}.pdf`, folder: '/docs' })
    )
    emitBooks(books)

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    // No import yet — confirmation is gating the call.
    expect(importBatch).not.toHaveBeenCalled()

    const confirmDialog = screen.getByRole('dialog', { name: /confirm/i })
    expect(within(confirmDialog).getByRole('heading', { name: /25/ })).toBeInTheDocument()

    fireEvent.click(within(confirmDialog).getByRole('button', { name: /^import/i }))

    expect(importBatch).toHaveBeenCalledTimes(1)
    expect(importBatch.mock.calls[0][0]).toHaveLength(25)
  })

  it('cancelling the large-import confirmation does not call importBatch', async () => {
    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    const books = Array.from({ length: 30 }, (_, i) =>
      makeBook({ filepath: `/docs/book-${i}.pdf`, folder: '/docs' })
    )
    emitBooks(books)

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    const confirmDialog = screen.getByRole('dialog', { name: /confirm/i })
    fireEvent.click(within(confirmDialog).getByRole('button', { name: /cancel|keep editing/i }))

    expect(importBatch).not.toHaveBeenCalled()
    // Selection survives cancel so the user can adjust before retrying.
    expect(screen.getByRole('button', { name: /import selected/i })).toHaveTextContent(
      'Import Selected (30)'
    )
  })
})

describe('BookDiscoveryModal post-import behavior', () => {
  it('closes the wizard after the import resolves (regardless of success)', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 1, filePath: '/docs/a.pdf', format: 'pdf' }
    ])
    renderWithClient(<BookDiscoveryModal open={true} onClose={onClose} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalledTimes(1))
  })

  it('auto-opens the book when exactly one import succeeds', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 99, filePath: '/docs/a.pdf', format: 'pdf' }
    ])
    renderWithClient(<BookDiscoveryModal open={true} onClose={onClose} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(openBook).toHaveBeenCalledWith(99))
    expect(onClose).toHaveBeenCalled()
  })

  it('does NOT auto-open when more than one book is imported', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 1, filePath: '/docs/a.pdf', format: 'pdf' },
      { ok: true, bookId: 2, filePath: '/docs/b.pdf', format: 'pdf' }
    ])
    renderWithClient(<BookDiscoveryModal open={true} onClose={onClose} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(openBook).not.toHaveBeenCalled()
  })

  it('does NOT auto-open when zero books succeed (all failed)', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: false, filePath: '/docs/a.pdf', stage: 'parse', error: 'corrupt' }
    ])
    renderWithClient(<BookDiscoveryModal open={true} onClose={onClose} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([makeBook({ filepath: '/docs/a.pdf', folder: '/docs' })])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(openBook).not.toHaveBeenCalled()
  })

  it('auto-opens the single successful book even when other selected imports failed', async () => {
    const onClose = vi.fn()
    importBatch.mockResolvedValue([
      { ok: true, bookId: 5, filePath: '/docs/a.pdf', format: 'pdf' },
      { ok: false, filePath: '/docs/b.pdf', stage: 'parse', error: 'bad' }
    ])
    renderWithClient(<BookDiscoveryModal open={true} onClose={onClose} />)
    await waitFor(() => expect(window.electron.getBookFilepaths).toHaveBeenCalled())
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select all books in \/docs/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    await waitFor(() => expect(openBook).toHaveBeenCalledWith(5))
    expect(onClose).toHaveBeenCalled()
  })
})

describe('BookDiscoveryModal discovery filter', () => {
  beforeEach(() => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockResolvedValue([])
  })

  it('hides discovered books whose filepath is already in the library', async () => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockResolvedValue(['/docs/already.pdf'])

    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)

    // Wait for the filepath query to resolve before emitting books — the
    // wizard buffers book-found events until the existing-paths query is ready.
    await waitFor(() =>
      expect(window.electron.getBookFilepaths).toHaveBeenCalled()
    )

    emitBooks([
      makeBook({ filepath: '/docs/already.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/new.pdf', folder: '/docs' })
    ])

    expect(screen.queryByRole('checkbox', { name: /select already\.pdf/i })).not.toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: /select new\.pdf/i })).toBeInTheDocument()
  })

  it('shows all discovered books when getBookFilepaths rejects (graceful degradation)', async () => {
    ;(window.electron.getBookFilepaths as ReturnType<typeof vi.fn>) = vi
      .fn()
      .mockRejectedValue(new Error('db offline'))

    renderWithClient(<BookDiscoveryModal open={true} onClose={vi.fn()} />)

    await waitFor(() =>
      expect(window.electron.getBookFilepaths).toHaveBeenCalled()
    )

    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    expect(screen.getByRole('checkbox', { name: /select a\.pdf/i })).toBeInTheDocument()
    expect(screen.getByRole('checkbox', { name: /select b\.pdf/i })).toBeInTheDocument()
  })
})
