/**
 * Pure validator for the "Go to page" modal (G09). Extracted from the
 * Modal component so its logic is unit-testable without rendering
 * react-native primitives.
 *
 * Returns the parsed page number if valid (in `[min, max]`), `null`
 * otherwise. Rejects decimals, NaN, negative values, and non-numeric
 * input. Whitespace is trimmed before parsing.
 */
export function validateGoToPageInput(
  input: string,
  min: number,
  max: number,
): number | null {
  const trimmed = input.trim()
  if (trimmed.length === 0) return null
  // Reject anything that isn't pure ASCII digits (no minus, no decimal).
  if (!/^\d+$/.test(trimmed)) return null
  const page = Number.parseInt(trimmed, 10)
  if (!Number.isInteger(page)) return null
  if (page < min || page > max) return null
  return page
}
