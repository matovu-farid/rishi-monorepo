// apps/main/src/machines/navMachine.ts
//
// Centralised EPUB page-navigation state machine.
// Every caller (buttons, keyboard, swipe, page-curl gesture, TTS player)
// sends an event here instead of calling rendition.next()/prev()/display()
// directly.  The machine serialises requests so only one navigation can be
// in-flight at a time, eliminating the "snap-back" and double-navigation
// race conditions.

import { setup, assign } from "xstate";

// ── Types ──────────────────────────────────────────────────────────────

export type NavAction = "next" | "prev" | "display";

export type NavMachineContext = {
  /** Which rendition method the current transition should invoke. */
  pendingAction: NavAction;
  /** Target CFI / href for DISPLAY navigations. */
  pendingLocation: string | null;
  /** Direction stored on curl-start so we can reverse on cancel. */
  curlDirection: "next" | "prev" | null;
  /** Monotonic counter — bumped by every action that requires a side-effect
   *  so the hook can detect re-entries (e.g. DISPLAY while navigating). */
  version: number;
  /** True once the curl's rendition call has resolved (SETTLED received
   *  while still in `curling`).  Lets CURL_COMMIT go straight to idle
   *  instead of through the `settling` wait state. */
  curlSettled: boolean;
};

export type NavMachineEvent =
  | { type: "NEXT" }
  | { type: "PREV" }
  | { type: "DISPLAY"; location: string }
  | { type: "CURL_NEXT" }
  | { type: "CURL_PREV" }
  | { type: "CURL_COMMIT" }
  | { type: "CURL_CANCEL" }
  | { type: "SETTLED" };

export type NavState =
  | "idle"
  | "navigating"
  | "curling"
  | "settling"
  | "undoing";

// ── Machine ────────────────────────────────────────────────────────────

const initialContext: NavMachineContext = {
  pendingAction: "next",
  pendingLocation: null,
  curlDirection: null,
  version: 0,
  curlSettled: false,
};

export const navMachine = setup({
  types: {
    context: {} as NavMachineContext,
    events: {} as NavMachineEvent,
  },
  guards: {
    isCurlSettled: ({ context }) => context.curlSettled,
  },
  actions: {
    setNext: assign({
      pendingAction: "next" as NavAction,
      pendingLocation: null,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    setPrev: assign({
      pendingAction: "prev" as NavAction,
      pendingLocation: null,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    setDisplay: assign({
      pendingAction: "display" as NavAction,
      pendingLocation: ({ event }: { event: NavMachineEvent }) =>
        event.type === "DISPLAY" ? event.location : null,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    setCurlNext: assign({
      pendingAction: "next" as NavAction,
      curlDirection: "next" as const,
      pendingLocation: null,
      curlSettled: false,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    setCurlPrev: assign({
      pendingAction: "prev" as NavAction,
      curlDirection: "prev" as const,
      pendingLocation: null,
      curlSettled: false,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    setUndoCurl: assign({
      pendingAction: ({ context }: { context: NavMachineContext }) =>
        (context.curlDirection === "next" ? "prev" : "next") as NavAction,
      curlDirection: null as NavMachineContext["curlDirection"],
      pendingLocation: null,
      version: ({ context }: { context: NavMachineContext }) => context.version + 1,
    }),
    markCurlSettled: assign({ curlSettled: true }),
  },
}).createMachine({
  id: "nav",
  initial: "idle",
  context: { ...initialContext },

  // ── Global handlers — these can interrupt ANY state ──────────────
  on: {
    // TOC / bookmark jump — always wins
    DISPLAY: {
      target: ".navigating",
      actions: "setDisplay",
    },
  },

  states: {
    // ── Idle — ready to accept any navigation event ────────────────
    idle: {
      on: {
        NEXT: {
          target: "navigating",
          actions: "setNext",
        },
        PREV: {
          target: "navigating",
          actions: "setPrev",
        },
        CURL_NEXT: {
          target: "curling",
          actions: "setCurlNext",
        },
        CURL_PREV: {
          target: "curling",
          actions: "setCurlPrev",
        },
      },
    },

    // ── Navigating — rendition.next()/prev()/display() in-flight ──
    navigating: {
      after: {
        30000: "idle", // safety timeout — generous to avoid false fires
      },
      on: {
        SETTLED: "idle",
      },
    },

    // ── Curling — page-curl gesture in progress ───────────────────
    //    rendition.next()/prev() was fired on entry.  We wait for
    //    either the animation to commit/cancel or the rendition
    //    promise to settle (whichever comes first).
    curling: {
      on: {
        // rendition call completed before the animation finished —
        // remember it so CURL_COMMIT can skip the settling wait.
        SETTLED: {
          actions: "markCurlSettled",
        },
        CURL_COMMIT: [
          {
            guard: "isCurlSettled",
            target: "idle",
          },
          {
            // rendition still in-flight — wait for SETTLED
            target: "settling",
          },
        ],
        CURL_CANCEL: {
          target: "undoing",
          actions: "setUndoCurl",
        },
      },
    },

    // ── Settling — curl animation done, waiting for rendition ─────
    settling: {
      after: {
        30000: "idle", // safety timeout
      },
      on: {
        SETTLED: "idle",
      },
    },

    // ── Undoing — reversing a cancelled curl ──────────────────────
    undoing: {
      after: {
        30000: "idle", // safety timeout
      },
      on: {
        SETTLED: "idle",
      },
    },
  },
});
