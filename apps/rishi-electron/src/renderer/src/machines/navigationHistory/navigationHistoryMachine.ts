import { setup, assign, emit } from 'xstate'
import type {
  AnchorPoint,
  NavigationHistoryContext,
  NavigationHistoryEvent,
  NavigationHistoryEmitted
} from './types'
import { STACK_MAX_DEPTH, DWELL_MS } from './types'
import { pageKey } from './pageKey'

const initialContext = (): NavigationHistoryContext => ({
  bookId: null,
  stack: [],
  resumeMap: new Map(),
  currentPage: null,
  currentTts: null,
  pillVisible: false
})

export const navigationHistoryMachine = setup({
  types: {
    context: {} as NavigationHistoryContext,
    events: {} as NavigationHistoryEvent,
    emitted: {} as NavigationHistoryEmitted
  },
  actions: {
    hydrateOnOpen: assign(({ event }) => {
      if (event.type !== 'BOOK_OPENED') return {}
      return {
        bookId: event.bookId,
        currentPage: event.initialPosition,
        currentTts: null,
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
    }),
    emitPopAnchorAsResume: emit(({ context }): NavigationHistoryEmitted => {
      // POP_BACK pops the topmost anchor from the stack; reader components
      // (PdfView / EpubView / etc.) listen on RESUME_REQUESTED via
      // `onResumeRequested` to drive the actual seek back to that anchor's
      // saved position. Without this emit, popping only mutates the stack
      // and the reader never moves — the pill click "succeeds" but the user
      // stays on the page they jumped TO. Match the popAnchor guard above:
      // do not emit when the stack was empty (guard `hasStackEntries` on the
      // POP_BACK transition already blocks that, but the assertion is cheap).
      const popped = context.stack[context.stack.length - 1]
      if (!popped) {
        throw new Error('emitPopAnchorAsResume: no anchor to pop (guard violated)')
      }
      return { type: 'RESUME_REQUESTED', anchor: popped }
    }),
    recordPageVisit: assign(({ event }) => {
      if (event.type !== 'PAGE_VISITED') return {}
      return { currentPage: event.position, currentTts: event.ttsContext }
    }),
    captureResumeAnchor: assign(({ context }) => {
      if (!context.bookId || !context.currentPage) return {}
      const anchor: AnchorPoint = {
        id: crypto.randomUUID(),
        bookId: context.bookId,
        position: context.currentPage,
        tts: context.currentTts,
        label: '',
        capturedAt: Date.now(),
        source: 'engagement'
      }
      const next = new Map(context.resumeMap)
      next.set(pageKey(context.currentPage), anchor)
      return { resumeMap: next }
    }),
    showPill: assign({ pillVisible: true }),
    hidePill: assign({ pillVisible: false }),
    hidePillIfStackEmpty: assign(({ context }) => {
      return context.stack.length === 0 ? { pillVisible: false } : {}
    }),
    emitResume: emit(({ context, event }): NavigationHistoryEmitted => {
      if (event.type !== 'PAGE_VISITED') {
        throw new Error('emitResume: expected PAGE_VISITED event')
      }
      const anchor = context.resumeMap.get(pageKey(event.position))
      if (!anchor) {
        throw new Error('emitResume: guard should have prevented this — no anchor')
      }
      return { type: 'RESUME_REQUESTED', anchor }
    })
  },
  guards: {
    hasStackEntries: ({ context }) => context.stack.length > 0,
    hasResumeAnchor: ({ context, event }) => {
      if (event.type !== 'PAGE_VISITED') return false
      return context.resumeMap.has(pageKey(event.position))
    }
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
                POP_BACK: {
                  target: 'navigating',
                  guard: 'hasStackEntries',
                  // Order matters: emitPopAnchorAsResume must run BEFORE
                  // popAnchor mutates the stack — it reads the top of the
                  // stack to build the RESUME_REQUESTED payload.
                  actions: ['emitPopAnchorAsResume', 'popAnchor', 'hidePillIfStackEmpty']
                },
                PAGE_VISITED: [
                  {
                    guard: 'hasResumeAnchor',
                    actions: ['recordPageVisit', 'emitResume']
                  },
                  {
                    actions: 'recordPageVisit'
                  }
                ]
              }
            },
            navigating: {
              on: {
                PAGE_VISITED: { target: 'idle', actions: 'recordPageVisit' }
              }
            }
          }
        },
        engagement: {
          initial: 'idle',
          states: {
            idle: {
              on: {
                PAGE_VISITED: { target: 'dwelling', actions: 'recordPageVisit' },
                ENGAGEMENT_TAP: { target: 'engaged' },
                ENGAGEMENT_TTS_PLAYING: { target: 'engaged' }
              }
            },
            dwelling: {
              after: {
                DWELL_TIMER: { target: 'engaged' }
              },
              on: {
                PAGE_VISITED: { target: 'dwelling', reenter: true, actions: 'recordPageVisit' },
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
              entry: ['captureResumeAnchor', 'hidePill'],
              on: {
                PAGE_VISITED: { target: 'dwelling', actions: 'recordPageVisit' }
              }
            }
          }
        },
        pill: {
          initial: 'hidden',
          states: {
            hidden: {
              on: {
                JUMP_REQUESTED: { target: 'visible', actions: 'showPill' }
              }
            },
            visible: {
              on: {
                DISMISS_PILL: { target: 'hidden', actions: 'hidePill' }
              }
            }
          }
        }
      }
    }
  }
})
