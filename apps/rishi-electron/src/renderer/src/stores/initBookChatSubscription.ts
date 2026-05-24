import { useChatStore } from '@/stores/chatStore'

/**
 * Register a side-effect that calls chatStore.startChat(bookId) whenever the
 * voice-chat launcher flips `isChatting` from false → true. Returns the
 * Zustand unsubscribe so callers can tear it down on unmount.
 *
 * The `getBookId` closure is invoked at activation time (not at subscription
 * time) so each reader path can derive the right id-or-null from live state:
 *
 *   - Azw3View    → `() => book.id`
 *   - pdfStore    → `() => usePdfStore.getState().book?.kind === 'pdf' ? usePdfStore.getState().book.id : null`
 *   - epubStore   → `() => useEpubStore.getState().bookId || null`
 *
 * If `getBookId` returns `null`, no activation fires for that edge — this
 * lets a single subscription site stay mounted across format switches while
 * gating activation on whether the active book actually belongs to that
 * reader path. This is the parity convergence point for issue #237: today
 * Azw3View has no subscription at all, so MOBI/AZW3 voice chat is dead;
 * after this lands, the same helper drives all three reader paths.
 *
 * NOTE: this is intentionally a thin wrapper around `useChatStore.subscribe`.
 * Each reader path owns its own cleanup lifecycle (component-local useRef
 * for Azw3View / EpubView, module-level singleton for pdfStore) — the helper
 * stays oblivious so we don't have to thread a registry through.
 */
export function initBookChatSubscription(getBookId: () => string | number | null): () => void {
  return useChatStore.subscribe(
    (state) => state.isChatting,
    (isChatting) => {
      if (!isChatting) return
      const bookId = getBookId()
      if (bookId == null) return
      useChatStore.getState().startChat(Number(bookId))
    }
  )
}
