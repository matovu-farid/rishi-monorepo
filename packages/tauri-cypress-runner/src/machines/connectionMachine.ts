import { setup, assign } from "xstate";

export const connectionMachine = setup({
  types: {
    context: {} as { retryCount: number; maxRetries: number },
    events: {} as
      | { type: "CONNECT" }
      | { type: "CONNECTED" }
      | { type: "DISCONNECTED" }
      | { type: "ERROR"; error: string }
      | { type: "RETRY" },
  },
}).createMachine({
  id: "connection",
  initial: "disconnected",
  context: { retryCount: 0, maxRetries: 3 },
  states: {
    disconnected: { on: { CONNECT: "connecting" } },
    connecting: {
      on: {
        CONNECTED: { target: "connected", actions: assign({ retryCount: 0 }) },
        ERROR: [
          { target: "connecting", guard: ({ context }) => context.retryCount < context.maxRetries, actions: assign({ retryCount: ({ context }) => context.retryCount + 1 }) },
          { target: "error" },
        ],
      },
    },
    connected: { on: { DISCONNECTED: "disconnected", ERROR: "error" } },
    error: { on: { RETRY: { target: "connecting", actions: assign({ retryCount: 0 }) } } },
  },
});
