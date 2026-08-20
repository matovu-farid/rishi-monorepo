import { beforeEach, describe, expect, it, vi } from "vitest";

const orderingState = vi.hoisted(() => ({
  events: [] as string[],
}));

vi.mock("../middleware", () => ({
  requireAuth: async (c: any, next: () => Promise<void>) => {
    if (c.req.header("Authorization") !== "Bearer test-token") {
      return c.json({ error: "Unauthorized" }, 401);
    }
    c.set("userId", "user_alice");
    return next();
  },
}));

vi.mock("../middleware/ai-data-consent", () => ({
  requireAiDataConsent: async (c: any, next: () => Promise<void>) => {
    if (c.req.header("X-Rishi-Data-Use-Consent") !== "2026-07-29") {
      return c.json({ error: "AI_DATA_CONSENT_REQUIRED" }, 428);
    }
    await next();
  },
}));

vi.mock("../billing/allowance-period-rollover", () => ({
  rollAllowancePeriodsForward: vi.fn(async () => {
    orderingState.events.push("allowance_refresh_complete");
  }),
}));

vi.mock("../realtime/client-secrets", () => ({
  coerceLanguage: (language: string | undefined) => language ?? "en",
  mintRealtimeClientSecret: vi.fn(async () => {
    orderingState.events.push("openai_mint");
    return {
      clientSecret: "ek_test",
      sessionId: "openai_session",
      expiresAt: 1_700_000_000,
    };
  }),
}));

import { REALTIME_VOICE_MODEL } from "@rishi/shared/realtime/model";
import { voiceSessionsRoutes } from "./voice-sessions";

describe("POST /api/voice-sessions", () => {
  beforeEach(() => {
    orderingState.events = [];
  });

  it("rejects missing consent before parsing, allowance refresh, ledger, or provider mint", async () => {
    const refresh = (await import("../billing/allowance-period-rollover")).rollAllowancePeriodsForward;
    const mint = (await import("../realtime/client-secrets")).mintRealtimeClientSecret;
    vi.mocked(mint).mockClear();
    const response = await voiceSessionsRoutes.request(
      "/",
      { method: "POST", body: "not-json", headers: { "content-type": "application/json", Authorization: "Bearer test-token" } },
      { USER_USAGE_LEDGER: { getByName: () => ({ createVoiceSession: async () => { throw new Error("must not run"); } }) } } as any,
    );

    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" });
    expect(refresh).not.toHaveBeenCalled();
    expect(mint).not.toHaveBeenCalled();
  });

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
      { method: "POST", body: "{}", headers: { "content-type": "application/json", Authorization: "Bearer test-token", "X-Rishi-Data-Use-Consent": "2026-07-29" } },
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

  it("completes allowance refresh before minting an OpenAI credential", async () => {
    let releaseRefresh!: () => void;
    const refreshGate = new Promise<void>((resolve) => {
      releaseRefresh = resolve;
    });
    const refresh = (await import("../billing/allowance-period-rollover")).rollAllowancePeriodsForward;
    const mint = (await import("../realtime/client-secrets")).mintRealtimeClientSecret;
    vi.mocked(mint).mockClear();
    vi.mocked(refresh).mockImplementationOnce(async () => {
      orderingState.events.push("allowance_started");
      await refreshGate;
      orderingState.events.push("allowance_refresh_complete");
    });

    const requestTask = voiceSessionsRoutes.request(
      "/",
      {
        method: "POST",
        body: "{}",
        headers: {
          "content-type": "application/json",
          Authorization: "Bearer test-token",
          "X-Rishi-Data-Use-Consent": "2026-07-29",
        },
      },
      {
        USER_USAGE_LEDGER: {
          getByName: () => ({
            createVoiceSession: async () => ({
              rishiSessionId: "rishi_ordered",
              nonce: "nonce_ordered",
              capIntervals: 12,
            }),
          }),
        },
      } as any,
    );

    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(orderingState.events).toEqual(["allowance_started"]);
    expect(mint).not.toHaveBeenCalled();
    releaseRefresh();
    const response = await requestTask;
    expect(response.status).toBe(200);
    expect(orderingState.events).toEqual([
      "allowance_started",
      "allowance_refresh_complete",
      "openai_mint",
    ]);
  });

  it("does not mint or admit a session when allowance refresh rejects", async () => {
    const refresh = (await import("../billing/allowance-period-rollover")).rollAllowancePeriodsForward;
    const mint = (await import("../realtime/client-secrets")).mintRealtimeClientSecret;
    vi.mocked(refresh).mockRejectedValueOnce(new Error("allowance rejected"));
    vi.mocked(mint).mockClear();
    const getByName = vi.fn();

    const response = await voiceSessionsRoutes.request(
      "/",
      {
        method: "POST",
        body: "{}",
        headers: {
          "content-type": "application/json",
          Authorization: "Bearer test-token",
          "X-Rishi-Data-Use-Consent": "2026-07-29",
        },
      },
      { USER_USAGE_LEDGER: { getByName } } as any,
    );

    expect(response.status).toBe(500);
    expect(mint).not.toHaveBeenCalled();
    expect(getByName).not.toHaveBeenCalled();
  });
});

describe("GET /api/voice-sessions/:id/control", () => {
  it("rejects missing consent before checking the ledger or upgrading", async () => {
    const getSessionSnapshot = vi.fn(async () => ({ active: true }));
    const response = await voiceSessionsRoutes.request(
      "/session_1/control",
      {
        method: "GET",
        headers: { upgrade: "websocket", Authorization: "Bearer test-token" },
      },
      { USER_USAGE_LEDGER: { getByName: () => ({ getSessionSnapshot }) } } as any,
    );

    expect(response.status).toBe(428);
    expect(getSessionSnapshot).not.toHaveBeenCalled();
  });
});

describe("voice session mutation consent boundaries", () => {
  it.each([
    ["end-active", "/end-active"],
    ["register-call", "/session_1/register-call"],
  ])("rejects missing consent on %s before ledger work", async (_name, path) => {
    const getByName = vi.fn(() => ({
      endActiveVoiceSession: vi.fn(),
      registerCallId: vi.fn(),
    }));
    const response = await voiceSessionsRoutes.request(
      path,
      {
        method: "POST",
        body: path.endsWith("register-call") ? "not-json" : undefined,
        headers: { Authorization: "Bearer test-token" },
      },
      { USER_USAGE_LEDGER: { getByName } } as any,
    );

    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" });
    expect(getByName).not.toHaveBeenCalled();
  });

  it.each([
    ["end-active", "/end-active"],
    ["register-call", "/session_1/register-call"],
  ])("rejects unsupported consent on %s", async (_name, path) => {
    const response = await voiceSessionsRoutes.request(
      path,
      {
        method: "POST",
        body: path.endsWith("register-call") ? "{}" : undefined,
        headers: {
          Authorization: "Bearer test-token",
          "X-Rishi-Data-Use-Consent": "2026-01-01",
        },
      },
      { USER_USAGE_LEDGER: { getByName: vi.fn() } } as any,
    );

    expect(response.status).toBe(428);
    expect(await response.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" });
  });
});
