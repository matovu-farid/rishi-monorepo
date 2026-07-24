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
 *   3. Speed forwarded: speed=1.5 reaches the OpenAI speech.create call.
 *   4. Voice fallback updated: invalid voice falls back to "marin".
 *   5. Model ownership: the worker calls gpt-4o-mini-tts even when a legacy
 *      client includes a different model value.
 */

// ─── Capture the args passed to openai.audio.speech.create ──────────────────
const { speechCalls, speechAudioBytes } = vi.hoisted(() => ({
  speechCalls: [] as Array<Record<string, unknown>>,
  speechAudioBytes: new Uint8Array([1, 2, 3, 4]),
}))

vi.mock("openai", () => {
  class MockOpenAI {
    audio = {
      speech: {
        create: vi.fn(async (args: Record<string, unknown>) => {
          speechCalls.push(args)
          return {
            arrayBuffer: async () =>
              speechAudioBytes.buffer.slice(
                speechAudioBytes.byteOffset,
                speechAudioBytes.byteOffset + speechAudioBytes.byteLength,
              ),
          }
        }),
      },
    }

    constructor(_config?: unknown) {}
  }

  return {
    default: MockOpenAI,
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

// ─── Stub auth middleware so these endpoint tests can focus on speech logic ─
vi.mock("./middleware", () => ({
  requireAuth: async (_c: unknown, next: () => Promise<void>) => {
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

async function callSpeechOptions() {
  const req = new Request("https://api.fidexa.org/api/audio/speech/options", {
    method: "GET",
  })
  return app.fetch(req, env, ctx)
}

function parseEventFrames(text: string) {
  return text
    .trim()
    .split(/\n\n/)
    .filter(Boolean)
    .map((frameText) => {
      const frame: { id?: string; event?: string; data?: string } = {}
      for (const line of frameText.split("\n")) {
        const separator = line.indexOf(": ")
        if (separator === -1) continue
        const key = line.slice(0, separator)
        const value = line.slice(separator + 2)
        if (key === "id" || key === "event" || key === "data") {
          frame[key] = value
        }
      }
      return frame
    })
}

async function computeKey(
  text: string,
  voice: string,
  speed: number,
): Promise<string> {
  const canonical = `gpt-4o-mini-tts|${voice}|${speed.toFixed(2)}|${text}`
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  )
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
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

  it("speed is forwarded into speech.create args", async () => {
    const res = await callSpeech({ text: "hi", voice: "alloy", speed: 1.5 })
    expect(res.status).toBe(200)
    expect(speechCalls.length).toBe(1)
    expect(speechCalls[0]).toMatchObject({ speed: 1.5 })
    expect(speechCalls[0]).toMatchObject({
      model: "gpt-4o-mini-tts",
    })
  })

  it("ignores a client-supplied model because the worker owns the model", async () => {
    const res = await callSpeech({
      text: "hi",
      voice: "alloy",
      model: "eleven_v3",
      speed: 1.0,
    })
    expect(res.status).toBe(200)
    expect(speechCalls).toHaveLength(1)
    expect(speechCalls[0]).toMatchObject({ model: "gpt-4o-mini-tts" })
  })

  it("invalid voice falls back to 'marin' (preferred default voice)", async () => {
    const res = await callSpeech({ text: "hi", voice: "invalid-voice", speed: 1.0 })
    expect(res.status).toBe(200)
    expect(speechCalls.length).toBe(1)
    expect(speechCalls[0]).toMatchObject({ voice: "marin" })
  })

  it("response_mode=events streams chunk and done SSE frames with stable ids", async () => {
    const text = "hello world"
    const res = await callSpeech({
      text,
      voice: "alloy",
      speed: 1.0,
      response_mode: "events",
    })

    expect(res.status).toBe(200)
    expect((res.headers.get("Content-Type") ?? "").toLowerCase()).toContain(
      "text/event-stream",
    )
    expect(res.headers.get("X-TTS-Cache")).toBe("miss")

    const frames = parseEventFrames(await res.text())
    expect(frames.map((frame) => frame.event)).toEqual(["chunk", "done"])

    const requestId = await computeKey(text, "alloy", 1.0)
    const chunkFrame = frames[0]
    const doneFrame = frames[1]

    expect(chunkFrame.id).toBe(`${requestId}#00000000`)
    expect(JSON.parse(chunkFrame.data!)).toMatchObject({
      request_id: requestId,
      chunk_id: `${requestId}#00000000`,
      index: 0,
      audio_b64: "AQIDBA==",
    })

    expect(doneFrame.id).toBe(`${requestId}#done`)
    expect(JSON.parse(doneFrame.data!)).toMatchObject({
      request_id: requestId,
      done: true,
      cache: "miss",
      chunk_count: 1,
      byte_length: 4,
    })

    expect(speechCalls.length).toBe(1)
  })
})

describe("GET /api/audio/speech/options", () => {
  it("returns the worker-driven OpenAI voice/model catalog", async () => {
    const res = await callSpeechOptions()
    expect(res.status).toBe(200)

    const body = (await res.json()) as {
      provider: string
      voices: Array<{ id: string; name: string }>
      models: Array<{ id: string; name: string }>
      default_voice_id: string
      default_model_id: string
    }

    expect(body.provider).toBe("openai")
    expect(body.default_voice_id).toBe("marin")
    expect(body.default_model_id).toBe("gpt-4o-mini-tts")
    expect(body.voices.map((choice) => choice.id)).toContain("alloy")
    expect(body.models).toEqual([
      { id: "gpt-4o-mini-tts", name: "GPT-4o mini TTS" },
    ])
  })
})
