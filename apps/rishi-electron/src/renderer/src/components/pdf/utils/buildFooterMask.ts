import type { TextContent } from 'react-pdf'
import { repetitionStrategy } from './footerStrategies/repetitionStrategy'
import { suffixStrategy } from './footerStrategies/suffixStrategy'
import { expandToLineMates } from './footerStrategies/expandToLineMates'
import { unionMasks } from './footerStrategies/types'
import type { FooterStrategy, FooterPostProcessor } from './footerStrategies/types'
// NOTE: `bottomBandPositionStrategy` is intentionally NOT in the strategy
// list. It silences any y-bin with text on ≥30% of pages regardless of
// content — which over-masks legitimate body text on prose-heavy PDFs
// where the last paragraph wraps to the bottom on enough pages. The
// chapter-title footer case it was meant to catch is already handled by
// the repetitionStrategy → expandToLineMates path (the page number anchors
// the baseline and the title is pulled in by line-mate expansion). The
// file is kept so it can be revived behind a tighter threshold + font-size
// signal if a real footers-without-page-numbers case shows up.

/**
 * Per-book footer mask: page number -> set of item indices on that page
 * that the heuristic flagged as running-footer chrome.
 *
 * The set is interpreted by `pageDataToParagraphs` (mask-aware path) which
 * drops paragraphs composed entirely of masked items WHILE preserving the
 * dropped paragraph's index slot — resume bookmarks stay stable across builds.
 */
export type FooterMask = Map<number, Set<number>>

export interface PageScanInput {
  pageNumber: number
  content: TextContent
  /** Page height in PDF user-space units (page.view[3] - page.view[1]). */
  viewportHeight: number
}

export interface BuildFooterMaskOptions {
  minPages: number
  bottomBandPct: number
  maxFooterLines: number
  maxCharsPerLine: number
  repetitionThreshold: number
  yBinPct: number
}

export const DEFAULT_FOOTER_MASK_OPTIONS: BuildFooterMaskOptions = {
  minPages: 8,
  // Bottom 25% catches multi-line copyright blocks that sit above the
  // page number — observed on Cengage textbooks where the block extends
  // ~20% from the bottom.
  bottomBandPct: 0.25,
  // Cap at 5 lines so a 3-line copyright + page number + running title
  // can all be masked. Repetition threshold (30%) still does the heavy
  // lifting against false positives.
  maxFooterLines: 5,
  // Long copyright lines run 180-220 chars; the strict 80-char cap was
  // dropping real chrome. Repetition is the trustworthy signal here, so
  // we tolerate longer matches.
  maxCharsPerLine: 250,
  repetitionThreshold: 0.3,
  yBinPct: 0.02
}

export const MIN_PAGES_FOR_DETECTION = DEFAULT_FOOTER_MASK_OPTIONS.minPages

const PURE_NUMERIC_RE = /^[ivxlcdm\d]+$/i
const EMBEDDED_NUMBER_RE = /\b\d+\b/g

/**
 * Collapse trivial variants so "Page 47" / "Page 48" / "47 of 350" all hash
 * to the same repetition key. Pure numeric or pure roman-numeral strings
 * become a sentinel; mixed text has standalone digit runs (word-boundary
 * anchored) replaced with the same sentinel.
 */
export function normalizeFooterToken(s: string): string {
  const trimmed = s.trim().replace(/\s+/g, ' ').toLowerCase()
  if (PURE_NUMERIC_RE.test(trimmed)) return '__NUM__'
  return trimmed.replace(EMBEDDED_NUMBER_RE, '__NUM__')
}

// Strategies are referenced via getters to side-step a circular import.
// This file imports each strategy module; each strategy module imports
// shared types/helpers (FooterMask, PageScanInput, BuildFooterMaskOptions,
// normalizeFooterToken) from this file. When a strategy module is imported
// FIRST (e.g., by a test that imports it directly), evaluation enters the
// cycle and the strategy bindings are still in the TDZ when the orchestrator
// array is built — `STRATEGIES.map(s => s(...))` then crashes with
// `TypeError: s is not a function`. Wrapping each reference in a thunk
// defers the binding read to call time, by which point both modules are
// fully initialised. DO NOT REMOVE THESE THUNKS without first extracting
// the shared types into a separate `shared.ts` module that both sides
// import from (which breaks the cycle structurally).
const STRATEGIES: Array<() => FooterStrategy> = [
  () => repetitionStrategy,
  () => suffixStrategy
]
const POST_PROCESSORS: Array<() => FooterPostProcessor> = [() => expandToLineMates]

export function buildFooterMask(
  pages: PageScanInput[],
  opts: Partial<BuildFooterMaskOptions> = {}
): FooterMask {
  const o: BuildFooterMaskOptions = { ...DEFAULT_FOOTER_MASK_OPTIONS, ...opts }
  if (pages.length < o.minPages) return new Map()

  const partial = STRATEGIES.map((get) => get()(pages, o))
  let merged = unionMasks(partial)
  for (const get of POST_PROCESSORS) merged = get()(merged, pages, o)
  return merged
}
