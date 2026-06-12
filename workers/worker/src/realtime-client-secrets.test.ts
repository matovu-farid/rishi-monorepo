import { describe, it, expect, beforeEach, vi } from "vitest"

// ─── Hoisted shared mutable state (used by axios + auth + sub-gate mocks) ────
// Capturing the OpenAI request lets us assert the language query param flows
// through buildRealtimeClientSecretsBody into the upstream call (Test 4).
// `openaiNext` controls the next mocked OpenAI response (Tests 1/2/3).
const { authState, openaiNext, openaiCaptured } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
  openaiNext: {
    mode: "success" as "success" | "error",
    data: null as unknown,
    error: null as unknown,
  },
  openaiCaptured: {
    url: null as string | null,
    body: null as unknown,
  },
}))

function setUser(id: string | null) {
  authState.userId = id
}

function setOpenAISuccess(data: unknown) {
  openaiNext.mode = "success"
  openaiNext.data = data
  openaiNext.error = null
}

function setOpenAIError(error: unknown) {
  openaiNext.mode = "error"
  openaiNext.error = error
  openaiNext.data = null
}

// ─── Mock axios so no network call leaves the test ──────────────────────────
vi.mock("axios", () => ({
  default: {
    post: async (url: string, body: unknown) => {
      openaiCaptured.url = url
      openaiCaptured.body = body
      if (openaiNext.mode === "error") {
        throw openaiNext.error
      }
      return { data: openaiNext.data }
    },
  },
}))

// ─── Mock ../auth so requireAuth's createAuth() call resolves cleanly ───────
vi.mock("./auth", () => ({
  createAuth: () => ({
    api: {
      getSession: async () => {
        if (!authState.userId) return null
        return {
          user: { id: authState.userId },
          session: { token: "tok_test" },
        }
      },
    },
    handler: async () => new Response(null, { status: 404 }),
  }),
}))

// ─── Mock ../billing/sub-gate so /api/realtime/* doesn't hit D1 ─────────────
vi.mock("./billing/sub-gate", () => ({
  requireActiveSubscription: async (
    _c: unknown,
    next: () => Promise<void>,
  ) => next(),
}))

import { app, buildRealtimeClientSecretsBody } from "./index"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  OPENAI_API_KEY: "sk-test",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
  // Sentry's withSentry() wrapper destructures env.CF_VERSION_METADATA.id at
  // request time. Provide a stub so the wrapped fetch path doesn't throw.
  CF_VERSION_METADATA: { id: "test-version" },
  SENTRY_DSN: "",
} as unknown as Record<string, unknown>

async function callClientSecrets(query: string = "") {
  const url = `http://test.local/api/realtime/client_secrets${query}`
  const req = new Request(url, { method: "GET" })
  return app.fetch(
    req,
    env,
    {
      waitUntil: (_p: Promise<unknown>) => {
        /* no-op */
      },
      passThroughOnException: () => {
        /* no-op */
      },
    } as unknown as ExecutionContext,
  )
}

beforeEach(() => {
  setUser("user_alice")
  openaiCaptured.url = null
  openaiCaptured.body = null
  setOpenAISuccess(null)
})

/**
 * Regression test for the May 16 outage where this endpoint started returning
 * HTTP 500 (silently breaking voice chat). Root cause: the request payload
 * sent `session.audio.input.transcription: { language }` without a `model`
 * field. OpenAI rejected with:
 *
 *   400 missing_required_parameter
 *   "Missing required parameter: 'session.audio.input.transcription.model'."
 *
 * If `transcription` is present in the request, `transcription.model` MUST
 * also be present. Any future refactor that drops it should fail this test
 * loudly before reaching production.
 */
