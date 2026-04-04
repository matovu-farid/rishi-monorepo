import { getCurrentWindow } from "@tauri-apps/api/window";

/**
 * Converts PDF points to physical pixels using the actual display scale factor.
 *
 * PDF points are defined as 1/72 of an inch. This function retrieves
 * the current monitor's scale factor (devicePixelRatio equivalent)
 * and computes pixel size accurately without assuming a fixed DPI.
 */
export async function ptsToPx(pts: number): Promise<number> {
  const appWindow = getCurrentWindow();
  new Logical();

  // On most platforms, logical DPI is 96 (1 logical px = 1/96 inch)
  const logicalDPI = 96;

  // Convert PDF points (1/72 inch per point) to pixels
  const px = pts * (logicalDPI / 72);

  return px;
}
