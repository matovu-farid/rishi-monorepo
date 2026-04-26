import { describe, it, expect, vi, beforeEach } from 'vitest'

describe('bookmark-storage', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('saveBookmark calls bookmarksSave', async () => {
    const { saveBookmark } = await import('./bookmark-storage')
    vi.mocked(window.electron.bookmarksSave).mockResolvedValueOnce(undefined)

    await saveBookmark({
      bookId: 'book-123',
      location: 'epubcfi(/6/4!/4/2)',
      label: 'Chapter 1'
    })

    expect(window.electron.bookmarksSave).toHaveBeenCalledWith(
      expect.objectContaining({
        bookId: 'book-123',
        location: 'epubcfi(/6/4!/4/2)',
        label: 'Chapter 1'
      })
    )
  })

  it('saveBookmark defaults label to empty string', async () => {
    const { saveBookmark } = await import('./bookmark-storage')
    vi.mocked(window.electron.bookmarksSave).mockResolvedValueOnce(undefined)

    await saveBookmark({
      bookId: 'book-123',
      location: 'epubcfi(/6/4!/4/2)'
    })

    expect(window.electron.bookmarksSave).toHaveBeenCalledWith(
      expect.objectContaining({ label: '' })
    )
  })

  it('getBookmarksForBook returns bookmarks', async () => {
    const { getBookmarksForBook } = await import('./bookmark-storage')
    const mockBookmarks = [
      {
        id: '1',
        bookId: 'book-123',
        location: 'cfi1',
        label: 'Ch 1',
        createdAt: 1000,
        updatedAt: 1000,
        pageNumber: null,
        syncVersion: 0,
        isDirty: 1,
        isDeleted: 0
      }
    ]
    vi.mocked(window.electron.bookmarksList).mockResolvedValueOnce(mockBookmarks)

    const result = await getBookmarksForBook('book-123')
    expect(result).toHaveLength(1)
  })

  it('deleteBookmark calls bookmarksDelete', async () => {
    const { deleteBookmark } = await import('./bookmark-storage')
    vi.mocked(window.electron.bookmarksDelete).mockResolvedValueOnce(undefined)

    await deleteBookmark('bm-1')

    expect(window.electron.bookmarksDelete).toHaveBeenCalledWith('bm-1')
  })
})
