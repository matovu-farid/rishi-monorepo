import { EpubCFI } from 'epubjs'

export interface ParagraphLike {
  index: string
  text: string
}

export interface MatchedParagraph {
  paragraphIndex: number
  charOffsetInParagraph: number
}

/**
 * Given a list of paragraphs (each with an `index` that is a CFI range string,
 * as produced by epubwrapper's `getCurrentViewParagraphs`) and a selection CFI
 * range, find the paragraph that contains the selection start and return its
 * array index plus the character offset within that paragraph's text.
 *
 * Returns null if no paragraph matches (e.g. the selection is in a different
 * spine item or the CFI strings are malformed).
 */
export function findParagraphForCfi(
  paragraphs: ParagraphLike[],
  selectionCfiRange: string
): MatchedParagraph | null {
  // Parse the selection CFI. We only need the start position for matching.
  let selCfi: EpubCFI
  try {
    selCfi = new EpubCFI(selectionCfiRange)
    // Reject obviously invalid CFIs (spinePos === -1 means parse failed)
    if ((selCfi as unknown as { spinePos: number }).spinePos === -1) return null
  } catch {
    return null
  }

  // Collapse to the selection start so compare() treats it as a point.
  const selStart = collapsedCopy(selCfi, true)

  // Reusable comparator — compare() takes two CFI args and doesn't use `this`
  // state, so any instance can serve as the comparator.
  const comparator = new EpubCFI()

  for (let i = 0; i < paragraphs.length; i++) {
    const p = paragraphs[i]

    let pCfi: EpubCFI
    try {
      pCfi = new EpubCFI(p.index)
      if ((pCfi as unknown as { spinePos: number }).spinePos === -1) continue
    } catch {
      continue
    }

    if (!pCfi.range) {
      // Non-range paragraph CFI: treat it as a point and do an exact-match
      // comparison against the selection start.
      if (comparator.compare(pCfi, selStart) === 0) {
        return {
          paragraphIndex: i,
          charOffsetInParagraph: extractStartOffset(selectionCfiRange)
        }
      }
      continue
    }

    // Build collapsed start/end points for this paragraph range.
    const pStart = collapsedCopy(pCfi, true)
    const pEnd = collapsedCopy(pCfi, false)

    // The selection start is inside this paragraph if:
    //   pStart <= selStart <= pEnd
    const afterOrAtStart = comparator.compare(pStart, selStart) <= 0
    const beforeOrAtEnd = comparator.compare(selStart, pEnd) <= 0

    if (afterOrAtStart && beforeOrAtEnd) {
      return {
        paragraphIndex: i,
        charOffsetInParagraph: extractStartOffset(selectionCfiRange)
      }
    }
  }

  return null
}

/**
 * Return a new EpubCFI that is a non-range (point) copy of `cfi`, collapsed
 * to either its start (`toStart=true`) or end (`toStart=false`).
 *
 * We clone via the string representation so that `collapse()` can mutate
 * the copy without affecting the original.
 */
function collapsedCopy(cfi: EpubCFI, toStart: boolean): EpubCFI {
  const copy = new EpubCFI(cfi.toString())
  copy.collapse(toStart)
  return copy
}

/**
 * Extract the start character offset from an epubcfi range string.
 *
 * Range CFI format:  epubcfi( BASE ! PATH , /steps:OFFSET , /steps:END )
 * We want the first numeric offset after the first comma.
 *
 * Examples:
 *   "epubcfi(/6/4!/4/4,/1:7,/1:12)"  → 7
 *   "epubcfi(/6/4!/4/2,/1:0,/1:5)"   → 0
 */
function extractStartOffset(cfiRange: string): number {
  // Match the first ":NUMBER" token that appears after a comma in the CFI.
  const m = cfiRange.match(/,(?:[^,]*):(\d+)/)
  if (!m) return 0
  const offset = parseInt(m[1], 10)
  return Number.isFinite(offset) ? offset : 0
}
