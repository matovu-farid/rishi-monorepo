/**
 * Re-export the full PDF viewer from the ported Tauri system.
 * This file exists so that existing imports (`@/components/pdf/PdfView`)
 * continue to resolve without changes.
 */
export { PdfView as default, PdfView } from "./components/pdf";
