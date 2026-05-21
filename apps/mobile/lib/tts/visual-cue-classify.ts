/**
 * Lightweight visual-cue heuristic for mobile (G15).
 *
 * The electron port (`@rishi/shared/tts/visual-heuristic.detectVisualsNear`)
 * is DOM-based: it walks sibling elements scanning for `<math>`, `<figure>`,
 * `<img>` etc. Mobile's PDF reader has no DOM around its paragraphs (the
 * chunker yields plain-text paragraphs), so we run a much cheaper text-only
 * heuristic: look for LaTeX delimiters, math characters, or explicit
 * "Equation N" / "Figure N" / "Table N" prefixes.
 *
 * For EPUB/MOBI/DJVU the same heuristic applies — the chunker yields plain
 * text in all three cases.
 *
 * Returns null when the paragraph doesn't look "visual" so callers can
 * pass the result through to `setVisualCue` without an extra branch.
 */

import type { VisualKind } from '@rishi/shared/tts'

export interface VisualCueClassification {
  kind: VisualKind
  label: string
}

const LATEX_DELIM = /\$\$[\s\S]+?\$\$|\$[^\n$]+?\$|\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\]/
const MATH_OPS = /\\frac|\\sum|\\int|\\sqrt|\\alpha|\\beta|\\pi|\\theta|\\phi|\\Delta/
const EQUATION_LABEL = /\b(?:Equation|Eq\.?)\s*\d/i
const FIGURE_LABEL = /\b(?:Figure|Fig\.?)\s*\d/i
const TABLE_LABEL = /\bTable\s*\d/i

export function classifyParagraphForVisualCue(
  text: string,
): VisualCueClassification | null {
  if (!text) return null

  // Math content first — LaTeX delimiters or LaTeX command tokens.
  if (LATEX_DELIM.test(text) || MATH_OPS.test(text)) {
    return { kind: 'equation', label: 'Equation on page' }
  }
  if (EQUATION_LABEL.test(text)) {
    return { kind: 'equation', label: 'Equation on page' }
  }

  // Figure / table mentions are a soft signal — the paragraph likely
  // references a nearby graphic.
  if (FIGURE_LABEL.test(text) || TABLE_LABEL.test(text)) {
    return { kind: 'figure', label: 'Figure on page' }
  }

  return null
}
