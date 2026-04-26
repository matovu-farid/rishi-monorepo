import { describe, it, expect, beforeEach, vi } from 'vitest'
import { getBooks, getBook, saveBook, deleteBook, searchBookText, convertFileSrc } from './api'

describe('API bridge', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('getBooks calls electron.getBooks', async () => {
    const mockBooks = [{ id: 1, title: 'Test Book', kind: 'epub' }]
    vi.mocked(window.electron.getBooks).mockResolvedValueOnce(mockBooks as any)
    const result = await getBooks()
    expect(window.electron.getBooks).toHaveBeenCalled()
    expect(result).toEqual(mockBooks)
  })

  it('getBook calls electron.getBook with bookId', async () => {
    const mockBook = { id: 1, title: 'Test Book' }
    vi.mocked(window.electron.getBook).mockResolvedValueOnce(mockBook as any)
    const result = await getBook({ bookId: 1 })
    expect(window.electron.getBook).toHaveBeenCalledWith(1)
    expect(result).toEqual(mockBook)
  })

  it('saveBook calls electron.saveBook', async () => {
    const book = {
      kind: 'epub',
      cover: [],
      title: 'Test',
      author: '',
      publisher: '',
      filepath: '/test.epub',
      location: '1',
      coverKind: 'png',
      version: 0
    }
    vi.mocked(window.electron.saveBook).mockResolvedValueOnce({ id: 1, ...book } as any)
    const result = await saveBook({ book: book as any })
    expect(window.electron.saveBook).toHaveBeenCalledWith(book)
    expect(result.id).toBe(1)
  })

  it('deleteBook calls electron.deleteBook', async () => {
    await deleteBook({ bookId: 1 })
    expect(window.electron.deleteBook).toHaveBeenCalledWith(1)
  })

  it('searchBookText calls electron.searchBookText', async () => {
    const results = [{ id: 1, pageNumber: 1, bookId: 1, data: 'test', snippet: 'test' }]
    vi.mocked(window.electron.searchBookText).mockResolvedValueOnce(results as any)
    const result = await searchBookText({ query: 'test', bookId: 1 })
    expect(window.electron.searchBookText).toHaveBeenCalledWith('test', 1)
    expect(result).toEqual(results)
  })

  it('convertFileSrc uses local-file:// protocol', () => {
    expect(convertFileSrc('/path/to/file.epub')).toBe('local-file:///path/to/file.epub')
    expect(convertFileSrc('file:///already/prefixed')).toBe('local-file:///already/prefixed')
    expect(convertFileSrc('local-file:///already/local')).toBe('local-file:///already/local')
    expect(convertFileSrc('http://example.com')).toBe('http://example.com')
  })
})
