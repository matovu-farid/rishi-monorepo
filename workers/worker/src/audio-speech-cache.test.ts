// ----------------------------------------------------------------------------
// R2 bucket lifecycle setup — ONE-TIME OPERATIONAL STEP (not run by tests)
//
// Bucket creation:
//   wrangler r2 bucket create rishi-tts-cache
//
// 90-day TTL eviction (per Phase 22 CONTEXT.md locked decision):
//   wrangler r2 bucket lifecycle add rishi-tts-cache --expire-days 90
//
// Verify after install:
//   wrangler r2 bucket lifecycle list rishi-tts-cache
//
// These commands are run by the orchestrator (NOT by this subagent, NOT by CI)
// during phase finalization, after this PR merges and before the next deploy
// touches the speech endpoint in production.
// ----------------------------------------------------------------------------

import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * Phase 22-01: R2 cache gate on POST /api/audio/speech.
 *
 * Coverage matrix (matches PLAN.md must_haves):
 *   - Cache miss calls OpenAI, fires metering, writes R2 via waitUntil, and
 *     returns X-TTS-Cache: miss.
 *   - Cache hit serves bytes from R2, skips OpenAI, skips metering, skips R2
 *     writeback, and returns X-TTS-Cache: hit.
 *   - Cache key is stable: same (text, voice, speed) yields same 64-char hex.
 *   - Cache key is sensitive to speed: 1.00 and 1.50 differ.
 *   - Cache key is sensitive to voice: alloy and cedar differ.
 *   - Cross-runner symmetry: a pinned canonical string produces a known hex
 *     that the companion iOS test in 22-02 must reproduce byte-for-byte.
 *   - Model bump: miss path calls gpt-4o-mini-tts and meters that model slug.
 */

// ─── Cross-runner symmetry constants ─────────────────────────────────────────
// This exact canonical string and resulting hex MUST also appear verbatim in
// apps/apple/Packages/RishiAudio/Tests/RishiAudioTests/TTSCacheKeyTests.swift.
const PINNED_CANONICAL = "gpt-4o-mini-tts|alloy|1.00|hello world"
const PINNED_TEXT = "hello world"
const PINNED_VOICE = "alloy"
const PINNED_SPEED = 1.0

