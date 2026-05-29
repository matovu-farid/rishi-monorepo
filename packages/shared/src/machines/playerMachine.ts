/**
 * Player XState machine. Ported verbatim from
 * `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts`.
 *
 * Manages playback state across idle → stopped → loading → playing →
 * paused, including page-navigation interruption, chat-position
 * preservation (CHAT_STARTED / CHAT_ENDED), retry policy, and
 * partial-first override (read-aloud from selection).
 */
import { setup, assign, sendTo, raise, fromCallback } from 'xstate'
import type { ViewActorCommand } from '../actors/viewActor'

/**
 * The paragraph type used by the player. Mirrors
 * `apps/rishi-electron/src/renderer/src/models/player_control.ts`
 * exactly so callers downstream can re-export.
 */
export type ParagraphWithIndex = {
  text: string
  index: string
}

const MAX_RETRIES = 3

// Placeholder view actor used when no per-format actor is provided via
// `.provide({ actors: { view: ... } })`. The default is a no-op so machines
// created without a view actor (e.g. legacy tests that exercise the state
// graph without navigation) don't crash on entry actions that
// sendTo('view', ...).
const noopViewActor = fromCallback<ViewActorCommand, unknown>(() => () => {})

export type PlayerMachineInput = {
  /**
   * Format-specific input for the view actor. The shape depends on which
   * actor is provided via `.provide({ actors: { view: ... } })`. Carried as
   * unknown because the machine itself is format-agnostic.
   */
  viewInput?: unknown
}

export type PlayerMachineContext = {
  bookId: string
  paragraphIndex: number
  direction: 'forward' | 'backward'
  currentParagraphs: ParagraphWithIndex[]
  nextPageParagraphs: ParagraphWithIndex[]
  prevPageParagraphs: ParagraphWithIndex[]
  errors: string[]
  retryCount: number
  timedOut: boolean
  // True if the player should auto-resume loading the new page after an
  // external PAGE_NAVIGATING event. Set when nav fires from an active state
  // (playing/loading/paused); false from stopped/idle (user is silent).
  wantsAutoResume: boolean
  // True when CHAT_STARTED interrupted active playback (or loading / waiting-
  // for-paragraphs). On CHAT_ENDED the player auto-resumes from the same
  // paragraphIndex. Reset on every CHAT_ENDED and on any transition that
  // represents the user choosing silence (PAUSE, STOP, etc.).
  wantsAutoResumeAfterChat: boolean
  // Partial-first override: when PLAY_FROM is sent, these fields allow the
  // audio engine to start playback from the middle of a paragraph (e.g. from
  // a user's text selection). partialFirstParagraphIndex tracks WHICH
  // paragraph the override applies to so it can be cleared after that
  // paragraph finishes playing.
  partialFirstText: string | null
  partialFirstKey: string | null
  partialFirstParagraphIndex: number | null
  /**
   * Format-specific input forwarded to the invoked view actor. Stored in
   * context so the root `invoke` block can read it via `({ context }) =>
   * context.viewInput` without import-side coupling. Non-serialisable.
   */
  viewInput: unknown
}

