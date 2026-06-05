export interface WordRect { idx: number; text: string; x: number; y: number; w: number; h: number }
export interface Paragraph { index: string; text: string }
export interface PageData {
  pageNumber: number
  widthPts: number
  heightPts: number
  paragraphs: Paragraph[]
  words: WordRect[]
}

export function hello(): string { return 'hello from mock' }

// Mutable hooks so per-test code can shape the response. The runner test (Task 8)
// configures these before invoking the runner.
export const __mockState = {
  pageCount: 0,
  extractPage: async (_path: string, _pageNumber: number): Promise<PageData> => {
    throw new Error('configure __mockState.extractPage in your test')
  },
}

export async function getPageCount(_path: string): Promise<number> {
  return __mockState.pageCount
}

export async function extractPage(path: string, pageNumber: number): Promise<PageData> {
  return __mockState.extractPage(path, pageNumber)
}

export async function extractPages(
  path: string,
  options: { pageNumbers: number[] },
): Promise<PageData[]> {
  const out: PageData[] = []
  for (const p of options.pageNumbers) out.push(await __mockState.extractPage(path, p))
  return out
}
