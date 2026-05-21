import { setup, assign } from 'xstate'
import type { AnchorPoint, NavigationHistoryContext, NavigationHistoryEvent } from './types'
import { STACK_MAX_DEPTH, DWELL_MS } from './types'

const initialContext = (): NavigationHistoryContext => ({
  bookId: null,
  stack: [],
  resumeMap: new Map(),
  currentPage: null,
  pillVisible: false
})

export const navigationHistoryMachine = setup({
  types: {
    context: {} as NavigationHistoryContext,
    events: {} as NavigationHistoryEvent
  },
  actions: {
    hydrateOnOpen: assign(({ event }) => {
      if (event.type !== 'BOOK_OPENED') return {}
      return {
        bookId: event.bookId,
        currentPage: event.initialPosition,
        stack: [],
        resumeMap: new Map(),
        pillVisible: false
      }
    }),
    clearAll: assign(() => initialContext()),
    pushAnchor: assign(({ context, event }) => {
      if (event.type !== 'JUMP_REQUESTED') return {}
      if (!context.bookId) return {}
      const anchor: AnchorPoint = {
        id: crypto.randomUUID(),
        bookId: context.bookId,
        position: event.from,
        tts: event.fromTts,
        label: event.fromLabel,
        capturedAt: Date.now(),
        source: event.source
      }
      const next = [...context.stack, anchor]
      if (next.length > STACK_MAX_DEPTH) next.splice(0, next.length - STACK_MAX_DEPTH)
      return { stack: next }
    }),
    popAnchor: assign(({ context }) => {
      if (context.stack.length === 0) return {}
      return { stack: context.stack.slice(0, -1) }
    })
  },
  guards: {
    hasStackEntries: ({ context }) => context.stack.length > 0
  },
  delays: {
    DWELL_TIMER: DWELL_MS
  }
}).createMachine({
  id: 'navigationHistory',
  initial: 'inactive',
  context: initialContext(),
  states: {
    inactive: {
      on: {
        BOOK_OPENED: { target: 'active', actions: 'hydrateOnOpen' }
      }
    },
    active: {
      on: {
        BOOK_CLOSED: { target: 'inactive', actions: 'clearAll' }
      },
      type: 'parallel',
      states: {
        stack: {
          initial: 'idle',
          states: {
            idle: {
              on: {
                JUMP_REQUESTED: { target: 'navigating', actions: 'pushAnchor' },
                POP_BACK: { target: 'navigating', guard: 'hasStackEntries', actions: 'popAnchor' }
              }
            },
            navigating: {
              on: {
                PAGE_VISITED: { target: 'idle' }
              }
            }
          }
        },
        engagement: {
          initial: 'idle',
          states: {
            idle: {
              on: {
                PAGE_VISITED: { target: 'dwelling' },
                ENGAGEMENT_TAP: { target: 'engaged' },
                ENGAGEMENT_TTS_PLAYING: { target: 'engaged' }
              }
            },
            dwelling: {
              after: {
                DWELL_TIMER: { target: 'engaged' }
              },
              on: {
                PAGE_VISITED: { target: 'dwelling', reenter: true },
                ENGAGEMENT_TAP: { target: 'engaged' },
                ENGAGEMENT_TTS_PLAYING: { target: 'engaged' },
                DWELL_ELAPSED: { target: 'engaged' },
                VISIBILITY_HIDDEN: { target: 'paused' }
              }
            },
            paused: {
              on: {
                VISIBILITY_VISIBLE: { target: 'dwelling', reenter: true }
              }
            },
            engaged: {
              on: {
                PAGE_VISITED: { target: 'dwelling' }
              }
            }
          }
        },
        pill: { initial: 'hidden', states: { hidden: {} } }
      }
    }
  }
})
