// apps/main/src/machines/playerMachine.ts
import { setup, assign } from "xstate";
import type { ParagraphWithIndex } from "@/models/player_control";

const MAX_RETRIES = 3;

export type PlayerMachineContext = {
  bookId: string;
  paragraphIndex: number;
  direction: "forward" | "backward";
  currentParagraphs: ParagraphWithIndex[];
  nextPageParagraphs: ParagraphWithIndex[];
  prevPageParagraphs: ParagraphWithIndex[];
  errors: string[];
  retryCount: number;
  timedOut: boolean;
};

export type PlayerMachineEvent =
  | { type: "INITIALIZE"; bookId: string }
  | { type: "PLAY" }
  | { type: "PAUSE" }
  | { type: "RESUME" }
  | { type: "STOP" }
  | { type: "NEXT" }
  | { type: "PREV" }
  | { type: "AUDIO_LOADED" }
  | { type: "AUDIO_ENDED" }
  | { type: "AUDIO_ERROR"; error: string }
  | { type: "PARAGRAPHS_UPDATED"; paragraphs: ParagraphWithIndex[] }
  | { type: "NEXT_PARAGRAPHS_UPDATED"; paragraphs: ParagraphWithIndex[] }
  | { type: "PREV_PARAGRAPHS_UPDATED"; paragraphs: ParagraphWithIndex[] }
  | { type: "CLEANUP" };

const initialContext: PlayerMachineContext = {
  bookId: "",
  paragraphIndex: 0,
  direction: "forward",
  currentParagraphs: [],
  nextPageParagraphs: [],
  prevPageParagraphs: [],
  errors: [],
  retryCount: 0,
  timedOut: false,
};

