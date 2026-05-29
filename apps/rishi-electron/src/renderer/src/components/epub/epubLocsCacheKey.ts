// Storage key for epub.js's persisted `locations` index. The cache is
// keyed by:
//   - schema version ("v5") — bump when the persisted JSON shape changes
//   - charsPerPage — bound to the value passed to locations.generate().
//     Including it means changing the constant naturally evicts every
//     persisted cache instead of silently mis-rendering against a stale
//     index (locations indexed at 1600 chars/page are not interchangeable
//     with locations indexed at 1200).
//   - book.id — partition per book
export function epubLocsCacheKey(bookId: number, charsPerPage: number): string {
  return `epub-locs-v5-${charsPerPage}-${bookId}`
}
