import { describe, it, expect, beforeEach, vi } from "vitest"

/**
 * ElevenLabs-backed speech route tests for POST /api/audio/speech/elevenlabs.
 *
 * Coverage:
 *   - cache miss calls ElevenLabs, meters, writes R2, and returns X-TTS-Cache: miss
 *   - cache hit skips ElevenLabs and metering
 *   - cache key remains model/voice-sensitive and uses the ElevenLabs namespace
 *   - legacy voice presets are translated to ElevenLabs voice IDs before fetch
 */

const { speechAudioBytes, fetchCalls, meterMock } = vi.hoisted(() => ({
  speechAudioBytes: new Uint8Array([5, 6, 7, 8]),
  fetchCalls: [] as Array<{ url: string; init?: RequestInit }>,
  meterMock: vi.fn(async () => undefined),
}))

const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
  fetchCalls.push({ url: String(input), init })
  return new Response(speechAudioBytes, {
    status: 200,
    headers: { "Content-Type": "audio/mpeg" },
  })
})

vi.stubGlobal("fetch", fetchMock)

vi.mock("@sentry/cloudflare", () => ({
  withSentry: <T>(_options: unknown, handler: T) => handler,
}))

vi.mock("./billing/meter", () => ({
  meterFromContext: meterMock,
}))
vi.mock("./usage/api-usage", () => ({
  incrementApiUsage: vi.fn(async () => undefined),
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
  requireAuthForDeletion: async (_c: unknown, next: () => Promise<void>) => {
    await next()
  },
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

vi.mock("./routes/sync", async () => {
  const { Hono } = await import("hono")
  return { syncRoutes: new Hono() }
})
vi.mock("./durable-objects/user-usage-ledger/ledger", () => ({
  UserUsageLedger: class UserUsageLedger {},
}))
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

vi.mock("openai", () => {
  class MockOpenAI {
    audio = {
      speech: {
        create: vi.fn(async () => ({
          arrayBuffer: async () => new Uint8Array([1]).buffer,
        })),
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

import { app } from "./index"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  OPENAI_API_KEY: "test-openai-key",
  ELEVEN_LABS_API_KEY: "test-elevenlabs-key",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  TTS_CACHE: {
    get: vi.fn<(key: string) => Promise<unknown>>(),
    put: vi.fn<(key: string, value: unknown, options?: unknown) => Promise<unknown>>(),
  } as unknown as R2Bucket,
  USER_USAGE_LEDGER: {
    getByName: () => ({
      reserveTts: async () => ({ reservationId: "reservation_test" }),
      commitTtsReservation: async () => undefined,
      releaseTtsReservation: async () => undefined,
      getEntitlementSnapshot: async () => ({}),
    }),
  },
} as unknown as Record<string, unknown>

const ctx = {
  waitUntil: (_p: Promise<unknown>) => undefined,
  passThroughOnException: () => undefined,
} as unknown as ExecutionContext

async function callSpeech(body: unknown) {
  const req = new Request("https://api.fidexa.org/api/audio/speech/elevenlabs", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Rishi-Data-Use-Consent": "2026-07-29",
    },
    body: JSON.stringify(body),
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

async function computeKey(text: string, voice: string, model: string, speed: number): Promise<string> {
  const canonical = `elevenlabs-tts|${model}|${voice}|${speed.toFixed(2)}|${text}`
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  )
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")
}

beforeEach(() => {
  fetchCalls.length = 0
  meterMock.mockReset().mockResolvedValue(undefined)
  setUser("user_alice")
  const cache = env.TTS_CACHE as unknown as {
    get: ReturnType<typeof vi.fn>
    put: ReturnType<typeof vi.fn>
  }
  cache.get.mockReset()
  cache.put.mockReset().mockResolvedValue({})
  fetchMock.mockClear()
})

describe("POST /api/audio/speech/elevenlabs", () => {
  it("missing consent rejects before parsing, cache lookup, metering, or provider work", async () => {
    const res = await app.fetch(
      new Request("https://api.fidexa.org/api/audio/speech/elevenlabs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not-json",
      }),
      env,
      ctx,
    )
    expect(res.status).toBe(428)
    expect(await res.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" })
    expect(fetchCalls).toHaveLength(0)
    expect(meterMock).not.toHaveBeenCalled()
  })

  it("unsupported consent rejects before parsing, cache lookup, metering, or provider work", async () => {
    const res = await app.fetch(
      new Request("https://api.fidexa.org/api/audio/speech/elevenlabs", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Rishi-Data-Use-Consent": "2026-01-01",
        },
        body: "not-json",
      }),
      env,
      ctx,
    )
    expect(res.status).toBe(428)
    expect(await res.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" })
    expect(fetchCalls).toHaveLength(0)
    expect(meterMock).not.toHaveBeenCalled()
  })

  it("cache miss calls ElevenLabs, meters, writes to R2, and returns audio", async () => {
    const cache = env.TTS_CACHE as unknown as {
      get: ReturnType<typeof vi.fn>
      put: ReturnType<typeof vi.fn>
    }
    cache.get.mockResolvedValue(null)

    const res = await callSpeech({
      text: "hello world",
      voice: "alloy",
      model: "eleven_v3",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    expect(res.headers.get("Content-Type")).toBe("audio/mpeg")
    expect(res.headers.get("X-TTS-Cache")).toBe("miss")

    expect(fetchCalls.length).toBe(1)
    expect(fetchCalls[0]?.url).toContain(
      "https://api.elevenlabs.io/v1/text-to-speech/JBFqnCBsd6RMkjVDRZzb",
    )

    const parsedBody = JSON.parse(
      String(fetchCalls[0]?.init?.body ?? "{}"),
    ) as {
      text?: string
      model_id?: string
      voice_settings?: { speed?: number }
    }
    expect(parsedBody).toMatchObject({
      text: "hello world",
      model_id: "eleven_v3",
      voice_settings: { speed: 1.0 },
    })

    expect(meterMock).toHaveBeenCalledTimes(1)
    const meterCall = meterMock.mock.calls[0] as unknown as [
      unknown,
      unknown,
      { model?: string },
    ]
    expect(meterCall[2]).toMatchObject({
      model: "eleven_v3",
    })

    expect(cache.put).toHaveBeenCalledTimes(1)
    const [putKey, putValue] = cache.put.mock.calls[0] as [
      string,
      Uint8Array,
      ...unknown[]
    ]
    expect(putKey).toBe(await computeKey("hello world", "JBFqnCBsd6RMkjVDRZzb", "eleven_v3", 1.0))
    expect(putValue).toBeInstanceOf(Uint8Array)
    expect(Array.from(putValue)).toEqual([5, 6, 7, 8])
  })

  it("cache hit skips ElevenLabs and metering", async () => {
    const cache = env.TTS_CACHE as unknown as {
      get: ReturnType<typeof vi.fn>
      put: ReturnType<typeof vi.fn>
    }
    const cachedBytes = new Uint8Array([9, 9, 9, 9])
    cache.get.mockResolvedValue({
      bytes: async () => cachedBytes,
    })

    const res = await callSpeech({
      text: "hello world",
      voice: "alloy",
      model: "eleven_v3",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    expect(res.headers.get("X-TTS-Cache")).toBe("hit")

    const bodyBytes = new Uint8Array(await res.arrayBuffer())
    expect(Array.from(bodyBytes)).toEqual([9, 9, 9, 9])

    expect(fetchCalls.length).toBe(0)
    expect(meterMock).not.toHaveBeenCalled()
    expect(cache.put).not.toHaveBeenCalled()
  })

  it("unsupported legacy preset falls back to the default ElevenLabs voice", async () => {
    const cache = env.TTS_CACHE as unknown as {
      get: ReturnType<typeof vi.fn>
      put: ReturnType<typeof vi.fn>
    }
    cache.get.mockResolvedValue(null)

    const res = await callSpeech({
      text: "hello world",
      voice: "invalid-voice",
      model: "eleven_v3",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    expect(fetchCalls.length).toBe(1)
    expect(fetchCalls[0]?.url).toContain(
      "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM",
    )
  })

  it("unsupported model falls back to Eleven V3", async () => {
    const cache = env.TTS_CACHE as unknown as {
      get: ReturnType<typeof vi.fn>
      put: ReturnType<typeof vi.fn>
    }
    cache.get.mockResolvedValue(null)

    const res = await callSpeech({
      text: "hello world",
      voice: "alloy",
      model: "not-a-real-model",
      speed: 1.0,
    })

    expect(res.status).toBe(200)
    const parsedBody = JSON.parse(String(fetchCalls[0]?.init?.body ?? "{}")) as {
      model_id?: string
    }
    expect(parsedBody.model_id).toBe("eleven_v3")
  })

  it("response_mode=events streams chunk and done SSE frames with stable ids", async () => {
    const cache = env.TTS_CACHE as unknown as {
      get: ReturnType<typeof vi.fn>
      put: ReturnType<typeof vi.fn>
    }
    cache.get.mockResolvedValue(null)

    const text = "hello world"
    const res = await callSpeech({
      text,
      voice: "alloy",
      model: "eleven_v3",
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

    const requestId = await computeKey(
      text,
      "JBFqnCBsd6RMkjVDRZzb",
      "eleven_v3",
      1.0,
    )
    expect(frames[0].id).toBe(`${requestId}#00000000`)
    expect(JSON.parse(frames[0].data!)).toMatchObject({
      request_id: requestId,
      chunk_id: `${requestId}#00000000`,
      index: 0,
      audio_b64: "BQYHCA==",
    })
    expect(frames[1].id).toBe(`${requestId}#done`)
    expect(JSON.parse(frames[1].data!)).toMatchObject({
      request_id: requestId,
      done: true,
      cache: "miss",
      chunk_count: 1,
      byte_length: 4,
    })

    expect(fetchCalls.length).toBe(1)
    expect(meterMock).toHaveBeenCalledTimes(1)
  })
})
