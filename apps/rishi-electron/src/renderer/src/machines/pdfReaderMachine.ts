import { setup, assign, fromPromise, raise } from 'xstate'

export const SAVE_DEBOUNCE_MS = 400
/** Sub-page scroll changes below this don't bother the persist machine. */
export const OFFSET_THRESHOLD_PX = 16

export type PdfReaderInput = {
  bookId: number
  initialPage: number
  /** Sub-page scroll offset in pixels from the top of `initialPage`. */
  initialOffset?: number
}

export type PdfReaderContext = {
  bookId: number
  numPages: number
  currentPage: number
  /** Pixels scrolled past the top of `currentPage`. */
  currentOffset: number
  seekTarget: number | null
  /**
   * Sub-page offset to scroll past `seekTarget` after the seek lands.
   * Set on initial restore (so we can re-land mid-page on reopen) and
   * cleared by `landSeek`.
   */
  pendingOffset: number
  lastSavedPage: number | null
  lastSavedOffset: number
  saveError: string | null
}

export type PdfReaderEvent =
  | { type: 'DOC_LOADED'; numPages: number }
  | { type: 'SEEK_REQUESTED'; page: number }
  | { type: 'SEEK_LANDED' }
  | { type: 'PAGE_CHANGED'; page: number; offset?: number }
  | { type: 'FLUSH' }
  // Internal — `raise`-d so the persist region only reacts to position
  // changes that originated in viewing state (i.e. real user scrolls).
  | { type: 'COMMIT_PAGE'; page: number; offset: number }

const clamp = (n: number, min: number, max: number): number => Math.min(Math.max(n, min), max)

