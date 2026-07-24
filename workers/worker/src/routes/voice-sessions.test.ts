import { describe, expect, it, vi } from "vitest";

vi.mock("../middleware", () => ({
  requireAuth: async (c: any, next: () => Promise<void>) => {
    c.set("userId", "user_alice");
    await next();
  },
}));

vi.mock("../billing/allowance-period-rollover", () => ({
  rollAllowancePeriodsForward: vi.fn(async () => undefined),
}));

vi.mock("../realtime/client-secrets", () => ({
  coerceLanguage: (language: string | undefined) => language ?? "en",
  mintRealtimeClientSecret: vi.fn(async () => ({
    clientSecret: "ek_test",
    sessionId: "openai_session",
    expiresAt: 1_700_000_000,
  })),
}));

import { REALTIME_VOICE_MODEL } from "@rishi/shared/realtime/model";
import { voiceSessionsRoutes } from "./voice-sessions";

describe("POST /api/voice-sessions", () => {
  it("returns the canonical realtime model with the minted session contract", async () => {
    const app = voiceSessionsRoutes;
    const env = {
      USER_USAGE_LEDGER: {
        getByName: () => ({
          createVoiceSession: async () => ({
            rishiSessionId: "rishi_session",
            nonce: "nonce_test",
            capIntervals: 12,
          }),
        }),
      },
    } as any;

    const response = await app.request(
      "/",
      { method: "POST", body: "{}", headers: { "content-type": "application/json" } },
      env,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      rishiSessionId: "rishi_session",
      nonce: "nonce_test",
      clientSecret: "ek_test",
      capIntervals: 12,
      realtimeModel: REALTIME_VOICE_MODEL,
    });
  });
});
