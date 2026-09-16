import { afterEach, describe, expect, it, vi } from "vitest";

const { authState } = vi.hoisted(() => ({
  authState: { userId: "user-web-bytes" as string | null },
}));

vi.mock("./auth", () => ({
  createAuth: async () => ({
    api: {
      getSession: async () =>
        authState.userId
          ? {
              user: { id: authState.userId },
              session: { token: "token-web-bytes" },
            }
          : null,
    },
  }),
}));

vi.mock("./middleware", () => ({
  requireAuthForDeletion: async (_c: unknown, next: () => Promise<void>) =>
    next(),
  requireAuth: async (_c: unknown, next: () => Promise<void>) => next(),
}));

vi.mock("./db/drizzle", () => ({ createDb: () => ({}) }));
vi.mock("./billing/sub-gate", () => ({
  requireActiveSubscription: async (
    _c: unknown,
    next: () => Promise<void>,
  ) => next(),
  isAllowedForBilledFeature: () => true,
}));
vi.mock("./billing/backfill", () => ({
  ensureCreditAndSubscription: async () => undefined,
}));
vi.mock("./billing/meter", () => ({ meterFromContext: async () => undefined }));
vi.mock("./billing/portal", () => ({
  createPortalSession: async () => ({ url: "" }),
}));
vi.mock("./billing/start", () => ({
  ensureCustomerAndPortal: async () => ({ url: "" }),
}));
vi.mock("./billing/realtime-usage", () => ({
  parseRealtimeUsageBody: () => null,
}));
vi.mock("./billing/stripe", () => ({ createStripeClient: () => ({}) }));
vi.mock("./billing/apple-verify-receipt", () => ({
  registerVerifyReceiptRoute: () => undefined,
}));
vi.mock("./billing/apple-webhook", () => ({
  registerAppleWebhookRoute: () => undefined,
}));
vi.mock("./billing/apple-me", () => ({
  registerBillingMeRoute: () => undefined,
}));
vi.mock("./durable-objects/user-usage-ledger/ledger", () => ({
  UserUsageLedger: class UserUsageLedger {},
}));

vi.mock("./routes/test-auth", async () => {
  const { Hono } = await import("hono");
  return { testAuthRoutes: new Hono() };
});
vi.mock("@upstash/redis/cloudflare", () => ({
  Redis: { fromEnv: () => ({ set: async () => undefined, get: async () => null }) },
}));
vi.mock("@sentry/cloudflare", () => ({
  withSentry: (_options: unknown, handler: unknown) => handler,
}));

import { app } from "./index";

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  DEEPGRAM_KEY: "deepgram-test-key",
  OPENAI_API_KEY: "openai-test-key",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {},
} as unknown as Record<string, unknown>;

const audioBytes = Uint8Array.from([0, 1, 255, 17, 32]);
const audioBase64 = Buffer.from(audioBytes).toString("base64");

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("Worker Web API byte boundaries", () => {
  it("normalizes every Web API binary boundary", async () => {
    const captured: Array<{ url: string; init: RequestInit }> = [];
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: unknown, init?: RequestInit) => {
        captured.push({
          url: typeof input === "string" ? input : String(input),
          init: init ?? {},
        });
        return new Response(
          JSON.stringify({
            results: {
              channels: [{ alternatives: [{ transcript: "decoded" }] }],
            },
          }),
          { status: 200, headers: { "Content-Type": "application/json" } },
        );
      }),
    );

    const response = await app.fetch(
      new Request("https://api.fidexa.org/api/audio/transcribe", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Rishi-Data-Use-Consent": "2026-07-29",
        },
        body: JSON.stringify({ audio: audioBase64, mime_type: "audio/wav" }),
      }),
      env,
      {
        waitUntil: () => undefined,
        passThroughOnException: () => undefined,
      } as unknown as ExecutionContext,
    );

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ transcript: "decoded" });

    const deepgram = captured.find((call) => call.url.includes("api.deepgram.com"));
    expect(deepgram).toBeDefined();
    expect(deepgram!.init.body).toBeInstanceOf(ArrayBuffer);
    expect(
      Array.from(new Uint8Array(deepgram!.init.body as ArrayBuffer)),
    ).toEqual(Array.from(audioBytes));
  });
});
