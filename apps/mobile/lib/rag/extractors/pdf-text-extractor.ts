/**
 * PDF text extraction via a hidden WebView.
 *
 * RN 0.81 doesn't have a reliable in-process pdfjs path — pdfjs-dist needs
 * Web Worker, Canvas, DOMMatrix, and URL.createObjectURL, none of which RN
 * supplies. The Tauri/electron approach (`pdfjs-dist/legacy/build/pdf.mjs`
 * with `disableWorker: true`) still depends on DOM globals. So we run the
 * exact same pdfjs algorithm inside a WebView loaded from CDN — that gives
 * us a real browser environment without polyfilling RN.
 *
 * Architecture:
 *   1. RagExtractorHost (in components/RagExtractorHost.tsx) registers this
 *      extractor at app init by calling setPdfExtractor(extractPdfText).
 *   2. extractPdfText() enqueues a job. The host mounts a hidden WebView,
 *      sends the file (base64) and awaits a JSON response with the
 *      per-page paragraphs.
 *   3. We mimic the electron pageDataToParagraphs algorithm so the same
 *      page yields the same paragraphs — required for stable chunk IDs and
 *      RAG parity across platforms.
 */

import type { ExtractedPage } from '@/lib/rag/chunker'

// ---------- HTML template loaded into the WebView ----------

/**
 * The pdfjs WebView template. Loads pdfjs from CDN (legacy build, no
 * Worker), accepts a `{ type: 'load', data: <base64> }` message, and posts
 * back `{ type: 'paragraphs', pages: [{ pageNumber, paragraphs: string[] }] }`.
 *
 * The paragraph splitter mirrors electron's `pageDataToParagraphs` so the
 * mobile chunker emits the same chunks for the same PDF.
 */
export const PDF_EXTRACTOR_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<style>html,body{margin:0;padding:0;background:transparent}</style>
<script src="https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/legacy/build/pdf.min.js"></script>
<script>
const MIN_PARAGRAPH_LENGTH = 50;
const PARAGRAPH_INDEX_PER_PAGE = 10000;

// pdfjs uses a Worker by default; we disable it because WebView's worker
// support is platform-dependent.
if (window.pdfjsLib) {
  window.pdfjsLib.GlobalWorkerOptions.workerSrc = '';
}

/**
 * Mirror of electron's getParagraphThreshold: returns a Y-coordinate gap
 * that triggers a paragraph break, scaled by font height.
 */
function paragraphThreshold(item) {
  return Math.max(item.height || 0, 1) * 1.5;
}

/**
 * Mirror of electron's pageDataToParagraphs: walks the TextContent items and
 * groups them into paragraphs by hasEOL + vertical gap heuristic, then
 * filters short paragraphs and merges them backward.
 */
function pageDataToParagraphs(pageNumber, textContent) {
  const defaultDims = { bottom: Number.MAX_SAFE_INTEGER, top: Number.MIN_SAFE_INTEGER };
  let paragraphs = [];
  let current = { index: '', text: '', dimensions: defaultDims };
  let previousItem = null;
  let lineCount = 0;

  for (const item of textContent.items) {
    if (typeof item.str !== 'string') continue;
    const text = item.str;
    const textSoFar = current.text || '';

    const isVerticallySpaced = previousItem
      && Math.abs(previousItem.transform[5] - item.transform[5]) > paragraphThreshold(item)
      && item.hasEOL;
    const isThereText = textSoFar.trim().length > 0;
    const hasFiveLines = lineCount >= 5 && item.hasEOL;

    if ((isVerticallySpaced && isThereText) || hasFiveLines) {
      if (hasFiveLines) lineCount = 0;
      paragraphs.push(current);
      const idx = paragraphs.length;
      current = {
        index: (pageNumber * PARAGRAPH_INDEX_PER_PAGE + idx).toString(),
        text: '',
        dimensions: defaultDims
      };
    }
    previousItem = item;

    const idx = paragraphs.length;
    current = {
      index: (pageNumber * PARAGRAPH_INDEX_PER_PAGE + idx).toString(),
      text: current.text + text,
      dimensions: {
        top: Math.max(item.transform[5], current.dimensions.top),
        bottom: Math.min(item.transform[5], current.dimensions.bottom)
      }
    };
    if (item.hasEOL) lineCount++;
  }
  paragraphs.push(current);

  paragraphs = paragraphs
    .filter((p) => p.text.trim().length > 0)
    .filter((p, i) => i !== 0 || p.text.trim().length > MIN_PARAGRAPH_LENGTH)
    .reduce((acc, p) => {
      if (p.text.trim().length >= MIN_PARAGRAPH_LENGTH) {
        acc.push(p);
        return acc;
      }
      const last = acc.pop();
      if (!last) {
        acc.push(p);
        return acc;
      }
      last.text = last.text + '\\n' + p.text;
      acc.push(last);
      return acc;
    }, []);

  return paragraphs.map((p) => p.text.trim());
}

async function extractAllPages(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

  const task = window.pdfjsLib.getDocument({
    data: bytes,
    disableWorker: true,
    isEvalSupported: false,
    useSystemFonts: false
  });
  const doc = await task.promise;

  const pages = [];
  for (let n = 1; n <= doc.numPages; n++) {
    const page = await doc.getPage(n);
    try {
      const content = await page.getTextContent();
      pages.push({ pageNumber: n, paragraphs: pageDataToParagraphs(n, content) });
    } finally {
      page.cleanup();
    }
  }
  await doc.destroy();
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

// Signal we're ready as soon as pdfjs is loaded
function announceReady() {
  if (window.pdfjsLib) {
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

// ---------- Public extractor port ----------

/**
 * The host module (components/RagExtractorHost.tsx) supplies this driver.
 * Without it, the extractor returns [] with a warning so unit tests that
 * never mount the host don't blow up.
 */
let _driver: ((filePath: string) => Promise<ExtractedPage[]>) | null = null

export function setPdfExtractorDriver(
  driver: (filePath: string) => Promise<ExtractedPage[]>
): void {
  _driver = driver
}

export function clearPdfExtractorDriver(): void {
  _driver = null
}

export async function extractPdfText(filePath: string): Promise<ExtractedPage[]> {
  if (!_driver) {
    console.warn(
      '[pdf-text-extractor] No driver registered — mount <RagExtractorHost/> at app root'
    )
    return []
  }
  return _driver(filePath)
}
