/**
 * Polyfills for older WebKit versions (Safari < 18 / macOS < 15).
 * Must be imported before any library code that uses these APIs.
 */

// URL.parse() — used by pdfjs-dist v5.x, not available in Safari < 18.
// Without this polyfill, opening any PDF crashes the app on older macOS.
if (typeof URL.parse !== "function") {
  URL.parse = function (url: string, base?: string | URL): URL | null {
    try {
      return new URL(url, base);
    } catch {
      return null;
    }
  } as typeof URL.parse;
}
