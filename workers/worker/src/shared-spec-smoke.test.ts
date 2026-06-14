import { describe, it, expect } from "vitest";
import {
  BOOK_CONTEXT_TOOL_SPEC,
  renderRealtimeInstructions,
} from "@rishi/shared/voice-chat/build-realtime-agent";

// Phase 25-02 sanity gate.
//
// This file exists for two reasons:
//   1. Prove at compile time that the worker's tsconfig allows importing
//      `build-realtime-agent.ts` out of `@rishi/shared/voice-chat/` even
//      though the heavy `index.ts` re-exports in that directory are still
//      excluded (browser-only WebRTC / MediaPort / createVoiceChatService).
//   2. Lock the wire-stable contract of `BOOK_CONTEXT_TOOL_SPEC` so a
//      future refactor in `packages/shared` does not silently break Plan
//      25-06's `/api/realtime/client_secrets` rewrite, which feeds this
//      spec straight to OpenAI's Realtime API as the registered tool.
//
// If this file fails to compile, run `pnpm --filter rishi-worker exec tsc
// --noEmit` and check `workers/worker/tsconfig.json` — the broad
// `voice-chat/**` exclude must NOT be reintroduced.

describe("shared voice-chat spec import (Phase 25-02)", () => {
  it("BOOK_CONTEXT_TOOL_SPEC has the wire-stable contract", () => {
    expect(BOOK_CONTEXT_TOOL_SPEC.name).toBe("bookContext");
    expect(BOOK_CONTEXT_TOOL_SPEC.parameters.type).toBe("object");
    expect(BOOK_CONTEXT_TOOL_SPEC.parameters.required).toEqual(["queryText"]);
    expect(BOOK_CONTEXT_TOOL_SPEC.parameters.properties.queryText.type).toBe(
      "string",
    );
  });

  it("renderRealtimeInstructions returns a non-empty markdown prompt", () => {
    const md = renderRealtimeInstructions({
      pageText: "hello world",
      language: "en",
    });
    expect(md).toContain("## Role");
    expect(md).toContain("hello world");
  });
});
