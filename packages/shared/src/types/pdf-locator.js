/** Encode a PdfLocator into a stable string for storage / IPC. */
export function encodePdfLocator(loc) {
    return JSON.stringify(loc);
}
/** Decode a stored PdfLocator string. Returns null on invalid input. */
export function decodePdfLocator(s) {
    if (!s)
        return null;
    try {
        const parsed = JSON.parse(s);
        if (typeof parsed.page !== 'number')
            return null;
        if (!Array.isArray(parsed.rects))
            return null;
        for (const r of parsed.rects) {
            if (typeof r.x !== 'number' ||
                typeof r.y !== 'number' ||
                typeof r.w !== 'number' ||
                typeof r.h !== 'number') {
                return null;
            }
        }
        return parsed;
    }
    catch {
        return null;
    }
}
/**
 * Mobile-only convention: PDF highlights are stored in the same
 * `highlights` table as EPUB ones (shared with D1). The `cfiRange` column
 * is reused for the encoded PdfLocator, prefixed with `pdf:` so callers
 * can distinguish formats without a schema migration.
 *
 *   `pdf:{"page":5,"rects":[{"x":72,"y":120,"w":300,"h":12}]}`
 *
 * Electron stores the format in a separate `format` column and the
 * locator in a `locator` column — both shapes are deserializable to the
 * same `PdfLocator`, so a row written by either client renders on the
 * other after sync.
 */
export const PDF_CFI_PREFIX = 'pdf:';
export function encodePdfCfiRange(loc) {
    return `${PDF_CFI_PREFIX}${encodePdfLocator(loc)}`;
}
export function decodePdfCfiRange(cfiRange) {
    if (!cfiRange.startsWith(PDF_CFI_PREFIX))
        return null;
    return decodePdfLocator(cfiRange.slice(PDF_CFI_PREFIX.length));
}
export function isPdfCfiRange(cfiRange) {
    return cfiRange.startsWith(PDF_CFI_PREFIX);
}
