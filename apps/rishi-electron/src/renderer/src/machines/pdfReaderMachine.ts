import { setup, assign, fromPromise, raise } from 'xstate'

export const SAVE_DEBOUNCE_MS = 400

export type PdfReaderInput = {
  bookId: number
  initialPage: number
}

export type PdfReaderContext = {
  bookId: number
  numPages: number
  currentPage: number
  seekTarget: number | null
  lastSaved: number | null
  saveError: string | null
}

export type PdfReaderEvent =
  | { type: 'DOC_LOADED'; numPages: number }
  | { type: 'SEEK_REQUESTED'; page: number }
  | { type: 'SEEK_LANDED' }
  | { type: 'PAGE_CHANGED'; page: number }
  | { type: 'FLUSH' }
  // Internal — `raise`-d from seek.viewing's PAGE_CHANGED handler so the
  // persist region only reacts to changes that originated in viewing state
  // (i.e. real user scrolls, never a polling glitch during seek).
  | { type: 'COMMIT_PAGE'; page: number }

const clamp = (n: number, min: number, max: number): number =>
  Math.min(Math.max(n, min), max)

export const pdfReaderMachine = setup({
  types: {
    input: {} as PdfReaderInput,
    context: {} as PdfReaderContext,
    events: {} as PdfReaderEvent
  },
  actors: {
    // Default impl throws — the React integration must supply a real one via
    // `.provide({ actors: { saveLocation: fromPromise(...) } })`.
    saveLocation: fromPromise<{ savedPage: number }, { bookId: number; page: number }>(
      async () => {
        throw new Error('saveLocation actor not provided')
      }
    )
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
      }
    }),
    landSeek: assign({
      currentPage: ({ context }) => context.seekTarget ?? context.currentPage,
      seekTarget: null
    }),
    updateCurrentPage: assign({
      currentPage: ({ context, event }) =>
        event.type === 'PAGE_CHANGED' ? event.page : context.currentPage
    }),
    markSaved: assign({
      lastSaved: ({ context, event }) => {
        // The done event from invoke carries the actor's output. Declared event
        // types don't include the meta events, so narrow by shape.
        if (!('output' in event)) return context.lastSaved
        const out = (event as { output: { savedPage: number } }).output
        return out.savedPage
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
    pageDiffersFromCurrent: ({ context, event }) =>
      event.type === 'PAGE_CHANGED' && event.page !== context.currentPage,
    pageDiffersFromLastSaved: ({ context, event }) =>
      event.type === 'COMMIT_PAGE' && event.page !== context.lastSaved,
    needsResave: ({ context, event }) => {
      if (!('output' in event)) return false
      const out = (event as { output: { savedPage: number } }).output
      return context.currentPage !== out.savedPage
    },
    flushable: ({ context }) =>
      context.currentPage > 0 && context.currentPage !== context.lastSaved
  }
}).createMachine({
  id: 'pdfReader',
  context: ({ input }) => {
    const initial = input.initialPage > 0 ? input.initialPage : 1
    return {
      bookId: input.bookId,
      numPages: 0,
      currentPage: initial,
      seekTarget: null,
      // Treat the initialPage as already-saved so we don't re-emit a save
      // for the page we just restored from.
      lastSaved: input.initialPage > 0 ? initial : null,
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
                // evaluate whether this page needs saving. The clean→dirty
                // guard checks `page !== lastSaved`, so the initial restore
                // (currentPage already equals lastSaved) is a no-op while a
                // user-triggered TOC/thumbnail seek correctly schedules a save.
                raise(({ context }) => ({
                  type: 'COMMIT_PAGE' as const,
                  page: context.currentPage
                }))
              ]
            }
          }
        },
        viewing: {
          on: {
            PAGE_CHANGED: {
              guard: 'pageDiffersFromCurrent',
              actions: [
                'updateCurrentPage',
                raise(({ event }) => ({
                  type: 'COMMIT_PAGE' as const,
                  page: event.type === 'PAGE_CHANGED' ? event.page : 0
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
              guard: 'pageDiffersFromLastSaved'
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
            input: ({ context }) => ({ bookId: context.bookId, page: context.currentPage }),
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
