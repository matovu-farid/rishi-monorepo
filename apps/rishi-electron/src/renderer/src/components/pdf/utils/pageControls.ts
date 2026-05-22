import { usePdfStore } from '@/stores/pdfStore'

// Suppression flag lifecycle (issue #30):
//   - We set `isLookingForNextParagraph = true` BEFORE asking the virtualizer
//     to scroll to the adjacent page and leave it set after we return.
//   - `useScrolling` reads the flag inside a 100 ms debounced effect; if we
//     cleared it synchronously here (as the original code did), that effect
//     would always observe `false` and helpfully snap the container back
//     to the OLD page's highlighted <mark>, undoing the page advance and
//     producing the "stays on page N" behaviour from issue #30.
//   - The flag is cleared by `publishParagraphsForPage` in `usePdfReader`
//     once the new page's paragraphs are actually published — i.e. once
//     the player is about to highlight a paragraph on the new page and
//     `useScrolling`'s next pass would scroll to the *correct* mark.
export function nextPage() {
  const state = usePdfStore.getState()
  const virtualizer = state.virtualizer
  if (!virtualizer) return
  // Bounds check (PR #31 review pullrequestreview-4348558706): the player
  // emits `pageRequest: 'next'` even when the last paragraph of the last page
  // finishes (usePlayerMachine ~L328). Without this guard we would set
  // `isLookingForNextParagraph = true`, ask the virtualizer to scroll to an
  // out-of-bounds index, no page would render, `currentDiffers` would never
  // flip in publishParagraphsForPage, and the flag would stay `true` for the
  // rest of the session — silently denying auto-scroll for every subsequent
  // highlight. Make nextPage a no-op when already on the last page.
  if (state.pageCount > 0 && state.pageNumber >= state.pageCount) return
  usePdfStore.getState().setIsLookingForNextParagraph(true)
  const pageIndex = state.pageNumber - 1
  virtualizer.scrollToIndex(pageIndex + 1, {
    align: 'start',
    behavior: 'auto'
  })
}
export function previousPage() {
  const state = usePdfStore.getState()
  const virtualizer = state.virtualizer
  if (!virtualizer) return
  // Symmetric guard: never scroll to virtual index -1 from the first page,
  // which would leave the suppression flag stuck `true` for the rest of the
  // session (same failure mode as the nextPage last-page case above).
  if (state.pageNumber <= 1) return

  usePdfStore.getState().setIsLookingForNextParagraph(true)
  const pageIndex = state.pageNumber - 1
  virtualizer.scrollToIndex(pageIndex - 1, {
    align: 'end',
    behavior: 'auto'
  })
}
