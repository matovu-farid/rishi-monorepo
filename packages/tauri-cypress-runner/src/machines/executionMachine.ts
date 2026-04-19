import { setup, assign } from "xstate";

export const executionMachine = setup({
  types: {
    context: {} as { currentFile: string | null; error: string | null },
    events: {} as
      | { type: "START"; file?: string }
      | { type: "BUILD_COMPLETE" }
      | { type: "BUILD_FAILED"; error: string }
      | { type: "APP_READY" }
      | { type: "LAUNCH_FAILED"; error: string }
      | { type: "CONNECTED" }
      | { type: "CONNECT_FAILED"; error: string }
      | { type: "TEST_COMPLETE" }
      | { type: "ALL_COMPLETE" }
      | { type: "RESET" },
  },
}).createMachine({
  id: "execution",
  initial: "idle",
  context: { currentFile: null, error: null },
  states: {
    idle: { on: { START: { target: "building", actions: assign({ currentFile: ({ event }) => event.file ?? null, error: null }) } } },
    building: { on: { BUILD_COMPLETE: "launching", BUILD_FAILED: { target: "build_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    build_failed: { on: { START: { target: "building", actions: assign({ error: null }) }, RESET: "idle" } },
    launching: { on: { APP_READY: "connecting", LAUNCH_FAILED: { target: "launch_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    launch_failed: { on: { START: "building", RESET: "idle" } },
    connecting: { on: { CONNECTED: "running", CONNECT_FAILED: { target: "connect_failed", actions: assign({ error: ({ event }) => event.error }) } } },
    connect_failed: { on: { START: "building", RESET: "idle" } },
    running: { on: { TEST_COMPLETE: "running", ALL_COMPLETE: "complete" } },
    complete: { on: { START: "building", RESET: "idle" } },
  },
});
