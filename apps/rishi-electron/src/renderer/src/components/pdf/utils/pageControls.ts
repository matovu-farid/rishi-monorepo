import { usePdfStore } from '@/stores/pdfStore'

// Suppression flag lifecycle (issue #30):
//   - We set `isLookingForNextParagraph = true` BEFORE asking the virtualizer
//     to scroll to the adjacent page and leave it set after we return.
//   - `useScrolling` reads the flag inside a 100 ms debounced effect; if we
//     cleared it synchronously here (as the original code did), that effect
//     would always observe `false` and helpfully snap the container back
//     to the OLD page's highlighted <mark>, undoing the page advance and
//     producing the "stays on page N" behaviour from issue #30.
//   - The flag is cleared by `useScrolling` itself, the moment its 100 ms
//     debounced effect fires for the first highlight on the new page —
//     where the suppression is actually needed. Clearing earlier (e.g.
//     when paragraphs publish, as the first iteration of this fix did)
//     leaves a race: the highlight assignment happens AFTER paragraphs
//     publish, so by the time `useScrolling` actually runs its centering
//     math, the suppression is already gone and the new page's first
//     paragraph (sitting flush with the viewport top after `align:'start'`)
//     gets "centered" — i.e. the container scrolls back to the previous
//     page. That's the refined symptom reported on PR #31.
// Returns true if the navigation was initiated (page-change snapshot will
// arrive once the virtualizer scrolls), false if at the document boundary
// or the virtualizer is not yet mounted. pdfViewActor relies on this to
// distinguish "wait for the page change" from "give up immediately."
export function nextPage(): boolean {
  const state = usePdfStore.getState()
  const virtualizer = state.virtualizer
  if (!virtualizer) return false
  // Bounds check (PR #31 review pullrequestreview-4348558706): the view
  // actor (pdfViewActor) calls nextPage() whenever the player sends
  // NAVIGATE_NEXT, including on the last paragraph of the last page. Without
  // this guard we would set `isLookingForNextParagraph = true`, ask the
  // virtualizer to scroll to an out-of-bounds index, no page would render,
  // `currentDiffers` would never flip in publishParagraphsForPage, and the
  // flag would stay `true` for the rest of the session — silently denying
  // auto-scroll for every subsequent highlight. Make nextPage a no-op when
  // already on the last page.
  if (state.pageCount > 0 && state.pageNumber >= state.pageCount) return false
  usePdfStore.getState().setIsLookingForNextParagraph(true)
  const pageIndex = state.pageNumber - 1
  virtualizer.scrollToIndex(pageIndex + 1, {
    align: 'start',
    behavior: 'smooth'
  })
  return true
}
export function previousPage(): boolean {
  const state = usePdfStore.getState()
  const virtualizer = state.virtualizer
  if (!virtualizer) return false
  // Symmetric guard: never scroll to virtual index -1 from the first page,
  // which would leave the suppression flag stuck `true` for the rest of the
  // session (same failure mode as the nextPage last-page case above).
  if (state.pageNumber <= 1) return false

  usePdfStore.getState().setIsLookingForNextParagraph(true)
  const pageIndex = state.pageNumber - 1
  virtualizer.scrollToIndex(pageIndex - 1, {
    align: 'end',
    behavior: 'smooth'
  })
  return true
}
