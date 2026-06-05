import { __mockState, extractPage, type PageData } from 'rishi-pdf-extractor'

describe('rishi-pdf-extractor contract', () => {
  beforeEach(() => {
    __mockState.extractPage = async (_, n) => ({
      pageNumber: n,
      widthPts: 612,
      heightPts: 792,
      paragraphs: [{ index: `${n * 10000}`, text: 'hello world' }],
      words: [],
    })
  })

  it('returns paragraphs with deterministic indices derived from pageNumber', async () => {
    const data: PageData = await extractPage('/tmp/a.pdf', 5)
    expect(data.paragraphs).toHaveLength(1)
    expect(data.paragraphs[0].index).toBe('50000')
  })

  it('returns the page size in PDF points', async () => {
    const data = await extractPage('/tmp/a.pdf', 1)
    expect(data.widthPts).toBe(612)
    expect(data.heightPts).toBe(792)
  })

  it('returns words as an array (empty in Task 4; populated in Task 6)', async () => {
    const data = await extractPage('/tmp/a.pdf', 1)
    expect(Array.isArray(data.words)).toBe(true)
  })
})
