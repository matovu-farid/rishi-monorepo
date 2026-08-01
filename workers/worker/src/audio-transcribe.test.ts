import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"

/**
 * Tests for POST /api/audio/transcribe — Phase 17-04 (Gap 7).
 *
 * iOS TranscribeEndpoint.Body (apps/apple/Packages/RishiAPI/Sources/RishiAPI/
 * Endpoints/AudioAPI.swift:46-58) is `{audio: Data, mime_type: String}`. The
 * default JSONEncoder() encodes Data as a base64 string. The previous worker
 * handler read `await c.req.arrayBuffer()` and treated the body as raw audio
 * bytes — the two shapes are fundamentally incompatible, so iOS payloads
 * were forwarded to Deepgram as JSON bytes and Deepgram returned 4xx.
 *
 * Contract under test (v1):
 *   1. Happy path — POST JSON {audio: <base64>, mime_type: "audio/webm"} with
 *      auth -> 200 {transcript}; Deepgram is called with
 *      Content-Type === "audio/webm" and a body whose byteLength matches the
 *      decoded base64 length (NOT the JSON byte length).
 *   2. Missing audio -> 400 fast, Deepgram NOT called.
 *   3. Malformed base64 -> 400 fast, Deepgram NOT called.
 *
 * Strategy:
 *   - Mock ../auth so the requireAuth middleware short-circuits on a fake
 *     session (no Better Auth / drizzle / D1).
 *   - Mock ../billing/sub-gate so requireActiveSubscription is a no-op even
 *     if the handler ever gains a billing gate.
 *   - Mock ../db/drizzle to a no-op createDb (transitively pulled by index).
 *   - vi.stubGlobal("fetch", ...) to capture the Deepgram request and return
 *     a canned response shaped like Deepgram's actual API.
 */

// ─── Hoisted shared state ────────────────────────────────────────────────────
const { authState } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
}))

function setUser(id: string | null) {
  authState.userId = id
}

// ─── Mock ../auth so createAuth.getSession returns a fake session ────────────
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
  }),
}))

vi.mock("./middleware", () => ({
  requireAuthForDeletion: async (_c: unknown, next: () => Promise<void>) => {
    await next()
  },
  requireAuth: async (_c: unknown, next: () => Promise<void>) => {
    await next()
  },
}))

// ─── Stub heavy transitive imports so importing ./index does not crash ──────
vi.mock("./db/drizzle", () => ({
  createDb: () => ({}),
}))

vi.mock("./billing/sub-gate", () => ({
  requireActiveSubscription: async (
    _c: unknown,
    next: () => Promise<void>,
  ) => {
    await next()
  },
  isAllowedForBilledFeature: () => true,
}))

vi.mock("./billing/backfill", () => ({
  ensureCreditAndSubscription: async () => undefined,
}))

vi.mock("./billing/meter", () => ({
  meterFromContext: async () => undefined,
}))

vi.mock("./billing/portal", () => ({
  createPortalSession: async () => ({ url: "" }),
}))

vi.mock("./billing/start", () => ({
  ensureCustomerAndPortal: async () => ({ url: "" }),
}))

vi.mock("./billing/realtime-usage", () => ({
  parseRealtimeUsageBody: () => null,
}))

