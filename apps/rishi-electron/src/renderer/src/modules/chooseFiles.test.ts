import { describe, it, expect, vi, beforeEach } from 'vitest'
import { chooseFiles } from './chooseFiles'

describe('chooseFiles', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('should return file paths from dialog', async () => {
    vi.mocked(window.electron.showOpenDialog).mockResolvedValueOnce({
      filePaths: ['/path/to/book.epub', '/path/to/doc.pdf']
    })
    const result = await chooseFiles()
    expect(result).toEqual(['/path/to/book.epub', '/path/to/doc.pdf'])
    expect(window.electron.showOpenDialog).toHaveBeenCalled()
  })

  it('should return empty array when no files selected', async () => {
    vi.mocked(window.electron.showOpenDialog).mockResolvedValueOnce({ filePaths: [] })
    const result = await chooseFiles()
    expect(result).toEqual([])
  })
})
