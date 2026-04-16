import * as pdfjs from "pdfjs-dist";

let configured = false;

export function ensurePdfWorker(): void {
  if (configured) return;
  pdfjs.GlobalWorkerOptions.workerSrc = new URL(
    "pdfjs-dist/build/pdf.worker.min.mjs",
    import.meta.url,
  ).toString();
  configured = true;
}
