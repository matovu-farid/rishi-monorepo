import { describe, it, expect, vi, beforeEach } from 'vitest'
import { getHighlightsForBook, saveHighlightPdf, type HighlightRow } from './highlight-storage'

// These tests validate the highlight-storage module's typed IPC interactions.
// The module uses window.electron.highlights* which are mocked in test-setup.ts.

describe('highlight-storage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('saveHighlight calls highlightsSave with correct params', async () => {
    const { saveHighlight } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsSave).mockResolvedValueOnce('new-id')

    const id = await saveHighlight({
      bookSyncId: 'book-123',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      text: 'highlighted text',
      color: 'yellow'
    })

    expect(window.electron.highlightsSave).toHaveBeenCalledWith({
      format: 'epub',
      bookSyncId: 'book-123',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      locator: null,
      text: 'highlighted text',
      color: 'yellow',
      note: undefined,
      chapter: undefined
    })
    expect(id).toBe('new-id')
  })

  it('getHighlightsForBook calls highlightsList with correct bookId', async () => {
    const { getHighlightsForBook } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsList).mockResolvedValueOnce([])

    const result = await getHighlightsForBook('book-123')

    expect(window.electron.highlightsList).toHaveBeenCalledWith('book-123')
    expect(result).toEqual([])
  })

  it('deleteHighlightById calls highlightsDeleteById', async () => {
    const { deleteHighlightById } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsDeleteById).mockResolvedValueOnce(undefined)

    await deleteHighlightById('highlight-1')

    expect(window.electron.highlightsDeleteById).toHaveBeenCalledWith('highlight-1')
  })

  it('deleteHighlight calls highlightsDelete with bookSyncId and cfiRange', async () => {
    const { deleteHighlight } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsDelete).mockResolvedValueOnce(undefined)

    await deleteHighlight('book-123', 'epubcfi(/6/4!/4/2/1:0)')

    expect(window.electron.highlightsDelete).toHaveBeenCalledWith(
      'book-123',
      'epubcfi(/6/4!/4/2/1:0)'
    )
  })

  it('updateHighlightNote calls highlightsUpdateNote', async () => {
    const { updateHighlightNote } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsUpdateNote).mockResolvedValueOnce(undefined)

    await updateHighlightNote('highlight-1', 'my note')

    expect(window.electron.highlightsUpdateNote).toHaveBeenCalledWith('highlight-1', 'my note')
  })

  it('updateHighlightColor calls highlightsUpdateColor', async () => {
    const { updateHighlightColor } = await import('./highlight-storage')
    vi.mocked(window.electron.highlightsUpdateColor).mockResolvedValueOnce(undefined)

    await updateHighlightColor('highlight-1', 'blue')

    expect(window.electron.highlightsUpdateColor).toHaveBeenCalledWith('highlight-1', 'blue')
  })
})

describe('highlight-storage — PDF support', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('saveHighlightPdf sends format=pdf and a locator JSON string to the IPC layer', async () => {
    const saveMock = window.electron.highlightsSave as unknown as ReturnType<typeof vi.fn>
    saveMock.mockResolvedValueOnce('row-id-1')

    const id = await saveHighlightPdf({
      bookSyncId: 'book-1',
      locator: { page: 3, rects: [{ x: 1, y: 2, w: 10, h: 12 }] },
      text: 'hello',
      color: 'yellow'
    })

    expect(id).toBe('row-id-1')
    expect(saveMock).toHaveBeenCalledTimes(1)
    const payload = saveMock.mock.calls[0][0]
    expect(payload.format).toBe('pdf')
    expect(payload.bookSyncId).toBe('book-1')
    expect(typeof payload.locator).toBe('string')
    expect(JSON.parse(payload.locator)).toEqual({ page: 3, rects: [{ x: 1, y: 2, w: 10, h: 12 }] })
    expect(payload.color).toBe('yellow')
  })

  it('getHighlightsForBook returns rows whose format and locator fields are typed', async () => {
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValueOnce([
      {
        id: 'r1',
        bookId: 'b1',
        format: 'epub',
        cfiRange: 'epubcfi(/6/4!/4/2)',
        locator: null,
        text: 't',
        color: 'yellow',
        note: '',
        chapter: null,
        createdAt: '2026-05-17T00:00:00.000Z',
        updatedAt: null,
        syncId: null,
        syncVersion: 0,
        isDirty: 0,
        isDeleted: 0
      },
      {
        id: 'r2',
        bookId: 'b1',
        format: 'pdf',
        cfiRange: null,
        locator: JSON.stringify({ page: 1, rects: [] }),
        text: 't2',
        color: 'green',
        note: '',
        chapter: null,
        createdAt: '2026-05-17T00:00:00.000Z',
        updatedAt: null,
        syncId: null,
        syncVersion: 0,
        isDirty: 0,
        isDeleted: 0
      }
    ])

    const rows: HighlightRow[] = await getHighlightsForBook('b1')
    expect(rows).toHaveLength(2)
    expect(rows[0].format).toBe('epub')
    expect(rows[1].format).toBe('pdf')
    expect(rows[1].locator).toBe(JSON.stringify({ page: 1, rects: [] }))
  })

  it('getHighlightsForBook surfaces cfiRange: null for PDF rows (empty-string to null mapping applied by main-process mapper)', async () => {
    // The main-process mapper converts cfi_range='' to null before sending over IPC.
    // The renderer receives null on the wire and must pass it through as-is.
    const listMock = window.electron.highlightsList as unknown as ReturnType<typeof vi.fn>
    listMock.mockResolvedValueOnce([
      {
        id: 'pdf-1',
        bookId: 'b1',
        format: 'pdf',
        cfiRange: null,
        locator: JSON.stringify({ page: 2, rects: [{ x: 0, y: 0, w: 50, h: 10 }] }),
        text: 'pdf text',
        color: 'blue',
        note: '',
        chapter: null,
        createdAt: '2026-05-17T00:00:00.000Z',
        updatedAt: null,
        syncId: null,
        syncVersion: 0,
        isDirty: 0,
        isDeleted: 0
      }
    ])

    const rows: HighlightRow[] = await getHighlightsForBook('b1')
    expect(rows).toHaveLength(1)
    expect(rows[0].cfiRange).toBeNull()
    expect(rows[0].format).toBe('pdf')
  })
})
