/**
 * HTML template loaded into the PDF reader's WebView. Hosts pdfjs and
 * implements the scroll/select/highlight/goto bridge described in
 * `pdf-webview-bridge.ts`.
 *
 * Why CDN: see `lib/rag/extractors/pdf-text-extractor.ts`. pdfjs needs
 * Web Worker / Canvas / DOMMatrix / URL.createObjectURL — Expo's RN
 * runtime doesn't supply them, so we run pdfjs in a real browser context
 * inside the WebView. The legacy build with `disableWorker: true` keeps
 * the bundle self-contained.
 *
 * If CDN access becomes a problem (offline / EAS bundle constraints),
 * swap `cdn.jsdelivr.net` for a locally bundled `pdf.min.js` via
 * react-native-blob-util + a `pdf.min.js` asset. The bridge protocol is
 * unchanged.
 *
 * Note on DOM clearing: we never assign to `innerHTML` with user-provided
 * strings. The only "clearing" pattern used is `replaceChildren()` (no
 * arguments) which removes all children safely without parsing HTML.
 */

export const PDF_READER_HTML = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
<style>
  html, body { margin: 0; padding: 0; background: #1a1a1a; color: #eee;
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
    -webkit-user-select: text; -webkit-touch-callout: default; }
  #status { padding: 12px; font-size: 13px; }
  #pages { padding: 8px 0 64px 0; }
  /* Issue #231 — wrapper background is themed at runtime via
     buildReaderThemeCss / buildReaderThemeInjection. Leaving a static
     #fff here reintroduces the bright rectangle in Dark/Sepia mode
     because the inline rule would shadow the injected one on the
     initial load. */
  .page-wrapper { position: relative; margin: 8px auto;
    box-shadow: 0 1px 6px rgba(0,0,0,0.6); }
  .page-canvas { display: block; width: 100%; height: auto; }
  .text-layer { position: absolute; inset: 0; line-height: 1;
    overflow: hidden; pointer-events: auto; }
  .text-layer > span { position: absolute; white-space: pre;
    transform-origin: 0 0; color: transparent; cursor: text; }
  .text-layer ::selection { background: rgba(0, 122, 255, 0.35); }
  .highlight-layer { position: absolute; inset: 0; pointer-events: none; }
  .highlight-rect { position: absolute; pointer-events: auto; cursor: pointer;
    border-radius: 1px; }
