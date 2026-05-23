import type { Paragraph } from '@/stores/pdfStore'
import type { TextContent } from 'react-pdf'
import type { TextMarkedContent } from 'pdfjs-dist/types/src/display/api'

import type { TextItem } from 'pdfjs-dist/types/src/display/api'

import { getParagraphThreshold } from '../utils/getParagraphThreshold'

const MIN_PARAGRAPH_LENGTH = 50

const PARAGRAPH_INDEX_PER_PAGE = 10000

export interface ParagraphWithItemIndices {
  paragraph: Paragraph
  itemIndices: number[]
}

function isTextItem(item: TextItem | TextMarkedContent): item is TextItem {
  return 'str' in item
}

/**
 * Raw paragraph assembly: walks `pageData.items` and groups them into
 * paragraphs using the vertical-spacing / line-count heuristic. Returns the
 * unfiltered slots plus the contributing item indices in parallel — both the
 * mask-aware paragraph filter and the suffix-matcher footer detector consume
 * the same assembled output, so we keep this one canonical implementation.
 */
function assembleRawParagraphs(
  pageNumber: number,
  pageData: TextContent
): ParagraphWithItemIndices[] {
  const defaultDimensions = {
    bottom: Number.MAX_SAFE_INTEGER,
    top: Number.MIN_SAFE_INTEGER
  }
  const paragraphsSoFarArray: Paragraph[] = []
  const paragraphItemIndices: number[][] = []
  let currentParagraphItems: number[] = []

  let paragraghSoFar: Paragraph = {
    index: '',
    text: '',
    dimensions: defaultDimensions
  }

  const items = pageData.items
  let previousItem: TextItem | null = null
  let lineCount = 0
  for (let itemIdx = 0; itemIdx < items.length; itemIdx++) {
    const item = items[itemIdx]
    if (!isTextItem(item)) continue

    const text = item.str
    const textSoFar = paragraghSoFar.text || ''

    const isVerticallySpaced =
      previousItem &&
      Math.abs(previousItem.transform[5] - item.transform[5]) > getParagraphThreshold(item) &&
      item.hasEOL
    const isThereText = textSoFar.trim().length > 0

    const hasAtlestFiveLines = lineCount >= 5 && item.hasEOL

    if ((isVerticallySpaced && isThereText) || hasAtlestFiveLines) {
      if (hasAtlestFiveLines) {
        lineCount = 0
      }
      paragraphsSoFarArray.push(paragraghSoFar)
      paragraphItemIndices.push(currentParagraphItems)
      currentParagraphItems = []
      // Calculate index AFTER push, so it's incremented correctly
      const currentIdx = paragraphsSoFarArray.length
      const pargraphIdx = (pageNumber * PARAGRAPH_INDEX_PER_PAGE + currentIdx).toString()
      // reset the paragraph so far
      paragraghSoFar = {
        index: pargraphIdx,
        text: '',
        dimensions: defaultDimensions
      }
    }
    previousItem = item

    // Calculate index on each iteration for the accumulating paragraph
    const currentIdx = paragraphsSoFarArray.length
    const pargraphIdx = (pageNumber * PARAGRAPH_INDEX_PER_PAGE + currentIdx).toString()

    paragraghSoFar = {
      index: pargraphIdx,
      text: paragraghSoFar.text + text,
      dimensions: {
        top: Math.max(item.transform[5], paragraghSoFar.dimensions.top),
        bottom: Math.min(
          // item.transform[5] - item.height,
          item.transform[5],
          paragraghSoFar.dimensions.bottom
        )
      }
    }
    currentParagraphItems.push(itemIdx)
    if (item.hasEOL) {
      lineCount++
    }
  }

  paragraphsSoFarArray.push(paragraghSoFar)
  paragraphItemIndices.push(currentParagraphItems)

  const out: ParagraphWithItemIndices[] = []
  for (let i = 0; i < paragraphsSoFarArray.length; i++) {
    out.push({ paragraph: paragraphsSoFarArray[i], itemIndices: paragraphItemIndices[i] })
  }
  return out
}

/**
 * Public sibling of `pageDataToParagraphs` that exposes the per-paragraph
 * item-index ranges BEFORE mask filtering and post-filters run. Consumed by
 * the suffix-matcher footer detector, which needs spatial + item-index info
 * on the raw layout.
 */
export function pageDataToParagraphsWithItemIndices(
  pageNumber: number,
  pageData: TextContent
): ParagraphWithItemIndices[] {
  return assembleRawParagraphs(pageNumber, pageData)
}

export function pageDataToParagraphs(
  pageNumber: number,
  pageData: TextContent,
  maskedItemIndices?: ReadonlySet<number>
): Paragraph[] {
  const assembled = assembleRawParagraphs(pageNumber, pageData)
  let paragraphsSoFarArray: Paragraph[] = assembled.map((a) => a.paragraph)
  const paragraphItemIndices: number[][] = assembled.map((a) => a.itemIndices)

  // Mask filter: drop paragraphs whose items are ALL in the mask while
  // KEEPING the slot — survivors retain their original index strings so
  // resume bookmarks stay stable across runs with/without detection.
  if (maskedItemIndices && maskedItemIndices.size > 0) {
    const kept: Paragraph[] = []
    for (let i = 0; i < paragraphsSoFarArray.length; i++) {
      const idxs = paragraphItemIndices[i]
      if (idxs.length > 0 && idxs.every((ix) => maskedItemIndices.has(ix))) {
        continue
      }
      kept.push(paragraphsSoFarArray[i])
    }
    paragraphsSoFarArray = kept
  }

  paragraphsSoFarArray = paragraphsSoFarArray
    .filter((paragraph) => paragraph.text.trim().length > 0)
    // try best effort to remove headers
    .filter(
      (paragraph, index) => index !== 0 || paragraph.text.trim().length > MIN_PARAGRAPH_LENGTH
    )

    // remove paragraphs that are too short
    .reduce<Paragraph[]>((acc, paragraph) => {
      const isParagraphTooShort = paragraph.text.trim().length < MIN_PARAGRAPH_LENGTH
      // if the paragraph is not too short, add it to the accumulator
      if (!isParagraphTooShort) {
        acc.push(paragraph)
        return acc
      }

      const lastParagraph = acc.pop()
      // if there is no last paragraph, add the paragraph to the accumulator
      if (!lastParagraph) {
        acc.push(paragraph)
        return acc
      }
      // merge the paragraph with the last paragraph
      lastParagraph.text = lastParagraph.text + '\n' + paragraph.text
      lastParagraph.dimensions = {
        top: Math.max(paragraph.dimensions.top, lastParagraph.dimensions.top),
        bottom: Math.min(paragraph.dimensions.bottom, lastParagraph.dimensions.bottom)
      }
      acc.push(lastParagraph)

      return acc
    }, [])
  return paragraphsSoFarArray
}
