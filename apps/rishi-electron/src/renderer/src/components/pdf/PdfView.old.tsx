/**
 * @deprecated This file is the old simplified PdfView. It has been replaced by
 * the full Tauri-ported PDF rendering system in ./components/pdf.tsx.
 * Kept as a backup for reference.
 */
import { useState, useCallback, useEffect } from "react";
import { Document, Page, pdfjs } from "react-pdf";
import { usePdfStore } from "@/stores/pdfStore";
import { ArrowLeft, ChevronLeft, ChevronRight } from "lucide-react";
import { Link } from "@tanstack/react-router";
import type { Book } from "@/lib/api";
import Loader from "../Loader";
import "react-pdf/dist/Page/TextLayer.css";
import "react-pdf/dist/Page/AnnotationLayer.css";

// Configure PDF.js worker - use the local copy from node_modules
// react-pdf v10 ships pdfjs-dist as a dep, Vite can resolve the worker
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  "pdfjs-dist/build/pdf.worker.min.mjs",
  import.meta.url,
).toString();

interface Props {
  filepath: string;
  book: Book;
}

export default function PdfViewOld({ filepath: _filepath, book }: Props) {
  const pageNumber = usePdfStore((s) => s.pageNumber) || 1;
  const pageCount = usePdfStore((s) => s.pageCount);
  const setPageNumber = usePdfStore((s) => s.setPageNumber);
  const setPageCount = usePdfStore((s) => s.setPageCount);
  const setPdfDocumentProxy = usePdfStore((s) => s.setPdfDocumentProxy);

  const [pdfData, setPdfData] = useState<{ data: Uint8Array } | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoadError(null);
    setPdfData(null);

    console.log("[pdf] Loading file:", book.filepath);

    window.electron
      .readFile(book.filepath)
      .then((data) => {
        if (cancelled) return;
        console.log("[pdf] readFile returned:", typeof data, data instanceof ArrayBuffer ? "ArrayBuffer" : "other", "byteLength:", (data as ArrayBuffer)?.byteLength);

        let arr: Uint8Array;
        if (data instanceof ArrayBuffer) {
          arr = new Uint8Array(data);
        } else if (ArrayBuffer.isView(data)) {
          arr = new Uint8Array((data as any).buffer, (data as any).byteOffset, (data as any).byteLength);
        } else {
          // Fallback: data might be a serialized object with numeric keys
          const values = Object.values(data as any) as number[];
          arr = new Uint8Array(values);
        }

        console.log("[pdf] Uint8Array length:", arr.length, "first bytes:", arr.slice(0, 8));

        // Check PDF magic bytes: %PDF
        if (arr.length > 4 && arr[0] === 0x25 && arr[1] === 0x50 && arr[2] === 0x44 && arr[3] === 0x46) {
          console.log("[pdf] Valid PDF header detected");
        } else {
          console.warn("[pdf] WARNING: Does not start with %PDF header. First 4 bytes:", arr[0], arr[1], arr[2], arr[3]);
        }

        setPdfData({ data: arr });
      })
      .catch((err) => {
        if (!cancelled) {
          console.error("[pdf] readFile failed:", err);
          setLoadError(err instanceof Error ? err.message : String(err));
        }
      });

    return () => { cancelled = true; };
  }, [book.filepath]);

  const onDocumentLoadSuccess = useCallback(
    (pdf: any) => {
      console.log("[pdf] Document loaded, pages:", pdf.numPages);
      setPageCount(pdf.numPages);
      setPdfDocumentProxy(pdf);
      if (book.currentPage) setPageNumber(book.currentPage);
      else setPageNumber(1);
    },
    [book.currentPage, setPageCount, setPageNumber, setPdfDocumentProxy]
  );

  const onDocumentLoadError = useCallback((error: Error) => {
    console.error("[pdf] Document load error:", error.message, error);
    setLoadError(error.message);
  }, []);

  return (
    <div className="flex flex-col h-screen">
      <div data-electron-drag-region className="flex items-center gap-2 px-4 py-2 border-b border-gray-200">
        <Link to="/" className="p-2 hover:bg-gray-100 rounded-lg" onClick={() => {
          try { localStorage.setItem("lastReadBookId", book.id.toString()); window.dispatchEvent(new Event("lastReadBookChanged")); } catch {}
        }}>
          <ArrowLeft size={20} />
        </Link>
        <span className="text-sm font-medium truncate flex-1">{book.title}</span>
        <div className="flex items-center gap-1">
          <button onClick={() => setPageNumber(Math.max(1, pageNumber - 1))} disabled={pageNumber <= 1}
            className="p-1 hover:bg-gray-100 rounded disabled:opacity-30"><ChevronLeft size={18} /></button>
          <span className="text-xs text-gray-500 min-w-[60px] text-center">{pageNumber} / {pageCount}</span>
          <button onClick={() => setPageNumber(Math.min(pageCount, pageNumber + 1))} disabled={pageNumber >= pageCount}
            className="p-1 hover:bg-gray-100 rounded disabled:opacity-30"><ChevronRight size={18} /></button>
        </div>
      </div>
      <div className="flex-1 overflow-auto flex justify-center bg-gray-100 p-4">
        {loadError && (
          <div className="p-8 text-center">
            <p className="text-red-500 mb-2">Failed to load PDF</p>
            <p className="text-xs text-gray-400">{loadError}</p>
          </div>
        )}
        {!pdfData && !loadError && <Loader />}
        {pdfData && (
          <Document
            file={pdfData}
            onLoadSuccess={onDocumentLoadSuccess}
            onLoadError={onDocumentLoadError}
            loading={<Loader />}
          >
            <Page pageNumber={pageNumber} width={Math.min(800, window.innerWidth - 100)} renderTextLayer={false} renderAnnotationLayer={false} />
          </Document>
        )}
      </div>
    </div>
  );
}
