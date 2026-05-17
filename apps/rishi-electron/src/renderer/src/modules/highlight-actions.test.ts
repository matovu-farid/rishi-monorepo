import { describe, it, expect, vi, beforeEach } from 'vitest'

vi.mock('@/modules/highlight-storage', () => ({
  saveHighlight: vi.fn(async (params: { bookSyncId: string; cfiRange: string; text: string; color?: string; note?: string; chapter?: string }) =>
    window.electron.highlightsSave({
      format: 'epub',
      bookSyncId: params.bookSyncId,
      cfiRange: params.cfiRange,
      locator: null,
      text: params.text,
      color: params.color ?? 'yellow',
      note: params.note ?? '',
      chapter: params.chapter ?? null
    })
  ),
  deleteHighlight: vi.fn().mockResolvedValue(undefined),
  saveHighlightPdf: vi.fn(async (params: { bookSyncId: string; locator: unknown; text: string; color?: string; note?: string; chapter?: string | null }) =>
    window.electron.highlightsSave({
      format: 'pdf',
      bookSyncId: params.bookSyncId,
      cfiRange: null,
      locator: JSON.stringify(params.locator),
      text: params.text,
      color: params.color ?? 'yellow',
      note: params.note ?? '',
      chapter: params.chapter ?? null
    })
  ),
  deleteHighlightById: vi.fn(async (id: string) => window.electron.highlightsDeleteById(id)),
  getHighlightsForBook: vi.fn().mockResolvedValue([])
}))

vi.mock('@/services', () => ({
  getSyncService: vi.fn(() => ({ triggerWrite: vi.fn() }))
}))

import {
  saveHighlight,
  deleteHighlight,
  getHighlightsForBook,
  type HighlightRow
} from '@/modules/highlight-storage'
import { getSyncService } from '@/services'
import {
  applyHighlightWithUndo,
  deleteHighlightWithUndo,
  saveNoteOnly,
  applyHighlightWithUndoPdf,
  deleteHighlightByIdWithUndo
} from './highlight-actions'
import { NOTE_COLOR_NONE } from '@/types/highlight'

function makeTarget() {
  return {
    applyVisual: vi.fn(),
    removeVisual: vi.fn()
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({
    triggerWrite: vi.fn()
  })
})

describe('applyHighlightWithUndo — apply path', () => {
  it('calls applyVisual, saveHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })
})

describe('applyHighlightWithUndo — undo path', () => {
  it('handle.undo() calls removeVisual, deleteHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow'
    })

    // Reset counts so we only see undo-time activity.
    target.applyVisual.mockClear()
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-2', 'cfi:2')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if saveHighlight rejects', async () => {
    ;(saveHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(new Error('boom'))
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    await handle.undo()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still removes visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await applyHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
    expect(target.removeVisual).toHaveBeenCalledTimes(2)
  })
})

describe('deleteHighlightWithUndo — delete path', () => {
  it('calls removeVisual, deleteHighlight and triggerWrite exactly once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-1',
      cfiRange: 'cfi:1',
      text: 'hello',
      color: 'yellow'
    })

    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledTimes(1)
    expect(deleteHighlight).toHaveBeenCalledWith('book-1', 'cfi:1')
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('handle.undo() calls applyVisual, saveHighlight and triggerWrite once', async () => {
    const target = makeTarget()
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note'
    })

    target.removeVisual.mockClear()
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockClear()
    triggerWrite.mockClear()

    await handle.undo()

    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledTimes(1)
    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-2',
      cfiRange: 'cfi:2',
      text: 'world',
      color: 'yellow',
      note: 'a note',
      chapter: undefined
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('returns a working handle even if deleteHighlight rejects', async () => {
    ;(deleteHighlight as unknown as ReturnType<typeof vi.fn>).mockRejectedValueOnce(
      new Error('boom')
    )
    const target = makeTarget()
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-3',
      cfiRange: 'cfi:3',
      text: 'x',
      color: 'yellow'
    })

    expect(warn).toHaveBeenCalled()
    expect(target.removeVisual).toHaveBeenCalledTimes(1)
    await handle.undo()
    expect(target.applyVisual).toHaveBeenCalledTimes(1)
    warn.mockRestore()
  })

  it('calling undo twice is safe — second call still re-applies visual but does not throw', async () => {
    const target = makeTarget()
    const handle = await deleteHighlightWithUndo({
      target,
      bookSyncId: 'book-4',
      cfiRange: 'cfi:4',
      text: 'x',
      color: 'yellow'
    })

    await handle.undo()
    await expect(handle.undo()).resolves.toBeUndefined()
    expect(target.applyVisual).toHaveBeenCalledTimes(2)
  })
})

