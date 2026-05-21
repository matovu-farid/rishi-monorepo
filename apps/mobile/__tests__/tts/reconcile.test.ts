/**
 * Pure reconcileTtsHighlight tests. The reconciler is format-agnostic;
 * each format-specific test file just adapts its own chunk shape into
 * the `ChunkLike` interface.
 */
import { reconcileTtsHighlight } from '@/lib/tts/reconcile'

const chunks = [
  { id: 'p0', chunkIndex: 0 },
  { id: 'p1', chunkIndex: 1 },
  { id: 'p2', chunkIndex: 2 },
]

describe('reconcileTtsHighlight (format-agnostic)', () => {
  it('returns -1 when there is no active paragraph', () => {
    const r = reconcileTtsHighlight(chunks, null)
    expect(r.activeChunkIndex).toBe(-1)
    expect(r.activeChunkId).toBeNull()
  })

  it('returns the matching chunk index when active paragraph matches a chunk id', () => {
    const r = reconcileTtsHighlight(chunks, { index: 'p1', text: 'second' })
    expect(r.activeChunkIndex).toBe(1)
    expect(r.activeChunkId).toBe('p1')
  })

  it('returns -1 when active paragraph index does not match any chunk', () => {
    const r = reconcileTtsHighlight(chunks, {
      index: 'nonexistent',
      text: 'orphan',
    })
    expect(r.activeChunkIndex).toBe(-1)
    expect(r.activeChunkId).toBeNull()
  })

  it('works with empty chunk lists (silent clear)', () => {
    const r = reconcileTtsHighlight([], { index: 'p0', text: 'x' })
    expect(r.activeChunkIndex).toBe(-1)
  })

  it('finds the first matching chunk (chunk ids should be unique)', () => {
    const r = reconcileTtsHighlight(chunks, { index: 'p2', text: 'third' })
    expect(r.activeChunkIndex).toBe(2)
  })
})

// ── Format-specific adapters: PDF / MOBI / AZW3 / DJVU ───────────────────────
//
// In production, each format's chunk row from the SQLite `chunks` table
// is shaped `{ id, text, chunkIndex, chapter }`. The reconciler only
// cares about `id` and `chunkIndex` — these tests prove the same code
// works against each format's chunk shape (no per-format coercion
// needed).

describe('reconcileTtsHighlight — PDF chunks', () => {
  it('highlights the PDF page 5 paragraph 2 chunk', () => {
    const pdfChunks = [
      { id: 'pdf:5:0', chunkIndex: 100, chapter: 'Chapter 1', text: 'A' },
      { id: 'pdf:5:1', chunkIndex: 101, chapter: 'Chapter 1', text: 'B' },
      { id: 'pdf:5:2', chunkIndex: 102, chapter: 'Chapter 1', text: 'C' },
    ]
    const r = reconcileTtsHighlight(pdfChunks, { index: 'pdf:5:2', text: 'C' })
    expect(r.activeChunkIndex).toBe(102)
    expect(r.activeChunkId).toBe('pdf:5:2')
  })
})

describe('reconcileTtsHighlight — MOBI/AZW3 chunks', () => {
  it('matches by string id regardless of underlying numeric encoding', () => {
    const mobiChunks = [
      { id: 'mobi-ch0-p0', chunkIndex: 0, chapter: null, text: 'x' },
      { id: 'mobi-ch0-p1', chunkIndex: 1, chapter: null, text: 'y' },
    ]
    const r = reconcileTtsHighlight(mobiChunks, {
      index: 'mobi-ch0-p1',
      text: 'y',
    })
    expect(r.activeChunkIndex).toBe(1)
  })
})

describe('reconcileTtsHighlight — DJVU chunks', () => {
  it('treats djvu chunks the same as any other format', () => {
    const djvuChunks = [
      { id: 'djvu:p1', chunkIndex: 0, chapter: 'Page 1', text: 'a' },
      { id: 'djvu:p2', chunkIndex: 1, chapter: 'Page 2', text: 'b' },
    ]
    const r = reconcileTtsHighlight(djvuChunks, { index: 'djvu:p2', text: 'b' })
    expect(r.activeChunkIndex).toBe(1)
  })
})
