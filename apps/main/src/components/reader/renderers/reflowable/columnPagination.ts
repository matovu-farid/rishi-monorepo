// apps/main/src/components/reader/renderers/reflowable/columnPagination.ts
export function pageIndexFromScroll(scrollLeft: number, columnWidth: number, gap: number): number {
  return Math.round(scrollLeft / (columnWidth + gap));
}

export function scrollPositionForPage(pageIndex: number, columnWidth: number, gap: number): number {
  return pageIndex * (columnWidth + gap);
}
