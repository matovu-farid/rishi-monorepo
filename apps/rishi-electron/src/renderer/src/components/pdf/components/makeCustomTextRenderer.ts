type Transform = [number, number, number, number, number, number]

/**
 * Pure factory for the PDF text-layer renderer. Extracted from the component
 * closure so the declarative TTS-highlight behavior can be unit-tested
 * without standing up a full `<PdfPage>` (which needs a real pdf.js page).
 *
 * Contract:
 *  - If `highlightedParagraph` is null, returns plain text for every item.
 *  - If `highlightedParagraph` is set and the text item's y-coordinate (the
 *    6th entry of the transform matrix) falls within
 *    `[dimensions.bottom, dimensions.top]`, wraps the text in `<mark>`.
 *  - Items without a transform always pass through as plain text.
 */
export function makeCustomTextRenderer(
  highlightedParagraph: { dimensions: { top: number; bottom: number } } | null
) {
  return ({ str, transform }: { str: string; transform: number[] | undefined }): string => {
    if (!highlightedParagraph || !transform) return str
    const t = transform as Transform
    const isBelowOrEqualTop = t[5] <= highlightedParagraph.dimensions.top
    const isAboveOrEqualBottom = t[5] >= highlightedParagraph.dimensions.bottom
    if (isBelowOrEqualTop && isAboveOrEqualBottom) {
      return `<mark style="background-color: rgb(255,255,204);">${str}</mark>`
    }
    return str
  }
}
