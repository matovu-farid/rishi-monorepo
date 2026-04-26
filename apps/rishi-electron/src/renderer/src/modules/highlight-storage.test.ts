import { describe, it, expect, vi, beforeEach } from 'vitest'

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
      bookSyncId: 'book-123',
      cfiRange: 'epubcfi(/6/4!/4/2/1:0)',
      text: 'highlighted text',
      color: 'yellow'
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
