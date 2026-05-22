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

  usePdfStore.getState().setIsLookingForNextParagraph(true)
  const pageIndex = state.pageNumber - 1
  virtualizer.scrollToIndex(pageIndex - 1, {
    align: 'end',
    behavior: 'auto'
  })
}