export type PlayerMachineEvent =
  | { type: 'INITIALIZE'; bookId: string }
  | { type: 'PLAY' }
  | { type: 'PAUSE' }
  | { type: 'RESUME' }
  | { type: 'STOP' }
  | { type: 'NEXT' }
  | { type: 'PREV' }
  | { type: 'AUDIO_LOADED' }
  | { type: 'AUDIO_ENDED' }
  | { type: 'AUDIO_ERROR'; error: string }
  | { type: 'PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'NEXT_PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'PREV_PARAGRAPHS_UPDATED'; paragraphs: ParagraphWithIndex[] }
  | { type: 'CHAT_STARTED' }
  | { type: 'CHAT_ENDED' }
  | { type: 'CLEANUP' }
  | { type: 'PAGE_NAVIGATING'; direction: 'forward' | 'backward' }
  | { type: 'PLAY_FROM'; paragraphIndex: number; partialFirstText: string; partialFirstKey: string }
  | { type: 'REPEAT' }
  // Emitted by the view layer when a navigation request did NOT yield a new
  // view (end of book / drift restore / same-CFI relocated / image-only
  // page). The player transitions to `stopped` with a meaningful reason
  // instead of timing out or silently republishing the OLD view's
  // paragraphs and snapping to paragraph 0. Parity with electron — see
  // apps/rishi-electron/src/renderer/src/machines/playerMachine.ts and
  // .parity/2026-05-28-player-actor-restructure/PLAN.md §3.4.
  | { type: 'NAV_NO_PROGRESS'; reason?: 'end-of-document' | 'no-relocation' | 'timeout' }
  // Emitted by the invoked view actor (epub/pdf/etc) when a navigation or
  // republish committed a non-empty new view. Re-raised at the root as
  // PARAGRAPHS_UPDATED so every existing state handler processes it
  // identically — this decouples per-state behaviour from whether paragraphs
  // arrived via store subscription or view-actor sendBack. Parity with
  // electron — see PLAN.md §3.4.
  | { type: 'VIEW_CHANGED'; locator: string; paragraphs: ParagraphWithIndex[] }

const initialContext: Omit<PlayerMachineContext, 'viewInput'> = {
  bookId: '',
  paragraphIndex: 0,
  direction: 'forward',
  currentParagraphs: [],
  nextPageParagraphs: [],
  prevPageParagraphs: [],
  errors: [],
  retryCount: 0,
  timedOut: false,
  wantsAutoResume: false,
  wantsAutoResumeAfterChat: false,
  partialFirstText: null,
  partialFirstKey: null,
  partialFirstParagraphIndex: null
}

