import { setup, assign } from "xstate";

export const timeTravelMachine = setup({
  types: {
    context: {} as { snapshotIndex: number; maxIndex: number },
    events: {} as
      | { type: "ACTIVATE"; index: number; maxIndex: number }
      | { type: "NEXT" }
      | { type: "PREV" }
      | { type: "GO_TO"; index: number }
      | { type: "UPDATE_MAX"; maxIndex: number }
      | { type: "DEACTIVATE" },
  },
}).createMachine({
  id: "timeTravel",
  initial: "off",
  context: { snapshotIndex: 0, maxIndex: 0 },
  states: {
    off: {
      on: {
        ACTIVATE: {
          target: "active",
          actions: assign({
            snapshotIndex: ({ event }) => event.index,
            maxIndex: ({ event }) => event.maxIndex,
          }),
        },
      },
    },
    active: {
      on: {
        NEXT: {
          actions: assign({
            snapshotIndex: ({ context }) => Math.min(context.snapshotIndex + 1, context.maxIndex),
          }),
        },
        PREV: {
          actions: assign({
            snapshotIndex: ({ context }) => Math.max(context.snapshotIndex - 1, 0),
          }),
        },
        GO_TO: {
          actions: assign({
            snapshotIndex: ({ event, context }) =>
              Math.max(0, Math.min(event.index, context.maxIndex)),
          }),
        },
        UPDATE_MAX: {
          actions: assign({ maxIndex: ({ event }) => event.maxIndex }),
        },
        ACTIVATE: {
          actions: assign({
            snapshotIndex: ({ event }) => event.index,
            maxIndex: ({ event }) => event.maxIndex,
          }),
        },
        DEACTIVATE: "off",
      },
    },
  },
});