export const playerMachine = setup({
  types: {
    context: {} as PlayerMachineContext,
    events: {} as PlayerMachineEvent,
  },
  guards: {
    hasParagraphs: ({ context }) => context.currentParagraphs.length > 0,
    hasMoreParagraphs: ({ context }) =>
      context.paragraphIndex < context.currentParagraphs.length - 1,
    hasRetries: ({ context }) => context.retryCount + 1 < MAX_RETRIES,
    wasTimedOut: ({ context }) => context.timedOut,
  },
  actions: {
    storeBookId: assign({
      bookId: ({ event }) =>
        event.type === "INITIALIZE" ? event.bookId : "",
    }),
    resetIndex: assign({ paragraphIndex: 0, retryCount: 0 }),
    resetIndexByDirection: assign({
      paragraphIndex: ({ context }) =>
        context.direction === "backward"
          ? Math.max(0, context.currentParagraphs.length - 1)
          : 0,
      retryCount: 0,
    }),
    advanceIndex: assign({
      paragraphIndex: ({ context }) =>
        Math.min(context.paragraphIndex + 1, context.currentParagraphs.length - 1),
      direction: "forward" as const,
      retryCount: 0,
    }),
    retreatIndex: assign({
      paragraphIndex: ({ context }) =>
        Math.max(context.paragraphIndex - 1, 0),
      direction: "backward" as const,
      retryCount: 0,
    }),
    storeParagraphs: assign({
      currentParagraphs: ({ event }) =>
        event.type === "PARAGRAPHS_UPDATED" ? event.paragraphs : [],
    }),
    storeNextParagraphs: assign({
      nextPageParagraphs: ({ event }) =>
        event.type === "NEXT_PARAGRAPHS_UPDATED" ? event.paragraphs : [],
    }),
    storePrevParagraphs: assign({
      prevPageParagraphs: ({ event }) =>
        event.type === "PREV_PARAGRAPHS_UPDATED" ? event.paragraphs : [],
    }),
    incrementRetry: assign({
      retryCount: ({ context }) => context.retryCount + 1,
    }),
    logError: assign({
      errors: ({ context, event }) => {
        const msg =
          event.type === "AUDIO_ERROR"
            ? event.error
            : "Unknown error";
        const errs = [...context.errors, msg];
        if (errs.length > 50) errs.shift();
        return errs;
      },
    }),
    flagTimedOut: assign({ timedOut: true }),
    clearTimedOut: assign({ timedOut: false }),
    resetAll: assign(() => ({ ...initialContext })),
  },
}).createMachine({
  id: "player",
  initial: "idle",
  context: { ...initialContext },
  on: {
    CLEANUP: {
      target: ".idle",
      actions: "resetAll",
    },
  },
  states: {
    idle: {
      on: {
        INITIALIZE: {
          target: "stopped",
          actions: ["storeBookId", "resetIndex"],
        },
      },
    },

    stopped: {
      on: {
        PLAY: [
          {
            guard: "hasParagraphs",
            target: "loading",
          },
          {
            target: "waitingForParagraphs",
          },
        ],
        PARAGRAPHS_UPDATED: [
          {
            guard: "wasTimedOut",
            target: "loading",
            actions: ["storeParagraphs", "clearTimedOut", "resetIndexByDirection"],
          },
          {
            actions: ["storeParagraphs"],
          },
        ],
        NEXT_PARAGRAPHS_UPDATED: {
          actions: ["storeNextParagraphs"],
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: ["storePrevParagraphs"],
        },
      },
    },

    loading: {
      on: {
        AUDIO_LOADED: {
          target: "playing",
        },
        AUDIO_ERROR: [
          {
            guard: "hasRetries",
            target: "loading",
            actions: ["incrementRetry", "logError"],
            reenter: true,
          },
          {
            target: "error",
            actions: "logError",
          },
        ],
        STOP: {
          target: "stopped",
          actions: "resetIndex",
        },
        CLEANUP: {
          target: "idle",
          actions: "resetAll",
        },
      },
    },

    playing: {
      on: {
        PAUSE: {
          target: "paused",
        },
        STOP: {
          target: "stopped",
          actions: "resetIndex",
        },
        AUDIO_ENDED: [
          {
            guard: "hasMoreParagraphs",
            target: "loading",
            actions: "advanceIndex",
          },
          {
            target: "waitingForParagraphs",
          },
        ],
        NEXT: [
          {
            guard: "hasMoreParagraphs",
            target: "loading",
            actions: "advanceIndex",
          },
          {
            target: "waitingForParagraphs",
          },
        ],
        PREV: {
          target: "loading",
          actions: "retreatIndex",
        },
        PARAGRAPHS_UPDATED: {
          target: "loading",
          actions: ["storeParagraphs", "resetIndex"],
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: "storeNextParagraphs",
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: "storePrevParagraphs",
        },
      },
    },

    paused: {
      initial: "clean",
      on: {
        STOP: {
          target: "stopped",
          actions: "resetIndex",
        },
        NEXT_PARAGRAPHS_UPDATED: {
          actions: "storeNextParagraphs",
        },
        PREV_PARAGRAPHS_UPDATED: {
          actions: "storePrevParagraphs",
        },
      },
      states: {
        clean: {
          on: {
            RESUME: {
              target: "#player.playing",
            },
            PARAGRAPHS_UPDATED: {
              target: "stale",
              actions: ["storeParagraphs", "resetIndexByDirection"],
            },
          },
        },
        stale: {
          on: {
            RESUME: {
              target: "#player.loading",
            },
            PARAGRAPHS_UPDATED: {
              target: "stale",
              actions: ["storeParagraphs", "resetIndexByDirection"],
              reenter: true,
            },
          },
        },
      },
    },

    waitingForParagraphs: {
      after: {
        10000: {
          target: "stopped",
          actions: "flagTimedOut",
        },
      },
      on: {
        PARAGRAPHS_UPDATED: {
          target: "loading",
          actions: ["storeParagraphs", "clearTimedOut", "resetIndexByDirection"],
        },
        STOP: {
          target: "stopped",
          actions: "resetIndex",
        },
      },
    },

    error: {
      on: {
        NEXT: {
          target: "loading",
          actions: "advanceIndex",
        },
        STOP: {
          target: "stopped",
          actions: "resetIndex",
        },
        PLAY: {
          target: "loading",
          actions: assign({ retryCount: 0 }),
        },
      },
    },
  },
});