</style>
<script src="https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/legacy/build/pdf.min.js"></script>
</head>
<body>
<div id="status">Loading PDF library…</div>
<div id="pages"></div>
<script>
(function() {
  const COLOR_HEX = {
    yellow: '#FBBF24',
    green: '#34D399',
    blue: '#60A5FA',
    pink: '#F472B6',
    none: 'transparent'
  };
  const HIGHLIGHT_OPACITY = 0.35;
  const MIN_PARAGRAPH_LENGTH = 50;
  const PARAGRAPH_INDEX_PER_PAGE = 10000;

  // pdfjs uses a Worker by default. Disabling it because WebView's worker
  // support is platform-dependent.
  if (window.pdfjsLib) {
    window.pdfjsLib.GlobalWorkerOptions.workerSrc = '';
  }

  // ---------- State ----------
  /** @type {any} */ let pdfDoc = null;
  /** @type {Array<{pageNumber:number, viewport:any, canvas:HTMLCanvasElement, textLayer:HTMLDivElement, highlightLayer:HTMLDivElement, wrapper:HTMLDivElement, rendered:boolean}>} */
  let pageEntries = [];
  /** @type {Map<string, {color:string, locator:any}>} */
  const highlights = new Map();
  /** Map of paged paragraphs cache: pageNumber -> Array<{index,text}> */
  const pageParagraphsCache = new Map();
  let currentPageNumber = 1;
  let lastReportedPage = 0;
  let pendingPageReportTimer = null;

  // ---------- Messaging ----------
  function send(msg) {
    if (window.ReactNativeWebView && window.ReactNativeWebView.postMessage) {
      window.ReactNativeWebView.postMessage(JSON.stringify(msg));
    }
  }

  function sendError(message) {
    send({ type: 'error', message });
  }

  // ---------- pdfjs helpers ----------
  function base64ToBytes(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function colorWithAlpha(name) {
    const hex = COLOR_HEX[name] || COLOR_HEX.yellow;
    if (hex === 'transparent') return hex;
    const r = parseInt(hex.slice(1,3), 16);
    const g = parseInt(hex.slice(3,5), 16);
    const b = parseInt(hex.slice(5,7), 16);
    return 'rgba(' + r + ',' + g + ',' + b + ',' + HIGHLIGHT_OPACITY + ')';
  }

  function paragraphThreshold(item) {
    return Math.max(item.height || 0, 1) * 1.5;
  }

  /**
   * Mirror of electron's pageDataToParagraphs. Produces deterministic
   * paragraph IDs so the RN side can match them against TTS chunks.
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
        if (p.text.trim().length >= MIN_PARAGRAPH_LENGTH) { acc.push(p); return acc; }
        const last = acc.pop();
        if (!last) { acc.push(p); return acc; }
        last.text = last.text + '\\n' + p.text;
        acc.push(last);
        return acc;
      }, []);
    return paragraphs.map((p) => ({ index: p.index, text: p.text.trim() }));
  }

  // ---------- Outline ----------
  async function buildOutline() {
    try {
      const items = await pdfDoc.getOutline();
      if (!items) return [];
      return await resolveOutline(items);
    } catch (e) {
      return [];
    }
  }

  async function resolveOutline(items) {
    const out = [];
    for (const item of items) {
      let pageNumber = null;
      try {
        let dest = item.dest;
        if (typeof dest === 'string') dest = await pdfDoc.getDestination(dest);
        if (Array.isArray(dest) && dest.length > 0) {
          const ref = dest[0];
          const pageIndex = await pdfDoc.getPageIndex(ref);
          pageNumber = pageIndex + 1;
        }
      } catch (e) { /* ignore */ }
      const children = item.items ? await resolveOutline(item.items) : [];
      out.push({ title: item.title || '', pageNumber, children });
    }
    return out;
  }

  // ---------- Rendering ----------
  async function loadPdf(base64) {
    const bytes = base64ToBytes(base64);
    const task = window.pdfjsLib.getDocument({
      data: bytes,
      disableWorker: true,
      isEvalSupported: false,
      useSystemFonts: false
    });
    pdfDoc = await task.promise;
    const status = document.getElementById('status');
    if (status) status.remove();
    await buildAllPageShells();
    const outline = await buildOutline();
    send({ type: 'loaded', numPages: pdfDoc.numPages, outline });
    // Eagerly render the first few pages so the user has content immediately.
    const initial = Math.min(3, pageEntries.length);
    for (let i = 0; i < initial; i++) await renderPage(pageEntries[i]);
  }

  /**
   * Create the page-wrapper / canvas / text-layer / highlight-layer DOM
   * for every page. Rendering is deferred to IntersectionObserver so
   * memory usage scales with viewport, not document size.
   */
  async function buildAllPageShells() {
    const pagesEl = document.getElementById('pages');
    pagesEl.replaceChildren();
    pageEntries = [];
    const containerWidth = pagesEl.clientWidth - 16;
    for (let n = 1; n <= pdfDoc.numPages; n++) {
      const page = await pdfDoc.getPage(n);
      const baseViewport = page.getViewport({ scale: 1 });
      const scale = containerWidth / baseViewport.width;
      const viewport = page.getViewport({ scale });
      const wrapper = document.createElement('div');
      wrapper.className = 'page-wrapper';
      wrapper.dataset.pageNumber = String(n);
      wrapper.style.width = viewport.width + 'px';
      wrapper.style.height = viewport.height + 'px';
      const canvas = document.createElement('canvas');
      canvas.className = 'page-canvas';
      canvas.width = viewport.width;
      canvas.height = viewport.height;
      const textLayer = document.createElement('div');
      textLayer.className = 'text-layer';
      const highlightLayer = document.createElement('div');
      highlightLayer.className = 'highlight-layer';
      wrapper.appendChild(canvas);
      wrapper.appendChild(textLayer);
      wrapper.appendChild(highlightLayer);
      pagesEl.appendChild(wrapper);
      pageEntries.push({
        pageNumber: n, viewport, canvas, textLayer, highlightLayer, wrapper,
        rendered: false, page
      });
    }
    setupLazyRender();
    setupScrollWatcher();
    // Re-apply any highlights queued before pages existed.
    for (const [id, h] of highlights) drawHighlight(id, h);
  }

  function setupLazyRender() {
    const io = new IntersectionObserver((entries) => {
      for (const e of entries) {
        if (!e.isIntersecting) continue;
        const pn = Number(e.target.dataset.pageNumber);
        const entry = pageEntries[pn - 1];
        if (entry && !entry.rendered) renderPage(entry);
      }
    }, { rootMargin: '300px 0px' });
    for (const entry of pageEntries) io.observe(entry.wrapper);
  }

  async function renderPage(entry) {
    if (entry.rendered) return;
    entry.rendered = true;
    try {
      const ctx = entry.canvas.getContext('2d');
      await entry.page.render({ canvasContext: ctx, viewport: entry.viewport }).promise;
      const textContent = await entry.page.getTextContent();
      renderTextLayer(entry, textContent);
      // Cache paragraphs for getPageText
      pageParagraphsCache.set(entry.pageNumber, pageDataToParagraphs(entry.pageNumber, textContent));
    } catch (e) {
      sendError('renderPage(' + entry.pageNumber + '): ' + (e && e.message ? e.message : e));
    }
  }

  function renderTextLayer(entry, textContent) {
    entry.textLayer.replaceChildren();
    for (const item of textContent.items) {
      if (typeof item.str !== 'string' || item.str.length === 0) continue;
      const span = document.createElement('span');
      span.textContent = item.str;
      // Project from PDF coords (origin bottom-left) to CSS coords (origin top-left).
      const tx = window.pdfjsLib.Util.transform(entry.viewport.transform, item.transform);
      const fontSize = Math.hypot(tx[2], tx[3]);
      const left = tx[4];
      const top = tx[5] - fontSize;
      span.style.left = left + 'px';
      span.style.top = top + 'px';
      span.style.fontSize = fontSize + 'px';
      if (item.fontName) span.style.fontFamily = item.fontName;
      entry.textLayer.appendChild(span);
    }
  }

  // ---------- Scroll → page reporting ----------
  function setupScrollWatcher() {
    document.addEventListener('scroll', schedulePageReport, { passive: true });
    window.addEventListener('scroll', schedulePageReport, { passive: true });
  }
  function schedulePageReport() {
    if (pendingPageReportTimer) return;
    pendingPageReportTimer = setTimeout(() => {
      pendingPageReportTimer = null;
      reportPage();
    }, 100);
  }
  function reportPage() {
    if (!pageEntries.length) return;
    const viewportMid = window.scrollY + window.innerHeight / 2;
    let nearest = 1, nearestDist = Infinity, offset = 0;
    for (const entry of pageEntries) {
      const top = entry.wrapper.offsetTop;
      const bottom = top + entry.wrapper.offsetHeight;
      if (viewportMid >= top && viewportMid <= bottom) {
        nearest = entry.pageNumber;
        offset = Math.max(0, window.scrollY - top);
        nearestDist = 0;
        break;
      }
      const dist = Math.min(Math.abs(viewportMid - top), Math.abs(viewportMid - bottom));
      if (dist < nearestDist) { nearest = entry.pageNumber; nearestDist = dist; offset = 0; }
    }
    if (nearest !== lastReportedPage) {
      lastReportedPage = nearest;
      currentPageNumber = nearest;
      send({ type: 'pageChanged', pageNumber: nearest, offset });
    }
  }

  // ---------- Selection ----------
  let lastSelection = null;
  let selectionTimer = null;
  document.addEventListener('selectionchange', () => {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
      if (lastSelection) {
        lastSelection = null;
        send({ type: 'selectionCleared' });
      }
      return;
    }
    // Defer until user lifts finger — selectionchange fires continuously.
    if (selectionTimer) clearTimeout(selectionTimer);
    selectionTimer = setTimeout(reportSelection, 150);
  });

  function findPageEntry(node) {
    let cur = node;
    while (cur) {
      if (cur instanceof HTMLElement && cur.classList.contains('page-wrapper')) {
        const n = Number(cur.dataset.pageNumber);
        if (Number.isFinite(n)) return pageEntries[n - 1] || null;
      }
      cur = cur.parentNode;
    }
    return null;
  }

  function rangeToLocator(range, entry) {
    const pageRect = entry.wrapper.getBoundingClientRect();
    const clientRects = Array.from(range.getClientRects());
    if (clientRects.length === 0) return null;
    const rects = [];
    for (const r of clientRects) {
      const vxLeft = r.left - pageRect.left;
      const vyTop = r.top - pageRect.top;
      const vxRight = vxLeft + r.width;
      const vyBottom = vyTop + r.height;
      const [pdfXLeft, pdfYBottom] = entry.viewport.convertToPdfPoint(vxLeft, vyBottom);
      const [pdfXRight, pdfYTop] = entry.viewport.convertToPdfPoint(vxRight, vyTop);
      const w = pdfXRight - pdfXLeft;
      const h = pdfYTop - pdfYBottom;
      if (w <= 0 || h <= 0) continue;
      rects.push({ x: pdfXLeft, y: pdfYBottom, w, h });
    }
    if (rects.length === 0) return null;
    return { page: entry.pageNumber, rects };
  }

  function reportSelection() {
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
    const range = sel.getRangeAt(0);
    const startEntry = findPageEntry(range.startContainer);
    const endEntry = findPageEntry(range.endContainer);
    if (!startEntry || !endEntry || startEntry !== endEntry) return;
    const locator = rangeToLocator(range, startEntry);
    if (!locator) return;
    const rects = Array.from(range.getClientRects());
    const first = rects[0];
    const anchor = { x: first.left + first.width / 2, y: first.top - 8 + window.scrollY };
    const text = range.toString();
    lastSelection = { locator, text };
    send({
      type: 'selection',
      pageNumber: startEntry.pageNumber,
      text, locator, anchor
    });
  }

  // ---------- Highlights ----------
  function drawHighlight(id, h) {
    const entry = pageEntries[h.locator.page - 1];
    if (!entry) return; // queued; will paint on render
    // Clean previous
    const existing = entry.highlightLayer.querySelectorAll('[data-highlight-id="' + id + '"]');
    for (const el of existing) el.remove();
    const bg = colorWithAlpha(h.color);
    for (const r of h.locator.rects) {
      const [vxLeft, vyBottom] = entry.viewport.convertToViewportPoint(r.x, r.y);
      const [vxRight, vyTop] = entry.viewport.convertToViewportPoint(r.x + r.w, r.y + r.h);
      const div = document.createElement('div');
      div.className = 'highlight-rect';
      div.dataset.highlightId = id;
      div.style.left = vxLeft + 'px';
      div.style.top = vyTop + 'px';
      div.style.width = (vxRight - vxLeft) + 'px';
      div.style.height = (vyBottom - vyTop) + 'px';
      div.style.backgroundColor = bg;
      div.addEventListener('click', (e) => {
        const rect = div.getBoundingClientRect();
        send({
          type: 'highlightTapped',
          highlightId: id,
          anchor: { x: rect.left + rect.width / 2, y: rect.top + window.scrollY }
        });
        e.stopPropagation();
      });
      entry.highlightLayer.appendChild(div);
    }
  }

  function removeHighlight(id) {
    highlights.delete(id);
    for (const entry of pageEntries) {
      const existing = entry.highlightLayer.querySelectorAll('[data-highlight-id="' + id + '"]');
      for (const el of existing) el.remove();
    }
  }

  function setHighlights(list) {
    // Remove all existing.
    for (const entry of pageEntries) entry.highlightLayer.replaceChildren();
    highlights.clear();
    for (const h of list) {
      highlights.set(h.id, { color: h.color, locator: h.locator });
      drawHighlight(h.id, h);
    }
  }

  // ---------- Commands ----------
  function goToPage(page, offset) {
    const entry = pageEntries[page - 1];
    if (!entry) return;
    const top = entry.wrapper.offsetTop + (offset || 0);
    window.scrollTo({ top, behavior: 'auto' });
    // Report immediately so the RN store updates without waiting for the
    // scroll watcher's debounce.
    currentPageNumber = page;
    lastReportedPage = page;
    send({ type: 'pageChanged', pageNumber: page, offset: offset || 0 });
  }

  async function getPageText(requestId, pageNumber) {
    let paragraphs = pageParagraphsCache.get(pageNumber);
    if (!paragraphs) {
      const entry = pageEntries[pageNumber - 1];
      if (entry) {
        try {
          const textContent = await entry.page.getTextContent();
          paragraphs = pageDataToParagraphs(pageNumber, textContent);
          pageParagraphsCache.set(pageNumber, paragraphs);
        } catch (e) { paragraphs = []; }
      } else paragraphs = [];
    }
    send({ type: 'pageText', requestId, pageNumber, paragraphs });
  }

  function handleCommand(rawData) {
    let msg;
    try { msg = JSON.parse(rawData); } catch (e) { return; }
    if (!msg || typeof msg.type !== 'string') return;
    switch (msg.type) {
      case 'load': loadPdf(msg.data).catch((e) => sendError('load: ' + (e && e.message ? e.message : e))); break;
      case 'goToPage': goToPage(msg.page, msg.offset); break;
      case 'addHighlight':
        highlights.set(msg.id, { color: msg.color, locator: msg.locator });
        drawHighlight(msg.id, { color: msg.color, locator: msg.locator });
        break;
      case 'removeHighlight': removeHighlight(msg.id); break;
      case 'setHighlights': setHighlights(msg.highlights || []); break;
      case 'getPageText': getPageText(msg.requestId, msg.pageNumber); break;
      case 'highlightSelection': {
        if (!lastSelection) return;
        highlights.set(msg.id, { color: msg.color, locator: lastSelection.locator });
        drawHighlight(msg.id, { color: msg.color, locator: lastSelection.locator });
        // Clear selection so the user can see the highlight overlay.
        const sel = window.getSelection();
        if (sel) sel.removeAllRanges();
        lastSelection = null;
        send({ type: 'selectionCleared' });
        break;
      }
      case 'clearSelection': {
        const sel = window.getSelection();
        if (sel) sel.removeAllRanges();
        lastSelection = null;
        send({ type: 'selectionCleared' });
        break;
      }
    }
  }

  document.addEventListener('message', (e) => handleCommand(e.data));
  window.addEventListener('message', (e) => handleCommand(e.data));

  // Announce ready when pdfjs is loaded.
  function announceReady() {
    if (window.pdfjsLib) send({ type: 'ready' });
    else setTimeout(announceReady, 50);
  }
  announceReady();
})();
</script>
</body>
</html>`