describe('saveNoteOnly — note-only highlight creation', () => {
  function makeRow(over: Partial<HighlightRow> = {}): HighlightRow {
    return {
      id: 'db-id-1',
      bookId: 'book-N',
      format: 'epub',
      cfiRange: 'cfi:N',
      locator: null,
      text: 'sample',
      color: NOTE_COLOR_NONE,
      note: '',
      chapter: null,
      createdAt: '0',
      updatedAt: 0,
      syncId: null,
      syncVersion: 0,
      isDirty: 1,
      isDeleted: 0,
      ...over
    }
  }

  it("writes a row with color 'none' via saveHighlight and triggers a sync write", async () => {
    const triggerWrite = vi.fn()
    ;(getSyncService as unknown as ReturnType<typeof vi.fn>).mockReturnValue({ triggerWrite })
    const fresh = makeRow({ cfiRange: 'cfi:N1' })
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([fresh])

    await saveNoteOnly({ bookSyncId: 'book-N', cfiRange: 'cfi:N1', text: 'sample' })

    expect(saveHighlight).toHaveBeenCalledWith({
      bookSyncId: 'book-N',
      cfiRange: 'cfi:N1',
      text: 'sample',
      color: NOTE_COLOR_NONE
    })
    expect(triggerWrite).toHaveBeenCalledTimes(1)
  })

  it('does not call any visual apply/remove function (note-only has no SVG mark)', async () => {
    const fresh = makeRow({ cfiRange: 'cfi:N2' })
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([fresh])

    // saveNoteOnly takes no `target` arg — type system already enforces
    // this; the test guards against future shape drift by asserting the
    // function resolves without any visual side-effect surface.
    await expect(
      saveNoteOnly({ bookSyncId: 'book-N', cfiRange: 'cfi:N2', text: 'sample' })
    ).resolves.toBeDefined()
  })

  it('resolves with the freshly persisted HighlightRow (id backfilled from the DB)', async () => {
    const fresh = makeRow({ id: 'db-real-id', cfiRange: 'cfi:N3', note: '' })
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([
      makeRow({ id: 'other', cfiRange: 'cfi:OTHER' }),
      fresh
    ])

    const row = await saveNoteOnly({
      bookSyncId: 'book-N',
      cfiRange: 'cfi:N3',
      text: 'sample'
    })

    expect(row.id).toBe('db-real-id')
    expect(row.cfiRange).toBe('cfi:N3')
    expect(row.color).toBe(NOTE_COLOR_NONE)
  })

  it('rejects when the backfill query cannot find the saved row (the cfiRange did not persist)', async () => {
    ;(getHighlightsForBook as unknown as ReturnType<typeof vi.fn>).mockResolvedValueOnce([])

    await expect(
      saveNoteOnly({ bookSyncId: 'book-N', cfiRange: 'cfi:MISSING', text: 'sample' })
    ).rejects.toThrow(/not found/i)
  })
})

describe('applyHighlightWithUndoPdf', () => {
  beforeEach(() => vi.clearAllMocks())

  it('persists via saveHighlightPdf and exposes an undo handle that calls deleteHighlightById', async () => {
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('pdf-row-1')
    const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
    deleteMock.mockResolvedValueOnce(undefined)

    const applyVisual = vi.fn().mockResolvedValueOnce(undefined)
    const removeVisual = vi.fn().mockResolvedValueOnce(undefined)
    const handle = await applyHighlightWithUndoPdf({
      target: { applyVisual, removeVisual },
      bookSyncId: 'b1',
      locator: { page: 2, rects: [{ x: 0, y: 0, w: 10, h: 10 }] },
      text: 'hi',
      color: 'yellow'
    })

    expect(applyVisual).toHaveBeenCalledTimes(1)
    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][0].format).toBe('pdf')

    await handle.undo()
    expect(removeVisual).toHaveBeenCalledTimes(1)
    expect(deleteMock).toHaveBeenCalledWith('pdf-row-1')
  })
})

describe('deleteHighlightByIdWithUndo', () => {
  beforeEach(() => vi.clearAllMocks())

  it('deletes by id and re-inserts on undo using the row snapshot', async () => {
    const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
    deleteMock.mockResolvedValueOnce(undefined)
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('reinserted-1')

    const handle = await deleteHighlightByIdWithUndo({
      target: { applyVisual: vi.fn(), removeVisual: vi.fn() },
      rowId: 'r1',
      snapshot: {
        bookId: 'b1', format: 'pdf', cfiRange: null,
        locator: JSON.stringify({ page: 1, rects: [{ x: 0, y: 0, w: 10, h: 10 }] }),
        text: 'hi', color: 'yellow', note: '', chapter: null
      }
    })
    expect(deleteMock).toHaveBeenCalledWith('r1')

    await handle.undo()
    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][0].format).toBe('pdf')
  })

  it('uses saveHighlight (EPUB path) on undo when snapshot.format is epub', async () => {
    const deleteMock = window.electron.highlightsDeleteById as unknown as ReturnType<typeof vi.fn>
    deleteMock.mockResolvedValueOnce(undefined)
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('reinserted-epub-1')

    const handle = await deleteHighlightByIdWithUndo({
      target: { applyVisual: vi.fn(), removeVisual: vi.fn() },
      rowId: 'r2',
      snapshot: {
        bookId: 'b1', format: 'epub', cfiRange: 'epubcfi(/6/4!/4/2)', locator: null,
        text: 't', color: 'yellow', note: '', chapter: null
      }
    })
    await handle.undo()
    expect(saveMock).toHaveBeenCalledTimes(1)
    expect(saveMock.mock.calls[0][0].format).toBe('epub')
    expect(saveMock.mock.calls[0][0].cfiRange).toBe('epubcfi(/6/4!/4/2)')
  })
})