export const playerMachine = setup({
  types: {
    context: {} as PlayerMachineContext,
    events: {} as PlayerMachineEvent
  },
  actors: {
    view: noopViewActor
  },
  guards: {
    hasParagraphs: ({ context }) => context.currentParagraphs.length > 0,
    hasMoreParagraphs: ({ context }) =>
      context.paragraphIndex < context.currentParagraphs.length - 1,
    hasRetries: ({ context }) => context.retryCount + 1 < MAX_RETRIES,
    isFirstParagraph: ({ context }) => context.paragraphIndex <= 0,
    wasTimedOut: ({ context }) => context.timedOut,
    wantsAutoResumeAfterChat: ({ context }) => context.wantsAutoResumeAfterChat
  },
  actions: {
    storeBookId: assign({
      bookId: ({ event }) => (event.type === 'INITIALIZE' ? event.bookId : '')
    }),
    resetIndex: assign({ paragraphIndex: 0, retryCount: 0, timedOut: false }),
    resetIndexByDirection: assign({
      paragraphIndex: ({ context }) =>
        context.direction === 'backward' ? Math.max(0, context.currentParagraphs.length - 1) : 0,
      retryCount: 0
    }),
    advanceIndex: assign({
      paragraphIndex: ({ context }) =>
        Math.min(context.paragraphIndex + 1, context.currentParagraphs.length - 1),
      direction: 'forward' as const,
      retryCount: 0
    }),
    retreatIndex: assign({
      paragraphIndex: ({ context }) => Math.max(context.paragraphIndex - 1, 0),
      direction: 'backward' as const,
      retryCount: 0
    }),
    storeParagraphs: assign({
      currentParagraphs: ({ event }) =>
        event.type === 'PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    storeNextParagraphs: assign({
      nextPageParagraphs: ({ event }) =>
        event.type === 'NEXT_PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    storePrevParagraphs: assign({
      prevPageParagraphs: ({ event }) =>
        event.type === 'PREV_PARAGRAPHS_UPDATED' ? event.paragraphs : []
    }),
    incrementRetry: assign({
      retryCount: ({ context }) => context.retryCount + 1
    }),
    logError: assign({
      errors: ({ context, event }) => {
        const msg = event.type === 'AUDIO_ERROR' ? event.error : 'Unknown error'
        const errs = [...context.errors, msg]
        if (errs.length > 50) errs.shift()
        return errs
      }
    }),
    setDirectionForward: assign({ direction: 'forward' as const }),
    setDirectionBackward: assign({ direction: 'backward' as const }),
    setNavDirection: assign({
      direction: ({ event }) =>
        event.type === 'PAGE_NAVIGATING' ? event.direction : ('forward' as const)
    }),
    clearCurrentParagraphs: assign({
      currentParagraphs: [] as ParagraphWithIndex[],
      paragraphIndex: 0
    }),
    clearErrors: assign({ errors: [] as string[] }),
    setWantsAutoResume: assign({ wantsAutoResume: true }),
    clearWantsAutoResume: assign({ wantsAutoResume: false }),
    setWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: true }),
    clearWantsAutoResumeAfterChat: assign({ wantsAutoResumeAfterChat: false }),
    flagTimedOut: assign({ timedOut: true }),
    logLoadingTimeout: assign({
      errors: ({ context }) => {
        const errs = [...context.errors, 'Audio loading timed out']
        if (errs.length > 50) errs.shift()
        return errs
      }
    }),
    clearTimedOut: assign({ timedOut: false }),
    resetAll: assign(() => ({ ...initialContext })),
    setPartialFirst: assign({
      partialFirstText: ({ event }) => (event.type === 'PLAY_FROM' ? event.partialFirstText : null),
      partialFirstKey: ({ event }) => (event.type === 'PLAY_FROM' ? event.partialFirstKey : null),
      partialFirstParagraphIndex: ({ event }) =>
        event.type === 'PLAY_FROM' ? event.paragraphIndex : null
    }),
    clearPartialFirst: assign({
      partialFirstText: null,
      partialFirstKey: null,
      partialFirstParagraphIndex: null
    }),
    setParagraphIndexFromEvent: assign({
      paragraphIndex: ({ event }) => (event.type === 'PLAY_FROM' ? event.paragraphIndex : 0)
    }),
    clearPartialFirstIfConsumed: assign({
      partialFirstText: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstText,
      partialFirstKey: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstKey,
      partialFirstParagraphIndex: ({ context }) =>
        context.partialFirstParagraphIndex === context.paragraphIndex
          ? null
          : context.partialFirstParagraphIndex
    })
  }
}).createMachine({
  id: 'player',
  initial: 'idle',
  context: ({ input }) => {
    const i = input as PlayerMachineInput | undefined
    return {
      ...initialContext,
      viewInput: i?.viewInput
    }
  },
  invoke: {
    // Always-on view actor — per-format (epubViewActor, pdfViewActor, ...)
    // injected via `.provide({ actors: { view: ... } })` at the reader-screen
    // layer. Receives NAVIGATE_NEXT/PREV/TO/REPUBLISH; emits VIEW_CHANGED /
    // NAV_NO_PROGRESS back. Default is a no-op so tests that exercise the
    // state graph without navigation don't crash. Parity with electron.
    id: 'view',
    src: 'view',
    input: ({ context }: { context: PlayerMachineContext }) => context.viewInput
  },
  on: {
    CLEANUP: {
      target: '.idle',
      actions: 'resetAll'
    },
    CHAT_ENDED: [
      {
        guard: 'wantsAutoResumeAfterChat',
        target: '.loading',
        actions: ['clearWantsAutoResumeAfterChat']
      },
      {
        actions: ['clearWantsAutoResumeAfterChat']
      }
    ],
    // The view actor reports a committed view. Re-raise as PARAGRAPHS_UPDATED
    // so every existing state handler processes it identically. Parity with
    // electron — see PLAN.md §3.4.
    VIEW_CHANGED: {
      actions: raise(({ event }) => ({
        type: 'PARAGRAPHS_UPDATED' as const,
        paragraphs: (event as { paragraphs: ParagraphWithIndex[] }).paragraphs
      }))
    }
  },
  states: {
    idle: {
      on: {
        INITIALIZE: {
          target: 'stopped',
          actions: ['storeBookId', 'resetIndex']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    stopped: {
      on: {
        PLAY: [
          {
            guard: 'hasParagraphs',
            target: 'loading'
          },
          {
            target: 'republishingParagraphs'
          }
        ],
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            guard: 'hasParagraphs',
            target: 'waitingForParagraphs',
            actions: 'setDirectionForward'
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: 'setDirectionBackward'
          },
          {
            guard: 'hasParagraphs',
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        PARAGRAPHS_UPDATED: [
          {
            guard: 'wasTimedOut',
            target: 'loading',
            actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
          },
          {
            actions: ['storeParagraphs']
          }
        ],
        NEXT_PARAGRAPHS_UPDATED: {
          actions: ['storeNextParagraphs']
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: ['storePrevParagraphs']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['setNavDirection', 'clearWantsAutoResume']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    loading: {
      after: {
        60000: {
          target: 'error',
          actions: ['logLoadingTimeout', 'flagTimedOut']
        }
      },
      on: {
        AUDIO_LOADED: {
          target: 'playing',
          actions: 'clearErrors'
        },
        AUDIO_ERROR: [
          {
            guard: 'hasRetries',
            target: 'loading',
            actions: ['incrementRetry', 'logError'],
            reenter: true
          },
          {
            target: 'error',
            actions: ['logError', 'clearPartialFirst']
          }
        ],
        PAUSE: {
          target: 'paused'
        },
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'resetIndexByDirection'],
          reenter: true
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        CLEANUP: {
          target: 'idle',
          actions: 'resetAll'
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'setWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent'],
          reenter: true
        },
        CHAT_STARTED: {
          target: 'paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    playing: {
      on: {
        PAUSE: {
          target: 'paused'
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        AUDIO_ENDED: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: ['clearPartialFirstIfConsumed', 'advanceIndex']
          },
          {
            target: 'waitingForParagraphs',
            actions: ['clearPartialFirstIfConsumed', 'setDirectionForward', 'setWantsAutoResume']
          }
        ],
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            target: 'waitingForParagraphs',
            actions: ['setDirectionForward', 'setWantsAutoResume']
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: ['setDirectionBackward', 'setWantsAutoResume']
          },
          {
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'resetIndexByDirection']
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        AUDIO_ERROR: {
          target: 'error',
          actions: 'logError'
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'setWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        REPEAT: {
          target: 'loading',
          reenter: true,
          actions: 'clearPartialFirst'
        },
        CHAT_STARTED: {
          target: 'paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    paused: {
      initial: 'clean',
      on: {
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: 'advanceIndex'
          },
          {
            target: 'waitingForParagraphs',
            actions: 'setDirectionForward'
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: 'setDirectionBackward'
          },
          {
            target: 'loading',
            actions: 'retreatIndex'
          }
        ],
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'clearWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        CHAT_STARTED: {
          actions: ['clearPartialFirst']
        }
      },
      states: {
        clean: {
          exit: ['clearWantsAutoResumeAfterChat'],
          on: {
            RESUME: {
              target: '#player.playing'
            },
            PARAGRAPHS_UPDATED: {
              target: 'stale',
              actions: ['storeParagraphs', 'resetIndexByDirection']
            },
            PLAY_FROM: {
              target: '#player.loading',
              actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
            }
          }
        },
        stale: {
          on: {
            RESUME: {
              target: '#player.loading'
            },
            PARAGRAPHS_UPDATED: {
              target: 'stale',
              actions: ['storeParagraphs', 'resetIndexByDirection'],
              reenter: true
            },
            PLAY_FROM: {
              target: '#player.loading',
              actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
            }
          }
        }
      }
    },

    waitingForParagraphs: {
      // Ask the view actor to navigate. The view actor emits VIEW_CHANGED
      // (re-raised as PARAGRAPHS_UPDATED) or NAV_NO_PROGRESS, both already
      // handled below. Parity with electron — see PLAN.md §3.4.
      entry: sendTo('view', ({ context }) => ({
        type:
          context.direction === 'backward'
            ? ('NAVIGATE_PREV' as const)
            : ('NAVIGATE_NEXT' as const)
      })),
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
        },
        // The view-layer detected end-of-document / no-relocation. Don't
        // loop; stop. Parity with electron — the structural fix for the
        // auto-advance-past-last-paragraph snap-back bug. See
        // .parity/2026-05-28-player-actor-restructure/PLAN.md §3.4.
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['clearCurrentParagraphs', 'clearPartialFirst']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          target: '#player.paused.clean',
          actions: ['setWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    republishingParagraphs: {
      // Ask the view actor to re-emit the current view's paragraphs. The
      // actor validates non-emptiness and emits VIEW_CHANGED (re-raised as
      // PARAGRAPHS_UPDATED) or NAV_NO_PROGRESS.
      entry: sendTo('view', { type: 'REPUBLISH' }),
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: {
          target: 'loading',
          actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
        },
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearPartialFirst']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['setNavDirection', 'clearCurrentParagraphs', 'clearPartialFirst']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    pageNavigating: {
      after: {
        10000: {
          target: 'stopped',
          actions: 'flagTimedOut'
        }
      },
      on: {
        PARAGRAPHS_UPDATED: [
          {
            guard: ({ context }) => context.wantsAutoResume,
            target: 'loading',
            actions: [
              'storeParagraphs',
              'clearTimedOut',
              'resetIndexByDirection',
              'clearWantsAutoResume'
            ]
          },
          {
            target: 'stopped',
            actions: ['storeParagraphs', 'clearTimedOut', 'resetIndexByDirection']
          }
        ],
        // THE bug class fix — when the rendition didn't actually advance
        // (end of book / drift restore / image-only page / same-CFI
        // relocated), the view layer signals NAV_NO_PROGRESS so the player
        // transitions to stopped instead of silently looping back to
        // paragraph 0 of the OLD view. Parity with electron — see
        // .parity/2026-05-28-player-actor-restructure/PLAN.md §3.4.
        NAV_NO_PROGRESS: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearWantsAutoResume', 'clearPartialFirst']
        },
        PLAY: {
          actions: 'setWantsAutoResume'
        },
        PAUSE: {
          actions: 'clearWantsAutoResume'
        },
        PAGE_NAVIGATING: {
          actions: 'setNavDirection'
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    },

    error: {
      on: {
        NEXT: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            actions: ['advanceIndex', 'clearErrors']
          },
          {
            target: 'waitingForParagraphs',
            actions: ['setDirectionForward', 'clearErrors']
          }
        ],
        PREV: [
          {
            guard: 'isFirstParagraph',
            target: 'waitingForParagraphs',
            actions: ['setDirectionBackward', 'clearErrors']
          },
          {
            target: 'loading',
            actions: ['retreatIndex', 'clearErrors']
          }
        ],
        STOP: {
          target: 'stopped',
          actions: ['resetIndex', 'clearErrors', 'clearPartialFirst']
        },
        PLAY: {
          target: 'loading',
          actions: ['clearErrors', 'resetIndex']
        },
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'clearErrors',
            'clearWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['clearErrors', 'setPartialFirst', 'setParagraphIndexFromEvent']
        },
        CHAT_STARTED: {
          actions: ['clearWantsAutoResumeAfterChat', 'clearPartialFirst']
        }
      }
    }
  }
})
