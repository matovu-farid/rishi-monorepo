import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen, fireEvent, act, within } from '@testing-library/react'
import { BookDiscoveryModal } from './BookDiscoveryModal'
import type { DiscoveredBook, ImportResult } from '@/services'
import type { DiscoveryEvent } from '@/services/book-import/types'

const importBatch = vi.fn<(paths: string[]) => Promise<ImportResult[]>>()
const startDiscovery = vi.fn()
const cancelDiscovery = vi.fn<() => Promise<void>>()
const onDiscoveryEvent =
  vi.fn<(cb: (event: DiscoveryEvent) => void) => () => void>()

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

vi.mock('@tanstack/react-query', () => ({
  useQueryClient: () => ({ invalidateQueries: vi.fn().mockResolvedValue(undefined) })
}))

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
})

describe('BookDiscoveryModal selection behavior', () => {
  it('starts with nothing selected and the import button disabled', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    const importButton = screen.getByRole('button', { name: /import selected/i })
    expect(importButton).toBeDisabled()
    expect(importButton).toHaveTextContent('Import Selected (0)')
  })

  it('does NOT render a one-click "Import All" button', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])
    expect(screen.queryByRole('button', { name: /import all/i })).not.toBeInTheDocument()
  })

  it('toggling a per-book checkbox updates the selection count and enables import', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
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

  it('folder header checkbox selects every book in that folder only', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
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

  it('folder header checkbox is indeterminate when only some books in folder are selected', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
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
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
    emitBooks([
      makeBook({ filepath: '/docs/a.pdf', folder: '/docs' }),
      makeBook({ filepath: '/docs/b.pdf', folder: '/docs' })
    ])

    fireEvent.click(screen.getByRole('checkbox', { name: /select a\.pdf/i }))
    fireEvent.click(screen.getByRole('button', { name: /import selected/i }))

    expect(importBatch).toHaveBeenCalledWith(['/docs/a.pdf'])
    expect(screen.queryByRole('dialog', { name: /confirm/i })).not.toBeInTheDocument()
  })

  it('a large selection requires confirmation before importing', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
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

  it('cancelling the large-import confirmation does not call importBatch', () => {
    render(<BookDiscoveryModal open={true} onClose={vi.fn()} />)
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
