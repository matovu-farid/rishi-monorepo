/**
 * Parse a PDF paragraph id of the form `pdf-{page}-{idx}` and return the
 * 1-based page number. Returns null for any input that doesn't match the
 * shape exactly, including legacy ids, ids from other formats, and ids
 * with non-numeric or non-positive page components.
 */
export function pdfParagraphToPageNumber(idx: string): number | null {
  const m = /^pdf-(\d+)-(\d+)$/.exec(idx)
  if (!m) return null
  const page = Number(m[1])
  if (!Number.isFinite(page) || page <= 0) return null
  return page
}