vi.mock("./billing/stripe", () => ({
  createStripeClient: () => ({}),
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

vi.mock("./durable-objects/user-usage-ledger/ledger", () => ({
  UserUsageLedger: class UserUsageLedger {},
}))

vi.mock("./routes/test-auth", async () => {
  const { Hono } = await import("hono")
  return { testAuthRoutes: new Hono() }
})

vi.mock("@upstash/redis/cloudflare", () => ({
  Redis: { fromEnv: () => ({ set: async () => undefined, get: async () => null }) },
}))

vi.mock("@sentry/cloudflare", () => ({
  withSentry: (_opts: unknown, app: unknown) => app,
}))

// ─── Now import the app ──────────────────────────────────────────────────────
import { app } from "./index"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  DEEPGRAM_KEY: "dg-test-key",
  OPENAI_API_KEY: "sk-test",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

// Base64 of the ASCII string "fakebytes" (9 bytes) — verified by hand:
//   f=66 a=61 k=6b e=65 b=62 y=79 t=74 e=65 s=73 -> "ZmFrZWJ5dGVz"
const FAKE_AUDIO_PLAINTEXT = "fakebytes"
const FAKE_AUDIO_BASE64 = "ZmFrZWJ5dGVz" // 9 bytes when decoded
const FAKE_AUDIO_DECODED_LEN = FAKE_AUDIO_PLAINTEXT.length // 9

interface CapturedFetch {
  url: string
  init: RequestInit
}

let captured: CapturedFetch[] = []

beforeEach(() => {
  setUser("user_alice")
  captured = []
  const fakeFetch = vi.fn(async (input: unknown, init?: RequestInit) => {
    const url =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : (input as Request).url
    captured.push({ url, init: init ?? {} })
    return new Response(
      JSON.stringify({
        results: {
          channels: [
            {
              alternatives: [{ transcript: "hello world" }],
            },
          ],
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    )
  })
  vi.stubGlobal("fetch", fakeFetch)
})

afterEach(() => {
  vi.unstubAllGlobals()
})

async function callTranscribe(body: unknown) {
  const req = new Request("http://test.local/api/audio/transcribe", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Rishi-Data-Use-Consent": "2026-07-29",
    },
    body: JSON.stringify(body),
  })
  return app.fetch(req, env, {
    waitUntil: (_p: Promise<unknown>) => {
      /* no-op for tests */
    },
    passThroughOnException: () => {
      /* no-op */
    },
  } as unknown as ExecutionContext)
}

describe("POST /api/audio/transcribe (iOS JSON+base64 contract)", () => {
  it("missing consent rejects before parsing or Deepgram work", async () => {
    const res = await app.fetch(
      new Request("http://test.local/api/audio/transcribe", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not-json",
      }),
      env,
      {} as ExecutionContext,
    )
    expect(res.status).toBe(428)
    expect(await res.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" })
    expect(captured).toHaveLength(0)
  })

  it("unsupported consent rejects before parsing or Deepgram work", async () => {
    const res = await app.fetch(
      new Request("http://test.local/api/audio/transcribe", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Rishi-Data-Use-Consent": "2026-01-01",
        },
        body: "not-json",
      }),
      env,
      {} as ExecutionContext,
    )
    expect(res.status).toBe(428)
    expect(await res.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" })
    expect(captured).toHaveLength(0)
  })

  it("happy path: JSON {audio: <base64>, mime_type} -> 200 {transcript}", async () => {
    const res = await callTranscribe({
      audio: FAKE_AUDIO_BASE64,
      mime_type: "audio/webm",
    })
    expect(res.status).toBe(200)
    const body = (await res.json()) as { transcript: string }
    expect(body.transcript).toBe("hello world")
  })

  it("forwards decoded bytes + mime_type as Content-Type to Deepgram", async () => {
    const res = await callTranscribe({
      audio: FAKE_AUDIO_BASE64,
      mime_type: "audio/webm",
    })
    expect(res.status).toBe(200)

    // Find the Deepgram call (it's the only fetch issued by the handler).
    const dg = captured.find((c) => c.url.includes("api.deepgram.com"))
    expect(dg, "expected Deepgram fetch to be issued").toBeDefined()

    const headers = (dg!.init.headers ?? {}) as Record<string, string>
    expect(headers["Content-Type"]).toBe("audio/webm")

    // Body MUST be the decoded bytes, NOT the JSON bytes. Decoded length is 9
    // ("fakebytes"); the JSON envelope is much longer.
    const body = dg!.init.body
    expect(body, "expected request body forwarded to Deepgram").toBeDefined()
    let byteLen = -1
    if (body instanceof ArrayBuffer) {
      byteLen = body.byteLength
    } else if (body instanceof Uint8Array) {
      byteLen = body.byteLength
    } else if (typeof body === "string") {
      // string body would mean the handler forwarded JSON — fail loudly.
      byteLen = new TextEncoder().encode(body).byteLength
    }
    expect(byteLen).toBe(FAKE_AUDIO_DECODED_LEN)
  })

  it("missing audio key -> 400, Deepgram NOT called", async () => {
    const res = await callTranscribe({ mime_type: "audio/webm" })
    expect(res.status).toBe(400)
    const dg = captured.find((c) => c.url.includes("api.deepgram.com"))
    expect(dg).toBeUndefined()
  })

  it("malformed base64 -> 400, Deepgram NOT called", async () => {
    // "***" contains characters illegal in base64 — handler MUST reject before
    // hitting Deepgram.
    const res = await callTranscribe({
      audio: "***not_base64***",
      mime_type: "audio/webm",
    })
    expect(res.status).toBe(400)
    const dg = captured.find((c) => c.url.includes("api.deepgram.com"))
    expect(dg).toBeUndefined()
  })
})