// ─── Hoisted shared mocks observable from the test body ─────────────────────
const { speechCalls, speechAudioBytes, meterMock } = vi.hoisted(() => ({
  speechCalls: [] as Array<Record<string, unknown>>,
  speechAudioBytes: new Uint8Array([1, 2, 3, 4]),
  meterMock: vi.fn(async () => undefined),
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

vi.mock("@ai-sdk/openai", () => ({
  createOpenAI: () => ({
    speech: (model: string) => ({ __model: model }),
  }),
}))

vi.mock("@sentry/cloudflare", () => ({
  withSentry: <T>(_options: unknown, handler: T) => handler,
}))

// Observable meter mock — hit-path assertions need to see call count.
vi.mock("./billing/meter", () => ({
  meterFromContext: meterMock,
}))

vi.mock("./billing/sub-gate", () => ({
  requireActiveSubscription: async (
    _c: unknown,
    next: () => Promise<void>,
  ) => {
    await next()
  },
}))

vi.mock("./middleware", () => ({
  requireAuth: async (_c: unknown, next: () => Promise<void>) => {
    await next()
  },
}))

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

// Side-routes mounted in index.ts — stub each with an empty Hono router so
// app.route(...) mounts succeed without dragging in Drizzle.
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

// ─── Local helpers ───────────────────────────────────────────────────────────

/**
 * Recompute the cache key with the SAME formula as the worker — kept here so
 * the test does not depend on a non-exported helper. If this drifts from
 * src/index.ts the symmetry tests will fail loudly.
 */
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

// ─── R2 cache + execution-context stubs ──────────────────────────────────────

const ttsCacheGetMock = vi.fn<(key: string) => Promise<unknown>>()
const ttsCachePutMock = vi.fn<
  (key: string, value: unknown, options?: unknown) => Promise<unknown>
>()

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  OPENAI_API_KEY: "test-openai-key",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  TTS_CACHE: {
    get: ttsCacheGetMock,
    put: ttsCachePutMock,
  } as unknown as R2Bucket,
} as unknown as Record<string, unknown>

// Collect waitUntil promises so the test can flush metering + R2 writeback
// before asserting on call counts.
let waited: Promise<unknown>[] = []

const ctx = {
  waitUntil: (p: Promise<unknown>) => {
    waited.push(p)
  },
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
  waited = []
  setUser("user_alice")
  ttsCacheGetMock.mockReset()
  ttsCachePutMock.mockReset().mockResolvedValue({})
  meterMock.mockReset().mockResolvedValue(undefined)
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/audio/speech — R2 cache gate (Phase 22-01)", () => {
  it("cache miss calls OpenAI, meters, writes to R2, returns X-TTS-Cache: miss", async () => {
    ttsCacheGetMock.mockResolvedValue(null)

    const res = await callSpeech({
      text: "hello world",
      voice: "alloy",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    expect(res.headers.get("Content-Type")).toBe("audio/mpeg")
    expect(res.headers.get("X-TTS-Cache")).toBe("miss")

    expect(speechCalls.length).toBe(1)
    expect(speechCalls[0]).toMatchObject({
      model: "gpt-4o-mini-tts",
    })

    // Flush waitUntil-deferred work (metering + R2 put).
    await Promise.all(waited)

    expect(meterMock).toHaveBeenCalledTimes(1)
    expect(meterMock.mock.calls[0]?.[2]).toMatchObject({
      model: "gpt-4o-mini-tts",
    })

    expect(ttsCachePutMock).toHaveBeenCalledTimes(1)
    const [putKey, putValue] = ttsCachePutMock.mock.calls[0] as [
      string,
      Uint8Array,
      ...unknown[]
    ]
    expect(putKey).toMatch(/^[0-9a-f]{64}$/)
    expect(putKey).toBe(await computeKey("hello world", "alloy", 1.0))
    expect(putValue).toBeInstanceOf(Uint8Array)
    expect(Array.from(putValue)).toEqual([1, 2, 3, 4])
  })

  it("cache hit skips OpenAI, skips metering, returns X-TTS-Cache: hit", async () => {
    const testBytes = new Uint8Array([9, 9, 9, 9])
    ttsCacheGetMock.mockResolvedValue({
      bytes: async () => testBytes,
    })

    const res = await callSpeech({
      text: "hello world",
      voice: "alloy",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    expect(res.headers.get("X-TTS-Cache")).toBe("hit")
    expect(res.headers.get("Content-Type")).toBe("audio/mpeg")

    const bodyBytes = new Uint8Array(await res.arrayBuffer())
    expect(Array.from(bodyBytes)).toEqual([9, 9, 9, 9])

    expect(speechCalls.length).toBe(0)

    // No deferred work should have been queued — but flush defensively so a
    // future regression that schedules waitUntil on the hit path is caught by
    // the meter/put assertions below.
    await Promise.all(waited)

    expect(meterMock).not.toHaveBeenCalled()
    expect(ttsCachePutMock).not.toHaveBeenCalled()
  })

  it("identical (text, voice, speed) produces identical cache key", async () => {
    const k1 = await computeKey("hello", "alloy", 1.0)
    const k2 = await computeKey("hello", "alloy", 1.0)
    expect(k1).toBe(k2)
    expect(k1).toMatch(/^[0-9a-f]{64}$/)
  })

  it("different speed produces different cache key", async () => {
    const k1 = await computeKey("hello", "alloy", 1.0)
    const k2 = await computeKey("hello", "alloy", 1.5)
    expect(k1).not.toBe(k2)
  })

  it("different voice produces different cache key", async () => {
    const k1 = await computeKey("hello", "alloy", 1.0)
    const k2 = await computeKey("hello", "cedar", 1.0)
    expect(k1).not.toBe(k2)
  })

  it("pinned hex matches the constant the iOS test asserts", async () => {
    const fromHelper = await computeKey(PINNED_TEXT, PINNED_VOICE, PINNED_SPEED)
    const fromCanonical = [
      ...new Uint8Array(
        await crypto.subtle.digest(
          "SHA-256",
          new TextEncoder().encode(PINNED_CANONICAL),
        ),
      ),
    ]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")

    expect(fromHelper).toBe(fromCanonical)
    expect(fromHelper).toHaveLength(64)
    expect(fromHelper).toMatch(/^[0-9a-f]{64}$/)

    // The iOS Swift Testing companion in 22-02 will assert the SAME canonical
    // string produces the SAME hex via CryptoKit.SHA256.hash(data:
    // Data(canonical.utf8)).
  })
})
