/**
 * Player XState machine. Ported verbatim from
 * `apps/rishi-electron/src/renderer/src/machines/playerMachine.ts`.
 *
 * Manages playback state across idle → stopped → loading → playing →
 * paused, including page-navigation interruption, chat-position
 * preservation (CHAT_STARTED / CHAT_ENDED), retry policy, and
 * partial-first override (read-aloud from selection).
 */
import { setup, assign } from 'xstate'

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

const initialContext: PlayerMachineContext = {
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
  context: { ...initialContext },
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
    ]
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
