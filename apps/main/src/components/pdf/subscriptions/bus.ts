// PDF event bus subscriptions have been moved into PdfView's useEffect lifecycle
// to prevent them from leaking across book formats (EPUB, MOBI, DJVU).
// See pdf.tsx for the scoped subscriptions.
