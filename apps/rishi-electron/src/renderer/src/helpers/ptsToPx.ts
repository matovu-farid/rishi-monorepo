/**
 * Converts PDF points to physical pixels.
 *
 * PDF points are defined as 1/72 of an inch. This function computes
 * pixel size using the standard logical DPI of 96 (1 logical px = 1/96 inch).
 */
export function ptsToPx(pts: number): number {
  // On most platforms, logical DPI is 96 (1 logical px = 1/96 inch)
  const logicalDPI = 96

  // Convert PDF points (1/72 inch per point) to pixels
  const px = pts * (logicalDPI / 72)

  return px
}
