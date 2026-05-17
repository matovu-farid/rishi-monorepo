// apps/electron/src/renderer/src/machines/playerMachine.ts
import { setup, assign } from 'xstate'
import type { ParagraphWithIndex } from '@/stores/playerStore'

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
  | { type: 'CLEANUP' }
  // External page navigation has started (e.g. user clicked the EPUB next-page
  // arrow). The rendition is curling and PARAGRAPHS_UPDATED will arrive later.
  // The player must immediately stop playback on the OLD page so the user
  // doesn't hear the previous paragraph during the curl animation.
  | { type: 'PAGE_NAVIGATING'; direction: 'forward' | 'backward' }
  // Jump directly to a specific paragraph (e.g. from a text selection), with
  // an optional override for the first chunk of audio so playback can begin
  // mid-paragraph. Ignored from idle/pageNavigating/republishingParagraphs.
  | { type: 'PLAY_FROM'; paragraphIndex: number; partialFirstText: string; partialFirstKey: string }

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
    wasTimedOut: ({ context }) => context.timedOut
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
    // Clear the current paragraph view. When an external page navigation
    // starts, the on-screen paragraphs are about to be replaced; clearing
    // them prevents PLAY from racing the rendition and fetching the old
    // page's paragraph 0.
    clearCurrentParagraphs: assign({
      currentParagraphs: [] as ParagraphWithIndex[],
      paragraphIndex: 0
    }),
    clearErrors: assign({ errors: [] as string[] }),
    setWantsAutoResume: assign({ wantsAutoResume: true }),
    clearWantsAutoResume: assign({ wantsAutoResume: false }),
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
    // Check BEFORE advanceIndex: if partialFirstParagraphIndex matches the
    // current (pre-advance) paragraphIndex, this is the paragraph the override
    // applied to — clear it. Otherwise leave it in place for a future paragraph.
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
    CHAT_STARTED: {
      target: '.stopped',
      actions: ['resetIndex', 'clearPartialFirst']
    },
    CLEANUP: {
      target: '.idle',
      actions: 'resetAll'
    }
  },
  // Note: PAGE_NAVIGATING is handled per-state below (not as a global handler)
  // because behaviour differs:
  //   - from playing/loading/paused we set wantsAutoResume and transition to
  //     pageNavigating, AND clear stale currentParagraphs (the old page's
  //     paragraphs must not persist into the new page);
  //   - from stopped we transition to pageNavigating WITHOUT clearing
  //     paragraphs — nothing's playing so there's no urgency, and clearing
  //     would cause a fast PLAY-during-curl to route to waitingForParagraphs
  //     and emit a spurious pageRequest='next' (double-nav bug);
  //   - from idle the event is dropped (no book is open yet).
  states: {
    idle: {
      on: {
        INITIALIZE: {
          target: 'stopped',
          actions: ['storeBookId', 'resetIndex']
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
            // Empty paragraphs means we lost them from a failed nav or
            // initial load. Re-publish from the rendition rather than
            // asking for a new page.
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
        // External page navigation while we're already silent. Transition to
        // pageNavigating — the existing state designed for "external nav in
        // flight, wait for paragraphs". Going there directly avoids the
        // spurious pageRequest='next' that would fire from
        // waitingForParagraphs if PLAY arrives mid-nav (the PLAY → !hasParagraphs
        // → waitingForParagraphs path used to clear paragraphs and double-navigate).
        // Paragraphs are NOT cleared here because nothing's playing; when
        // PARAGRAPHS_UPDATED arrives, pageNavigating transitions back to
        // stopped (if no PLAY arrived) or loading (if PLAY did arrive and
        // set wantsAutoResume).
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: ['setNavDirection', 'clearWantsAutoResume']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
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
        // Page nav started while we're mid-fetch: cancel any in-flight load
        // by transitioning to pageNavigating. We remember we wanted to play
        // so PARAGRAPHS_UPDATED auto-resumes loading on the new page.
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
        // Reaching waitingForParagraphs from playing means the user was
        // actively listening — set wantsAutoResume so once the rendition
        // delivers the new page's paragraphs (via the
        // waitingForParagraphs → pageNavigating → PARAGRAPHS_UPDATED
        // chain triggered by the hook setting pageRequest), playback
        // continues automatically instead of dropping into `stopped`.
        AUDIO_ENDED: [
          {
            guard: 'hasMoreParagraphs',
            target: 'loading',
            // clearPartialFirstIfConsumed MUST run before advanceIndex so it
            // compares against the pre-advance paragraphIndex (the paragraph
            // that just finished playing).
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
        // External page nav started during playback. Stop audio (handled by
        // the entry side-effect on pageNavigating) and auto-resume on the
        // new page when PARAGRAPHS_UPDATED arrives.
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
        // External page nav while paused: jump to the new page but stay
        // effectively-paused (no auto-resume — user paused intentionally).
        PAGE_NAVIGATING: {
          target: 'pageNavigating',
          actions: [
            'clearWantsAutoResume',
            'setNavDirection',
            'clearCurrentParagraphs',
            'clearPartialFirst'
          ]
        }
      },
      states: {
        clean: {
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
          // Preserve wantsAutoResume AND direction from however we got here.
          // The player set the direction (forward/backward) on entry to
          // waitingForParagraphs based on the user's NEXT/PREV intent; the
          // event's direction field is best-effort (the hook can't always
          // tell which way the rendition is going) and must not overwrite
          // the player's authoritative intent. Specifically, after PREV at
          // the first paragraph the player needs direction='backward' to
          // survive so resetIndexByDirection lands on the LAST paragraph of
          // the previous page rather than the first.
          actions: ['clearCurrentParagraphs', 'clearPartialFirst']
        },
        PLAY_FROM: {
          target: 'loading',
          actions: ['setPartialFirst', 'setParagraphIndexFromEvent']
        }
      }
    },

    republishingParagraphs: {
      // Entered when the machine is in `stopped` with empty currentParagraphs
      // and the user clicks PLAY. Paragraphs were lost (typically via
      // clearCurrentParagraphs during a failed/timed-out page navigation).
      // The hook responds by calling publishCurrentEpubParagraphs(), which
      // re-reads the rendition's current view and dispatches a fresh
      // PARAGRAPHS_UPDATED. Unlike waitingForParagraphs, this state does NOT
      // set pageRequest — the player has not asked for a new page.
      // PLAY_FROM is intentionally NOT handled here — the paragraphs are not
      // yet known so a targeted jump cannot be validated.
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
        }
      }
    },

    // Distinct from waitingForParagraphs:
    //   - waitingForParagraphs is entered when the *player itself* wants the
    //     next/prev page (via player NEXT/PREV) and emits a pageRequest so
    //     the EPUB rendition navigates.
    //   - pageNavigating is entered when an *external* navigation has
    //     already started (user clicked the EPUB page arrow). The rendition
    //     is already curling; emitting another pageRequest here would
    //     double-navigate. So this state just waits for PARAGRAPHS_UPDATED
    //     and resumes loading IFF the player was active before.
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
          // User clicked Play during a page-curl. Remember they want to play
          // and wait for the new paragraphs to land before starting.
          actions: 'setWantsAutoResume'
        },
        PAUSE: {
          actions: 'clearWantsAutoResume'
        },
        PAGE_NAVIGATING: {
          // A second nav (rapid Next clicks). Stay here; refresh direction.
          actions: 'setNavDirection'
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: 'storeNextParagraphs'
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: 'storePrevParagraphs'
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
        }
      }
    }
  }
})
