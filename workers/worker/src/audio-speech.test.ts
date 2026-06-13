import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Phase 17-03: Wire-contract reconciliation for POST /api/audio/speech.
 *
 * iOS `SpeechStreamEndpoint.Body`
 * (apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AudioAPI.swift) sends:
 *
 *   { text: String, voice: String, speed: Double }
 *
 * The deployed worker historically read `{ input, voice }` and ignored speed,
 * so every TTSStreamer.swift call short-circuited with
 *   400 "Missing or empty input text"
 * because body.input was always undefined.
 *
 * These tests assert the iOS body shape end-to-end against the Hono `app`:
 *   1. Happy path: { text, voice, speed=1.0 } -> 200 + audio/mpeg.
 *   2. Old shape rejection: { input, voice } (no `text`) -> 400 envelope.
 *   3. Speed forwarded: speed=1.5 reaches the AI SDK's generateSpeech call.
 *   4. Voice fallback unchanged: invalid voice falls back to "alloy".
 */

// ─── Capture the args passed to experimental_generateSpeech ──────────────────
const { speechCalls, speechAudioBytes } = vi.hoisted(() => ({
  speechCalls: [] as Array<Record<string, unknown>>,
  speechAudioBytes: new Uint8Array([1, 2, 3, 4]),
}))

vi.mock("ai", async () => {
  // Preserve APICallError for the error-handling branch in the handler.
  const actual = await vi.importActual<typeof import("ai")>("ai")
  return {
    ...actual,
    experimental_generateSpeech: vi.fn(async (args: Record<string, unknown>) => {
      speechCalls.push(args)
      return {
        audio: { uint8Array: speechAudioBytes },
      }
    }),
  }
})

// ─── Mock @ai-sdk/openai so getOpenAI(...) doesn't need a real key ────────────
vi.mock("@ai-sdk/openai", () => ({
  createOpenAI: () => ({
    speech: (model: string) => ({ __model: model }),
  }),
}))

// ─── Mock Sentry wrapper — we import the bare `app`, not the default export ──
vi.mock("@sentry/cloudflare", () => ({
  withSentry: <T>(_options: unknown, handler: T) => handler,
}))

// ─── Mock the metering side-effect so a missing DB doesn't crash waitUntil ──
vi.mock("./billing/meter", () => ({
  meterFromContext: vi.fn(async () => undefined),
}))

// ─── Stub requireActiveSubscription to a pass-through middleware ────────────
vi.mock("./billing/sub-gate", () => ({
  requireActiveSubscription: async (
    _c: unknown,
    next: () => Promise<void>,
  ) => {
    await next()
  },
}))

// ─── Stub createAuth so the index.ts requireAuth sees a session ─────────────
const { authState } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
}))

function setUser(id: string | null) {
  authState.userId = id
}

vi.mock("./auth", () => ({
  createAuth: async () => ({
    api: {
      getSession: async () => {
        if (!authState.userId) return null
        return {
          user: { id: authState.userId },
          session: { token: "tok_test" },
        }
      },
    },
    handler: async () => new Response("", { status: 200 }),
  }),
}))

// Side-routes mounted in index.ts pull in Drizzle + DB; stub each with a real
// empty Hono router so `app.route(...)` mounts succeed without dragging in
// the real Drizzle wiring.
vi.mock("./routes/sync", async () => {
  const { Hono } = await import("hono")
  return { syncRoutes: new Hono() }
})
vi.mock("./routes/upload", async () => {
  const { Hono } = await import("hono")
  return { uploadRoutes: new Hono() }
})
vi.mock("./routes/desktop", async () => {
  const { Hono } = await import("hono")
  return { desktopRoutes: new Hono() }
})
vi.mock("./routes/mobile", async () => {
  const { Hono } = await import("hono")
  return { mobileRoutes: new Hono() }
})
vi.mock("./routes/devices", async () => {
  const { Hono } = await import("hono")
  return { devicesRoutes: new Hono() }
})
vi.mock("./routes/chat", async () => {
  const { Hono } = await import("hono")
  return { chatRoutes: new Hono() }
})
vi.mock("./routes/conversations", async () => {
  const { Hono } = await import("hono")
  return { conversationsRoutes: new Hono() }
})
vi.mock("./routes/messages", async () => {
  const { Hono } = await import("hono")
  return { messagesRoutes: new Hono() }
})
vi.mock("./routes/changes", async () => {
  const { Hono } = await import("hono")
  return { changesRoutes: new Hono() }
})
vi.mock("./routes/test-auth", async () => {
  const { Hono } = await import("hono")
  return { testAuthRoutes: new Hono() }
})

