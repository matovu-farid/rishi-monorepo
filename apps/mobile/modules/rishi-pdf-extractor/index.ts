import { requireNativeModule } from 'expo-modules-core'

export interface WordRect {
  idx: number
  text: string
  x: number; y: number; w: number; h: number
}

export interface Paragraph {
  index: string
  text: string
}

export interface PageData {
  pageNumber: number
  widthPts: number
  heightPts: number
  paragraphs: Paragraph[]
  words: WordRect[]
}

interface Native {
  hello(): string
  getPageCount(path: string): Promise<number>
  extractPage(path: string, pageNumber: number): Promise<PageData>
}

const NativeMod = requireNativeModule<Native>('RishiPdfExtractor')

export function hello(): string {
  return NativeMod.hello()
}

export function getPageCount(path: string): Promise<number> {
  return NativeMod.getPageCount(path)
}

export function extractPage(path: string, pageNumber: number): Promise<PageData> {
  return NativeMod.extractPage(path, pageNumber)
}

export async function extractPages(
  path: string,
  options: { pageNumbers: number[] },
): Promise<PageData[]> {
  const out: PageData[] = []
  for (const p of options.pageNumbers) {
    out.push(await NativeMod.extractPage(path, p))
  }
  return out
}