describe("buildRealtimeClientSecretsBody", () => {
  const ALLOWED_TRANSCRIPTION_MODELS = [
    "whisper-1",
    "gpt-4o-mini-transcribe",
    "gpt-4o-mini-transcribe-2025-12-15",
    "gpt-4o-transcribe",
    "gpt-4o-transcribe-diarize",
    "gpt-realtime-whisper",
  ] as const

  it("includes a non-empty transcription.model whenever transcription is set", () => {
    const body = buildRealtimeClientSecretsBody("en")
    const transcription = body.session.audio?.input?.transcription
    expect(transcription, "transcription block must be present").toBeDefined()
    expect(transcription?.model, "transcription.model is required by OpenAI").toBeTruthy()
  })

  it("uses a transcription.model OpenAI's realtime API accepts", () => {
    const body = buildRealtimeClientSecretsBody("en")
    expect(ALLOWED_TRANSCRIPTION_MODELS).toContain(body.session.audio.input.transcription.model)
  })

  it("propagates the language hint into transcription.language", () => {
    expect(buildRealtimeClientSecretsBody("fr").session.audio.input.transcription.language).toBe("fr")
    expect(buildRealtimeClientSecretsBody("ja").session.audio.input.transcription.language).toBe("ja")
  })

  it("uses session.type='realtime' and a known realtime model", () => {
    const body = buildRealtimeClientSecretsBody("en")
    expect(body.session.type).toBe("realtime")
    expect(body.session.model).toBe("gpt-realtime")
  })

  it("requests expires_after anchored at created_at with a sensible TTL", () => {
    const body = buildRealtimeClientSecretsBody("en")
    expect(body.expires_after.anchor).toBe("created_at")
    expect(body.expires_after.seconds).toBeGreaterThanOrEqual(10)
    expect(body.expires_after.seconds).toBeLessThanOrEqual(7200)
  })
})

/**
 * Handler-level tests for GET /api/realtime/client_secrets — Phase 17-05 (Gap 8).
 *
 * iOS RishiAPI/Endpoints/RealtimeAPI.swift defines:
 *
 *   public struct ClientSecretResponse: Decodable, Sendable, Equatable {
 *     public let clientSecret: String   // "client_secret"
 *     public let sessionId: String      // "session_id"
 *   }
 *
 * The worker previously returned `{client_secret: {value: <jwt>}}` which fails
 * to decode on iOS (clientSecret expects String, gets Object). This suite locks
 * the iOS-shape projection: flat `{client_secret: <string>, session_id: <string>}`.
 *
 * OpenAI's POST /v1/realtime/client_secrets returns a richer payload with a
 * top-level `id` (session id), `value` (JWT secret), and `expires_at`. The
 * worker reads `id` as `session_id`; if OpenAI omits it (defensive), the worker
 * synthesises a `local_<uuid>` for traceability.
 */
describe("GET /api/realtime/client_secrets handler", () => {
  it("projects OpenAI {value,expires_at,id} into flat iOS {client_secret,session_id}", async () => {
    setOpenAISuccess({
      value: "sec_abc123",
      expires_at: 1700000000,
      id: "sess_xyz",
    })
    const res = await callClientSecrets()
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      client_secret: unknown
      session_id: unknown
    }
    // iOS contract: client_secret is a STRING, not an object with .value.
    expect(typeof body.client_secret).toBe("string")
    expect(body.client_secret).toBe("sec_abc123")
    expect(typeof body.session_id).toBe("string")
    expect(body.session_id).toBe("sess_xyz")
  })

  it("falls back to a local_<uuid> session_id when OpenAI omits id", async () => {
    setOpenAISuccess({
      value: "sec_abc",
      expires_at: 1700000000,
      // no `id` field — defensive path
    })
    const res = await callClientSecrets()
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      client_secret: unknown
      session_id: unknown
    }
    expect(body.client_secret).toBe("sec_abc")
    expect(typeof body.session_id).toBe("string")
    expect((body.session_id as string).length).toBeGreaterThan(0)
    // Local fallback is prefixed with `local_` so logs can distinguish a
    // synthesised id from a real OpenAI session id.
    expect(body.session_id as string).toMatch(/^local_/)
  })

  it("returns 500 with the existing error envelope when OpenAI rejects", async () => {
    setOpenAIError({
      message: "Request failed with status code 401",
      response: { status: 401, data: { error: "invalid_api_key" } },
    })
    const res = await callClientSecrets()
    expect(res.status).toBe(500)
    const body = (await res.json()) as {
      error: string
      detail: { message: unknown; upstreamStatus: unknown; upstreamBody: unknown }
    }
    expect(body.error).toBe("Failed to get client secrets")
    expect(body.detail.upstreamStatus).toBe(401)
    expect(body.detail.upstreamBody).toEqual({ error: "invalid_api_key" })
  })

  it("forwards ?language=es into the OpenAI request body", async () => {
    setOpenAISuccess({
      value: "sec_abc",
      expires_at: 1700000000,
      id: "sess_lang",
    })
    const res = await callClientSecrets("?language=es")
    expect(res.status).toBe(200)
    // Regression: the language hint must reach OpenAI via
    // buildRealtimeClientSecretsBody — otherwise the realtime session won't
    // be locale-tuned for the user.
    const capturedBody = openaiCaptured.body as ReturnType<
      typeof buildRealtimeClientSecretsBody
    >
    expect(capturedBody.session.audio.input.transcription.language).toBe("es")
  })
})