export const pdfReaderMachine = setup({
  types: {
    input: {} as PdfReaderInput,
    context: {} as PdfReaderContext,
    events: {} as PdfReaderEvent
  },
  actors: {
    // Default impl throws — the React integration must supply a real one via
    // `.provide({ actors: { saveLocation: fromPromise(...) } })`.
    saveLocation: fromPromise<
      { savedPage: number; savedOffset: number },
      { bookId: number; page: number; offset: number }
    >(() => Promise.reject(new Error('saveLocation actor not provided')))
  },
  actions: {
    // Default no-op; React layer overrides via `.provide` to fire the IPC.
    flushSave: () => {},
    setNumPages: assign({
      numPages: ({ event }) => (event.type === 'DOC_LOADED' ? event.numPages : 0)
    }),
    setSeekTargetFromInitialPage: assign({
      seekTarget: ({ context, event }) => {
        if (event.type !== 'DOC_LOADED') return context.seekTarget
        const max = event.numPages > 0 ? event.numPages : context.currentPage
        return clamp(context.currentPage, 1, max)
      }
    }),
    setSeekTargetFromEvent: assign({
      seekTarget: ({ context, event }) => {
        if (event.type !== 'SEEK_REQUESTED') return context.seekTarget
        const max = context.numPages > 0 ? context.numPages : event.page
        return clamp(event.page, 1, max)
      },
      // A user-initiated seek lands at the page top, not at the previously
      // restored offset. Clear pending so landSeek doesn't re-apply it.
      pendingOffset: 0
    }),
    landSeek: assign({
      currentPage: ({ context }) => context.seekTarget ?? context.currentPage,
      currentOffset: ({ context }) => context.pendingOffset,
      seekTarget: null,
      pendingOffset: 0
    }),
    updateCurrentPage: assign({
      currentPage: ({ context, event }) =>
        event.type === 'PAGE_CHANGED' ? event.page : context.currentPage,
      currentOffset: ({ context, event }) =>
        event.type === 'PAGE_CHANGED' ? (event.offset ?? 0) : context.currentOffset
    }),
    markSaved: assign({
      lastSavedPage: ({ context, event }) => {
        if (!('output' in event)) return context.lastSavedPage
        const out = (event as { output: { savedPage: number } }).output
        return out.savedPage
      },
      lastSavedOffset: ({ context, event }) => {
        if (!('output' in event)) return context.lastSavedOffset
        const out = (event as { output: { savedOffset: number } }).output
        return out.savedOffset
      },
      saveError: null
    }),
    markSaveError: assign({
      saveError: ({ event }) => {
        if (!('error' in event)) return null
        const err = (event as { error: unknown }).error
        return err instanceof Error ? `${err.name}: ${err.message}` : String(err)
      }
    })
  },
  guards: {
    positionDiffersFromCurrent: ({ context, event }) => {
      if (event.type !== 'PAGE_CHANGED') return false
      if (event.page !== context.currentPage) return true
      const offset = event.offset ?? 0
      return Math.abs(offset - context.currentOffset) >= OFFSET_THRESHOLD_PX
    },
    positionDiffersFromLastSaved: ({ context, event }) => {
      if (event.type !== 'COMMIT_PAGE') return false
      if (event.page !== context.lastSavedPage) return true
      return Math.abs(event.offset - context.lastSavedOffset) >= OFFSET_THRESHOLD_PX
    },
    needsResave: ({ context, event }) => {
      if (!('output' in event)) return false
      const out = (event as { output: { savedPage: number; savedOffset: number } }).output
      if (context.currentPage !== out.savedPage) return true
      return Math.abs(context.currentOffset - out.savedOffset) >= OFFSET_THRESHOLD_PX
    },
    flushable: ({ context }) => {
      if (context.currentPage <= 0) return false
      if (context.currentPage !== context.lastSavedPage) return true
      return Math.abs(context.currentOffset - context.lastSavedOffset) >= OFFSET_THRESHOLD_PX
    }
  }
}).createMachine({
  id: 'pdfReader',
  context: ({ input }) => {
    const initial = input.initialPage > 0 ? input.initialPage : 1
    const offset = input.initialOffset && input.initialOffset > 0 ? input.initialOffset : 0
    return {
      bookId: input.bookId,
      numPages: 0,
      currentPage: initial,
      currentOffset: offset,
      seekTarget: null,
      // Re-applied by `landSeek` once the initial restore-seek finishes.
      pendingOffset: offset,
      // Treat the initial position as already-saved so we don't re-emit
      // a save for the location we just restored from.
      lastSavedPage: input.initialPage > 0 ? initial : null,
      lastSavedOffset: input.initialPage > 0 ? offset : 0,
      saveError: null
    }
  },
  on: {
    FLUSH: {
      guard: 'flushable',
      actions: 'flushSave'
    }
  },
  type: 'parallel',
  states: {
    seek: {
      initial: 'idle',
      states: {
        idle: {
          on: {
            DOC_LOADED: {
              target: 'seeking',
              actions: ['setNumPages', 'setSeekTargetFromInitialPage']
            }
          }
        },
        seeking: {
          // PAGE_CHANGED is intentionally NOT handled here. While the initial
          // (or programmatic) seek is in flight, any visible-page update from
          // the scroll listener is ignored — this is the lockout that prevents
          // the "scroll detector reads sentinel 1 and stomps the saved page"
          // bug. Lockout ends only when the integration sends SEEK_LANDED.
          on: {
            SEEK_REQUESTED: {
              target: 'seeking',
              reenter: true,
              actions: 'setSeekTargetFromEvent'
            },
            SEEK_LANDED: {
              target: 'viewing',
              actions: [
                'landSeek',
                // After landing on the seek target, ask the persist region to
                // evaluate whether this position needs saving. The clean→dirty
                // guard checks page+offset, so the initial restore (matching
                // lastSaved) is a no-op while a TOC/thumbnail seek to a new
                // page correctly schedules a save.
                raise(({ context }) => ({
                  type: 'COMMIT_PAGE' as const,
                  page: context.currentPage,
                  offset: context.currentOffset
                }))
              ]
            }
          }
        },
        viewing: {
          on: {
            PAGE_CHANGED: {
              guard: 'positionDiffersFromCurrent',
              actions: [
                'updateCurrentPage',
                raise(({ event }) => ({
                  type: 'COMMIT_PAGE' as const,
                  page: event.page,
                  offset: event.offset ?? 0
                }))
              ]
            },
            SEEK_REQUESTED: {
              target: 'seeking',
              actions: 'setSeekTargetFromEvent'
            }
          }
        }
      }
    },
    persist: {
      initial: 'clean',
      states: {
        clean: {
          on: {
            COMMIT_PAGE: {
              target: 'dirty',
              guard: 'positionDiffersFromLastSaved'
            }
          }
        },
        dirty: {
          after: { [SAVE_DEBOUNCE_MS]: 'saving' },
          on: {
            COMMIT_PAGE: {
              target: 'dirty',
              reenter: true
            }
          }
        },
        saving: {
          invoke: {
            src: 'saveLocation',
            input: ({ context }) => ({
              bookId: context.bookId,
              page: context.currentPage,
              offset: context.currentOffset
            }),
            onDone: [
              {
                target: 'dirty',
                guard: 'needsResave',
                actions: 'markSaved'
              },
              {
                target: 'clean',
                actions: 'markSaved'
              }
            ],
            onError: {
              target: 'dirty',
              actions: 'markSaveError'
            }
          }
        }
      }
    }
  }
})
