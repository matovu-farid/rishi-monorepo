import { useEffect, useState } from 'react';
import * as pdfjs from 'pdfjs-dist';
import type { PDFDocumentProxy } from 'pdfjs-dist';
import type { AdapterState, PagedContent, TextItem, TOCEntry, Location } from '@/types/reader';
import { ensurePdfWorker } from './pdfWorker';

export function usePdfAdapter(filepath: string): AdapterState {
  const [state, setState] = useState<AdapterState>({ content: null, status: 'loading' });

  useEffect(() => {
    ensurePdfWorker();
    let doc: PDFDocumentProxy | null = null;
    let cancelled = false;
    void (async () => {
      try {
        doc = await pdfjs.getDocument(filepath).promise;
        if (cancelled) { void doc.destroy(); return; }
        setState({ content: await buildContent(doc), status: 'ready' });
      } catch (error) {
        if (cancelled) return;
        setState({ content: null, status: 'error', error: error as Error });
      }
    })();
    return () => {
      cancelled = true;
      void doc?.destroy();
    };
  }, [filepath]);

  return state;
}

async function buildContent(doc: PDFDocumentProxy): Promise<PagedContent> {
  const [metadata, outline] = await Promise.all([doc.getMetadata(), doc.getOutline()]);
  const info = (metadata.info ?? {}) as { Title?: string; Author?: string; Producer?: string };

  return {
    kind: 'paged',
    metadata: {
      title: info.Title,
      author: info.Author,
      publisher: info.Producer,
      tableOfContents: outline ? await convertOutline(outline, doc) : [],
    },
    pageCount: doc.numPages,
    renderPage: async (pageIndex, viewport) => {
      const page = await doc.getPage(pageIndex + 1);
      const vp = page.getViewport({ scale: viewport.scale, rotation: viewport.rotation ?? 0 });
      const canvas = document.createElement('canvas');
      canvas.width = vp.width;
      canvas.height = vp.height;
      const ctx = canvas.getContext('2d');
      if (!ctx) throw new Error('Canvas 2D context unavailable');
      await page.render({ canvas, canvasContext: ctx, viewport: vp }).promise;
      const textContent = await page.getTextContent();
      type PdfTextItem = { str: string; transform: number[]; width: number; height: number };
      const textItems: TextItem[] = (textContent.items as unknown[])
        .filter((it): it is PdfTextItem => typeof it === 'object' && it !== null && 'str' in it && 'transform' in it)
        .map((it) => ({
          text: it.str,
          bbox: { x: it.transform[4], y: vp.height - it.transform[5], width: it.width, height: it.height },
        }));
      return {
        source: { kind: 'canvas', canvas },
        textItems,
        width: vp.width,
        height: vp.height,
      };
    },
  };
}

async function convertOutline(
  outline: Array<{ title: string; dest?: unknown; items?: unknown }>,
  doc: PDFDocumentProxy,
): Promise<TOCEntry[]> {
  const out: TOCEntry[] = [];
  for (const item of outline) {
    const pageIndex = await resolveDestPage(item.dest, doc);
    out.push({
      title: item.title,
      location: { kind: 'paged', pageIndex } as Extract<Location, { kind: 'paged' }>,
      children: item.items ? await convertOutline(item.items as never, doc) : [],
    });
  }
  return out;
}

async function resolveDestPage(dest: unknown, doc: PDFDocumentProxy): Promise<number> {
  try {
    const resolved = typeof dest === 'string' ? await doc.getDestination(dest) : (dest as unknown[]);
    if (!resolved || !Array.isArray(resolved) || resolved.length === 0) return 0;
    const ref = resolved[0];
    const pageIndex = await doc.getPageIndex(ref as never);
    return pageIndex;
  } catch {
    return 0;
  }
}
