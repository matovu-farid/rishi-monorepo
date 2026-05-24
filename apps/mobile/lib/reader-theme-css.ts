/**
 * Build the CSS + `injectJavaScript` snippet used by the MOBI / DJVU /
 * PDF WebView readers to apply a reader theme.
 *
 * Issue #47 — the WebView-backed readers (MOBI, DJVU, PDF) used to
 * persist a theme via `saveReaderSettings` but never forwarded it into
 * the WebView. Dark-mode users were stuck on the white default. This
 * helper centralises the CSS so every reader injects an identical
 * stylesheet keyed by the active `ThemeName`.
 *
 * Design notes:
 *   - We render via a `<style id="rishi-theme">` element so repeated
 *     injections replace the previous stylesheet instead of stacking.
 *   - We touch `body` background/color *and* the canvas wrapper used by
 *     DJVU (`body` is the canvas container) and the pdfjs viewer
 *     (`#viewerContainer`, `.pdfViewer`) so all three readers visibly
 *     re-theme on a single helper call.
 *   - The returned snippet ends in `true;` — react-native-webview
 *     requires `injectJavaScript` to end in a JS expression, and
 *     omitting the trailing expression triggers a runtime warning on
 *     iOS (verified against react-native-webview 13.x).
 */

import type { ReaderTheme } from '@/types/book'

/**
 * Return a JavaScript snippet that, when injected via
 * `WebView.injectJavaScript`, swaps the active reader theme inside the
 * WebView. The snippet is idempotent — repeated calls replace the
 * `<style id="rishi-theme">` element rather than appending new ones.
 */
export function buildReaderThemeInjection(theme: ReaderTheme): string {
  const css = buildReaderThemeCss(theme)
  // JSON.stringify handles escaping (quotes, newlines, backslashes) so
  // the injected JS literal is always valid no matter what colour
  // syntax future themes use.
  const cssLiteral = JSON.stringify(css)
  return [
    '(function(){',
    '  try {',
    '    var id = "rishi-theme";',
    '    var existing = document.getElementById(id);',
    '    if (existing) existing.parentNode.removeChild(existing);',
    '    var style = document.createElement("style");',
    '    style.id = id;',
    `    style.textContent = ${cssLiteral};`,
    '    (document.head || document.documentElement).appendChild(style);',
    '  } catch (e) { /* swallow — best-effort theme swap */ }',
    '})();',
    'true;',
  ].join('\n')
}

/**
 * Build the raw CSS for a theme. Exported separately so callers can
 * embed it inline in a static HTML template (initial load) while still
 * using the same colour values as runtime updates.
 */
export function buildReaderThemeCss(theme: ReaderTheme): string {
  const bg = theme.background
  const fg = theme.color
  return [
    `html, body { background: ${bg} !important; color: ${fg} !important; }`,
    // pdfjs viewer chrome — keep page chrome consistent with body.
    `#viewerContainer, .pdfViewer { background: ${bg} !important; }`,
    // MOBI parser content wrapper.
    `#content, #content * { color: ${fg} !important; }`,
    `#content a { color: ${fg} !important; }`,
  ].join('\n')
}
