/**
 * Pin the chunk → reader-param mapping the chat citation chip relies on
 * (#68). `handleSourcePress` previously discarded `source.chunkId` /
 * `source.chapter`, so the chip just opened the reader at the user's
 * last saved position. The helper parses the chunker's per-format
 * labels back into the params the reader screens honor on mount:
 *
 *   - PDF / DJVU  → `page`
 *   - MOBI / AZW3 → `chapter` (normalised to the 0-indexed reader store)
 *   - EPUB        → `cfi` if present on the chunk, else `chapter` label
 *
 * `chunkId` always rides along so a later highlight-on-jump pass can
 * resolve back to the exact chunk without us re-touching the chat
 * screen.
 */
import { resolveSourceLocationParams } from '@/lib/chat/source-location'
import type { Book } from '@/types/book'
import type { SourceChunk } from '@/types/conversation'

function book(format: Book['format']): Pick<Book, 'id' | 'format'> {
  return { id: 'b1', format }
}

function chunk(over: Partial<SourceChunk> = {}): SourceChunk {
  return {
    chunkId: 'chunk-uuid',
    text: '',
    chapter: null,
    ...over,
  }
}

describe('resolveSourceLocationParams (#68)', () => {
  describe('PDF', () => {
    it('parses "Page N" → page', () => {
      const params = resolveSourceLocationParams(
        book('pdf'),
        chunk({ chapter: 'Page 42' }),
      )
      expect(params).toEqual({ id: 'b1', chunkId: 'chunk-uuid', page: '42' })
    })

    it('omits page when chapter is null', () => {
      const params = resolveSourceLocationParams(
        book('pdf'),
        chunk({ chapter: null }),
      )
      expect(params).toEqual({ id: 'b1', chunkId: 'chunk-uuid' })
      expect(params.page).toBeUndefined()
    })

    it('omits page when chapter is non-page text', () => {
      const params = resolveSourceLocationParams(
        book('pdf'),
        chunk({ chapter: 'Introduction' }),
      )
      expect(params).toEqual({ id: 'b1', chunkId: 'chunk-uuid' })
    })
  })

  describe('DJVU', () => {
    it('parses "Page N" → page (same as PDF)', () => {
      const params = resolveSourceLocationParams(
        book('djvu'),
        chunk({ chapter: 'Page 7' }),
      )
      expect(params.page).toBe('7')
    })
  })

  describe('MOBI', () => {
    it('parses "Chapter N" → chapter (0-indexed for the reader store)', () => {
      const params = resolveSourceLocationParams(
        book('mobi'),
        chunk({ chapter: 'Chapter 3' }),
      )
      expect(params).toEqual({
        id: 'b1',
        chunkId: 'chunk-uuid',
        chapter: '2',
      })
    })

    it('omits chapter when label is not parseable', () => {
      const params = resolveSourceLocationParams(
        book('mobi'),
        chunk({ chapter: null }),
      )
      expect(params.chapter).toBeUndefined()
    })

    it('AZW3 shares the MOBI parser', () => {
      const params = resolveSourceLocationParams(
        book('azw3'),
        chunk({ chapter: 'Chapter 5' }),
      )
      expect(params.chapter).toBe('4')
    })
  })

  describe('EPUB', () => {
    it('forwards cfiRange when present', () => {
      const params = resolveSourceLocationParams(
        book('epub'),
        chunk({ cfiRange: 'epubcfi(/6/4!/4/2/1:0)', chapter: 'Heading' }),
      )
      expect(params).toEqual({
        id: 'b1',
        chunkId: 'chunk-uuid',
        cfi: 'epubcfi(/6/4!/4/2/1:0)',
      })
      expect(params.chapter).toBeUndefined()
    })

    it('falls back to chapter heading label when no CFI', () => {
      const params = resolveSourceLocationParams(
        book('epub'),
        chunk({ chapter: 'Chapter One' }),
      )
      expect(params).toEqual({
        id: 'b1',
        chunkId: 'chunk-uuid',
        chapter: 'Chapter One',
      })
    })

    it('returns just id + chunkId when nothing positional is known', () => {
      const params = resolveSourceLocationParams(
        book('epub'),
        chunk({ chapter: null }),
      )
      expect(params).toEqual({ id: 'b1', chunkId: 'chunk-uuid' })
    })
  })
})
