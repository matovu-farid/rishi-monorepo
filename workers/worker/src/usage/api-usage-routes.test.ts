import { afterAll, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import { Effect } from "effect";
import { eq } from "drizzle-orm";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { signAccessToken } from "../jwt";
import { createDb } from "../db/drizzle";
import { createTestD1 } from "../test-utils/d1";
import { user, userApiUsage } from "@rishi/shared/schema";

const { openaiResponse, elevenLabsBytes } = vi.hoisted(() => ({
  openaiResponse: {
    value: "sec_test",
    expires_at: 1_700_000_000,
    id: "sess_test",
  },
  elevenLabsBytes: new Uint8Array([5, 6, 7, 8]),
}));

vi.mock("axios", () => ({
  default: {
    post: vi.fn(async () => ({ data: openaiResponse })),
  },
}));

vi.mock("openai", () => {
  class MockOpenAI {
    audio = {
      speech: {
        create: vi.fn(async () => ({
          arrayBuffer: async () => new Uint8Array([1, 2, 3, 4]).buffer,
        })),
      },
    };
  }

  return { default: MockOpenAI };
});

vi.mock("@sentry/cloudflare", () => ({
  withSentry: <T>(_options: unknown, handler: T) => handler,
}));

vi.stubGlobal(
  "fetch",
  vi.fn(async () =>
    new Response(elevenLabsBytes, {
      status: 200,
      headers: { "Content-Type": "audio/mpeg" },
    }),
  ),
);

vi.mock("../routes/sync", async () => {
  const { Hono } = await import("hono");
  return { syncRoutes: new Hono() };
});
vi.mock("../routes/upload", async () => {
  const { Hono } = await import("hono");
  return { uploadRoutes: new Hono() };
});
vi.mock("../routes/desktop", async () => {
  const { Hono } = await import("hono");
  return { desktopRoutes: new Hono() };
});
vi.mock("../routes/mobile", async () => {
  const { Hono } = await import("hono");
  return { mobileRoutes: new Hono() };
});
vi.mock("../routes/devices", async () => {
  const { Hono } = await import("hono");
  return { devicesRoutes: new Hono() };
});
vi.mock("../routes/chat", async () => {
  const { Hono } = await import("hono");
  return { chatRoutes: new Hono() };
});
vi.mock("../routes/conversations", async () => {
  const { Hono } = await import("hono");
  return { conversationsRoutes: new Hono() };
});
vi.mock("../routes/messages", async () => {
  const { Hono } = await import("hono");
  return { messagesRoutes: new Hono() };
});
vi.mock("../routes/changes", async () => {
  const { Hono } = await import("hono");
  return { changesRoutes: new Hono() };
});
vi.mock("../routes/test-auth", async () => {
  const { Hono } = await import("hono");
  return { testAuthRoutes: new Hono() };
});

vi.mock("../billing/backfill", () => ({
  ensureCreditAndSubscription: async () => undefined,
}));
vi.mock("../billing/portal", () => ({
  createPortalSession: async () => "https://example.invalid",
}));
vi.mock("../billing/realtime-usage", () => ({
  parseRealtimeUsageBody: () => ({ ok: true }),
}));
vi.mock("../billing/start", () => ({
  ensureCustomerAndPortal: async () => ({ url: "https://example.invalid" }),
}));
vi.mock("../billing/apple-verify-receipt", () => ({
  registerVerifyReceiptRoute: () => undefined,
}));
vi.mock("../billing/apple-webhook", () => ({
  registerAppleWebhookRoute: () => undefined,
}));
vi.mock("../billing/apple-me", () => ({
  registerBillingMeRoute: () => undefined,
}));
vi.mock("../billing/stripe", () => ({
  createStripeClient: () => ({}),
}));
vi.mock("../billing/meter", () => ({
  meterFromContext: async () => undefined,
}));
import { app } from "../index.ts";

const env = {
  ACCESS_TOKEN_SECRET: "access-secret",
  REFRESH_TOKEN_SECRET: "refresh-secret",
  OPENAI_API_KEY: "openai-test-key",
  ELEVEN_LABS_API_KEY: "elevenlabs-test-key",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  TTS_CACHE: {
    get: async () => null,
    put: async () => ({}),
  } as unknown as R2Bucket,
} as unknown as Env;

let db: D1Database & { close: () => void };
let pending: Promise<unknown>[];
let databaseDirectory: string;

async function tokenFor(userId: string) {
  return Effect.runPromise(signAccessToken(env, { userId }));
}

async function call(
  path: string,
  options: { method?: string; body?: unknown; userId?: string } = {},
) {
  const token = options.userId ? await tokenFor(options.userId) : undefined;
  const headers = new Headers();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body !== undefined) headers.set("Content-Type", "application/json");

  return app.fetch(
    new Request(`https://api.fidexa.org${path}`, {
      method: options.method ?? "GET",
      headers,
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
    { ...env, DB: db },
    {
      waitUntil(promise: Promise<unknown>) {
        pending.push(promise);
      },
      passThroughOnException() {},
    } as unknown as ExecutionContext,
  );
}

async function usageFor(userId: string) {
  return createDb(db)
    .select({
      voiceChatRequests: userApiUsage.voiceChatRequests,
      ttsRequests: userApiUsage.ttsRequests,
    })
    .from(userApiUsage)
    .where(eq(userApiUsage.userId, userId))
    .get();
}

beforeAll(async () => {
  databaseDirectory = mkdtempSync(join(tmpdir(), "rishi-api-usage-"));
  db = createTestD1(join(databaseDirectory, "rishi.sqlite"));
});

afterAll(() => {
  db.close();
  rmSync(databaseDirectory, { recursive: true, force: true });
});

beforeEach(async () => {
  const testDb = createDb(db);
  await testDb.delete(userApiUsage).run();
  await testDb.delete(user).run();
  pending = [];
  await testDb
    .insert(user)
    .values([
      {
        id: "user_alice",
        name: "Alice",
        email: "alice@example.com",
        emailVerified: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      },
      {
        id: "user_bob",
        name: "Bob",
        email: "bob@example.com",
        emailVerified: false,
        createdAt: new Date(),
        updatedAt: new Date(),
      },
    ])
    .run();
});

describe("authenticated voice and TTS usage flows", () => {
  it("persists and accumulates voice-chat requests without a subscription", async () => {
    const first = await call("/api/realtime/client_secrets", {
      method: "POST",
      body: { language: "en" },
      userId: "user_alice",
    });
    const second = await call("/api/realtime/client_secrets", {
      method: "POST",
      body: { language: "en" },
      userId: "user_alice",
    });
    expect(first.status).toBe(200);
    expect(second.status).toBe(200);
    await Promise.all(pending);
    await expect(usageFor("user_alice")).resolves.toEqual({
      voiceChatRequests: 2,
      ttsRequests: 0,
    });
  });

  it("persists TTS requests for both providers and keeps users separate", async () => {
    const openAi = await call("/api/audio/speech", {
      method: "POST",
      body: { text: "hello", voice: "alloy", speed: 1 },
      userId: "user_alice",
    });
    const elevenLabs = await call("/api/audio/speech/elevenlabs", {
      method: "POST",
      body: { text: "hello", voice: "alloy", model: "eleven_v3", speed: 1 },
      userId: "user_bob",
    });
    await Promise.all(pending);

    expect(openAi.status).toBe(200);
    expect(elevenLabs.status).toBe(200);
    await expect(usageFor("user_alice")).resolves.toEqual({
      voiceChatRequests: 0,
      ttsRequests: 1,
    });
    await expect(usageFor("user_bob")).resolves.toEqual({
      voiceChatRequests: 0,
      ttsRequests: 1,
    });
  });

  it("rejects unauthenticated requests and does not create usage rows", async () => {
    const response = await call("/api/audio/speech", {
      method: "POST",
      body: { text: "hello", voice: "alloy", speed: 1 },
    });

    expect(response.status).toBe(401);
    await expect(usageFor("user_alice")).resolves.toBeUndefined();
  });

  it("does not count the unauthenticated TTS options lookup", async () => {
    const response = await call("/api/audio/speech/options");

    expect(response.status).toBe(200);
    await expect(usageFor("user_alice")).resolves.toBeUndefined();
  });
});
