export function hello(): string {
  return 'hello from mock'
}

export async function getPageCount(_path: string): Promise<number> {
  return 0
}

export interface WordRect {
  idx: number
  text: string
  x: number; y: number; w: number; h: number
}
export interface Paragraph { index: string; text: string }
export interface PageData {
  pageNumber: number
  widthPts: number
  heightPts: number
  paragraphs: Paragraph[]
  words: WordRect[]
}

export async function extractPage(_path: string, _pageNumber: number): Promise<PageData> {
  throw new Error('not mocked in this test')
}

export async function extractPages(
  _path: string,
  _options: { pageNumbers: number[] },
): Promise<PageData[]> {
  throw new Error('not mocked in this test')
}