// Apple/Stripe billing extras register routes by calling app.post(...) directly
// via a factory; stub them to no-ops so import-time side-effects don't fail.
vi.mock("./billing/backfill", () => ({
  ensureCreditAndSubscription: async () => undefined,
}))
vi.mock("./billing/portal", () => ({
  createPortalSession: async () => "https://example.invalid",
}))
vi.mock("./billing/realtime-usage", () => ({
  parseRealtimeUsageBody: () => ({ ok: true }),
}))
vi.mock("./billing/start", () => ({
  ensureCustomerAndPortal: async () => ({ url: "https://example.invalid" }),
}))
vi.mock("./billing/apple-verify-receipt", () => ({
  registerVerifyReceiptRoute: () => undefined,
}))
vi.mock("./billing/apple-webhook", () => ({
  registerAppleWebhookRoute: () => undefined,
}))
vi.mock("./billing/apple-me", () => ({
  registerBillingMeRoute: () => undefined,
}))
vi.mock("./billing/stripe", () => ({
  createStripeClient: () => ({}),
}))

vi.mock("./db/drizzle", () => ({
  createDb: () => ({
    select: () => ({
      from: () => ({
        where: () => ({ get: async () => null }),
      }),
    }),
  }),
}))

vi.mock("@rishi/shared/schema", () => ({
  user: {},
  session: {},
  account: {},
  verification: {},
  passkey: {},
  syncMeta: {},
  appleSubscriptions: {},
  appleNotificationsLog: {},
  subscription: {},
  devices: {},
  books: {},
  highlights: {},
  conversations: {},
  messages: {},
  bookmarks: {},
}))

vi.mock("@rishi/shared/billing/stripe-config", () => ({
  getStripeIdsForKey: () => ({}),
}))

vi.mock("drizzle-orm", () => ({
  eq: () => ({}),
  desc: () => ({}),
  and: () => ({}),
}))

vi.mock("@upstash/redis/cloudflare", () => ({
  Redis: { fromEnv: () => ({ get: async () => null, set: async () => null }) },
}))

// ─── Import the Hono app under test ──────────────────────────────────────────
import { app } from "./index"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  OPENAI_API_KEY: "test-openai-key",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  // STRIPE_SECRET_KEY left undefined so the sub-gate's billing-disabled path
  // is irrelevant here — we already stubbed the middleware to a pass-through.
  // Phase 22-01: the speech handler now reads c.env.TTS_CACHE.get(...) before
  // calling OpenAI. These body-shape tests assert miss-path behavior, so the
  // stub returns null unconditionally and a no-op put silently succeeds.
  TTS_CACHE: {
    get: async () => null,
    put: async () => ({}),
  } as unknown as R2Bucket,
} as unknown as Record<string, unknown>

const ctx = {
  waitUntil: (_p: Promise<unknown>) => undefined,
  passThroughOnException: () => undefined,
} as unknown as ExecutionContext

async function callSpeech(body: unknown) {
  const req = new Request("https://api.fidexa.org/api/audio/speech", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  })
  return app.fetch(req, env, ctx)
}

beforeEach(() => {
  speechCalls.length = 0
  setUser("user_alice")
})

describe("POST /api/audio/speech — iOS body shape (Phase 17-03)", () => {
  it("happy path: { text, voice, speed } -> 200 + audio/mpeg", async () => {
    const res = await callSpeech({ text: "hello world", voice: "alloy", speed: 1.0 })
    expect(res.status).toBe(200)
    expect(res.headers.get("Content-Type")).toBe("audio/mpeg")
    const bytes = new Uint8Array(await res.arrayBuffer())
    expect(bytes.length).toBe(speechAudioBytes.length)
    expect(speechCalls.length).toBe(1)
  })

  it("old shape: { input, voice } (no `text` key) -> 400 missing-text envelope", async () => {
    const res = await callSpeech({ input: "hello world", voice: "alloy" })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string }
    expect(body.error).toMatch(/missing.*text|empty.*text/i)
    expect(speechCalls.length).toBe(0)
  })

  it("speed is forwarded into experimental_generateSpeech args", async () => {
    const res = await callSpeech({ text: "hi", voice: "alloy", speed: 1.5 })
    expect(res.status).toBe(200)
    expect(speechCalls.length).toBe(1)
    expect(speechCalls[0]).toMatchObject({ speed: 1.5 })
  })

  it("invalid voice falls back to 'alloy' (existing whitelist behavior)", async () => {
    const res = await callSpeech({ text: "hi", voice: "invalid-voice", speed: 1.0 })
    expect(res.status).toBe(200)
    expect(speechCalls.length).toBe(1)
    expect(speechCalls[0]).toMatchObject({ voice: "alloy" })
  })
})
