/**
 * DJVU text extraction via a hidden WebView.
 *
 * Same hidden-WebView pattern as PDF and the existing DJVU reader screen:
 * djvu.js is loaded from CDN inside a WebView. We expose its `getPageText()`
 * API page-by-page and post the result back as a JSON array of paragraphs.
 *
 * The DJVU OCR layer is the only source of selectable text in a .djvu file,
 * and djvu.js already exposes it via Page.getText(). We split the OCR text
 * by paragraph breaks (double newlines) for chunking.
 */

import type { ExtractedPage } from '@/lib/rag/chunker'

export const DJVU_EXTRACTOR_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<style>html,body{margin:0;padding:0;background:transparent}</style>
<script src="https://cdn.jsdelivr.net/npm/djvu.js@0.5.2/dist/djvu.js"></script>
<script>
async function extractAllPages(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  const doc = new DjVu.Document(bytes.buffer);
  const pageCount = doc.getPageCount();

  const pages = [];
  for (let n = 1; n <= pageCount; n++) {
    let pageText = '';
    try {
      const page = doc.getPage(n);
      // djvu.js exposes a text layer per page via getText() in newer
      // releases. Older releases use getNormalizedText(); we try both.
      if (typeof page.getText === 'function') {
        pageText = page.getText() || '';
      } else if (typeof page.getNormalizedText === 'function') {
        pageText = page.getNormalizedText() || '';
      }
    } catch (e) {
      // Pages without an OCR layer throw; we just emit an empty page.
    }

    const paragraphs = pageText
      .split(/\\n{2,}/)
      .map((p) => p.replace(/\\s+/g, ' ').trim())
      .filter((p) => p.length > 0);

    pages.push({ pageNumber: n, paragraphs });
  }

  return pages;
}

function onMessage(rawData) {
  let msg;
  try { msg = JSON.parse(rawData); } catch (e) { return; }
  if (msg.type !== 'load' || typeof msg.data !== 'string') return;

  extractAllPages(msg.data)
    .then((pages) => {
      window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'paragraphs', pages }));
    })
    .catch((err) => {
      window.ReactNativeWebView.postMessage(JSON.stringify({
        type: 'error',
        message: (err && err.message) ? err.message : String(err)
      }));
    });
}

document.addEventListener('message', (e) => onMessage(e.data));
window.addEventListener('message', (e) => onMessage(e.data));

function announceReady() {
  if (typeof DjVu !== 'undefined' && DjVu.Document) {
    window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'ready' }));
  } else {
    setTimeout(announceReady, 50);
  }
}
announceReady();
</script>
</head>
<body></body>
</html>`

let _driver: ((filePath: string) => Promise<ExtractedPage[]>) | null = null

export function setDjvuExtractorDriver(
  driver: (filePath: string) => Promise<ExtractedPage[]>
): void {
  _driver = driver
}

export function clearDjvuExtractorDriver(): void {
  _driver = null
}

export async function extractDjvuText(filePath: string): Promise<ExtractedPage[]> {
  if (!_driver) {
    console.warn(
      '[djvu-text-extractor] No driver registered — mount <RagExtractorHost/> at app root'
    )
    return []
  }
  return _driver(filePath)
}
