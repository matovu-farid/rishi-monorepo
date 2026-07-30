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
import { REALTIME_VOICE_MODEL } from "@rishi/shared/realtime/model"

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

interface ClientSecretsRequestBody {
  language?: string
  bookId?: string
  currentPage?: number
  outline?: {
    title: string
    author?: string
    chapters: string[]
  }
}

async function callClientSecretsPOST(body?: ClientSecretsRequestBody) {
  const url = `http://test.local/api/realtime/client_secrets`
  const init: RequestInit =
    body === undefined
      ? { method: "POST" }
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(body),
        }
  const req = new Request(url, init)
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

async function callClientSecretsGET() {
  const url = `http://test.local/api/realtime/client_secrets`
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
    const body = buildRealtimeClientSecretsBody({ language: "en" })
    const transcription = body.session.audio?.input?.transcription
    expect(transcription, "transcription block must be present").toBeDefined()
    expect(transcription?.model, "transcription.model is required by OpenAI").toBeTruthy()
  })

  it("uses a transcription.model OpenAI's realtime API accepts", () => {
    const body = buildRealtimeClientSecretsBody({ language: "en" })
    expect(ALLOWED_TRANSCRIPTION_MODELS).toContain(body.session.audio.input.transcription.model)
  })

  it("propagates the language hint into transcription.language", () => {
    expect(
      buildRealtimeClientSecretsBody({ language: "fr" }).session.audio.input.transcription.language,
    ).toBe("fr")
    expect(
      buildRealtimeClientSecretsBody({ language: "ja" }).session.audio.input.transcription.language,
    ).toBe("ja")
  })

  it("uses session.type='realtime' and a known realtime model", () => {
    const body = buildRealtimeClientSecretsBody({ language: "en" })
    expect(body.session.type).toBe("realtime")
    expect(body.session.model).toBe(REALTIME_VOICE_MODEL)
  })

  it("includes the complete audio session config for WebRTC startup", () => {
    const body = buildRealtimeClientSecretsBody({ language: "en" })
    const audio = body.session.audio

    expect(body.session.tool_choice).toBe("auto")
    expect(audio.input.format).toEqual({ type: "audio/pcm", rate: 24000 })
    expect(audio.input.noise_reduction).toEqual({ type: "near_field" })
    expect(audio.input.turn_detection).toEqual({
      type: "server_vad",
      prefix_padding_ms: 300,
      silence_duration_ms: 700,
      threshold: 0.7,
    })
    expect(audio.output).toEqual({
      voice: "alloy",
      speed: 1,
      format: { type: "audio/pcm", rate: 24000 },
    })
  })

  it("requests expires_after anchored at created_at with a sensible TTL", () => {
    const body = buildRealtimeClientSecretsBody({ language: "en" })
    expect(body.expires_after.anchor).toBe("created_at")
    expect(body.expires_after.seconds).toBeGreaterThanOrEqual(10)
    expect(body.expires_after.seconds).toBeLessThanOrEqual(7200)
  })
})

/**
 * Handler-level tests for POST /api/realtime/client_secrets — Phase 25-06.
 *
 * Migration from GET to POST is atomic with iOS Plan 25-08. The worker now
 * accepts a JSON body carrying optional book-context fields and bakes a
 * book-aware system prompt + the bookContext tool spec into the upstream
 * OpenAI request.
 *
 * iOS contract (response shape) is UNCHANGED:
 *
 *   public struct ClientSecretResponse: Decodable, Sendable, Equatable {
 *     public let clientSecret: String   // "client_secret"
 *     public let sessionId: String      // "session_id"
 *   }
 */
describe("POST /api/realtime/client_secrets handler", () => {
  it("projects OpenAI {value,expires_at,id} into flat iOS {client_secret,session_id}", async () => {
    setOpenAISuccess({
      value: "sec_abc123",
      expires_at: 1700000000,
      id: "sess_xyz",
    })
    const res = await callClientSecretsPOST({ language: "en" })
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
    const res = await callClientSecretsPOST({ language: "en" })
    expect(res.status).toBe(200)
    const body = (await res.json()) as {
      client_secret: unknown
      session_id: unknown
    }
    expect(body.client_secret).toBe("sec_abc")
    expect(typeof body.session_id).toBe("string")
    expect((body.session_id as string).length).toBeGreaterThan(0)
    expect(body.session_id as string).toMatch(/^local_/)
  })

  it("returns 500 with the existing error envelope when OpenAI rejects", async () => {
    setOpenAIError({
      message: "Request failed with status code 401",
      response: { status: 401, data: { error: "invalid_api_key" } },
    })
    const res = await callClientSecretsPOST({ language: "en" })
    expect(res.status).toBe(500)
    const body = (await res.json()) as {
      error: string
      detail: { message: unknown; upstreamStatus: unknown; upstreamBody: unknown }
    }
    expect(body.error).toBe("Failed to get client secrets")
    expect(body.detail.upstreamStatus).toBe(401)
    expect(body.detail.upstreamBody).toEqual({ error: "invalid_api_key" })
  })

  it("forwards body language into the OpenAI request transcription block", async () => {
    setOpenAISuccess({
      value: "sec_abc",
      expires_at: 1700000000,
      id: "sess_lang",
    })
    const res = await callClientSecretsPOST({ language: "es" })
    expect(res.status).toBe(200)
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(capturedBody.session.audio.input.transcription.language).toBe("es")
  })

  // ─── New Phase 25-06 payload-shape gates ──────────────────────────────────

  it("bakes the bookContext tool spec into session.tools", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({ language: "en" })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(Array.isArray(capturedBody.session.tools)).toBe(true)
    expect(capturedBody.session.tools.length).toBeGreaterThanOrEqual(1)
    expect(capturedBody.session.tools[0].name).toBe("bookContext")
    expect(capturedBody.session.tools[0].type).toBe("function")
  })

  it("bakes the currentPageContext tool into session.tools", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({ language: "en" })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(capturedBody.session.tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "function",
          name: "currentPageContext",
        }),
      ]),
    )
  })

  it("bakes the chapterIndex tool into session.tools with automatic tool choice", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({ language: "en" })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(capturedBody.session.tool_choice).toBe("auto")
    expect(capturedBody.session.tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "function",
          name: "chapterIndex",
          parameters: {
            type: "object",
            properties: {
              startChapter: expect.objectContaining({
                type: "integer",
                minimum: 0,
                maximum: 100_000,
              }),
              maxChapters: expect.objectContaining({
                type: "integer",
                minimum: 1,
                maximum: 16,
              }),
            },
            required: [],
          },
        }),
      ]),
    )
  })

  it("pins the bookContext tool's required parameters to ['queryText']", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({ language: "en" })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(capturedBody.session.tools[0].parameters.required).toEqual(["queryText"])
  })

  it("renders metadata-only instructions when outline is provided", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({
      language: "en",
      outline: { title: "Moby Dick", chapters: ["Loomings"] },
    })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    const instructions = capturedBody.session.instructions
    expect(typeof instructions).toBe("string")
    expect(instructions).toContain("Moby Dick")
    expect(instructions).not.toContain("Current Page Content")
    expect(instructions).toContain("currentPageContext")
  })

  it("renders non-empty instructions when no book context provided (no undefined/null)", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    await callClientSecretsPOST({ language: "en" })
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    const instructions = capturedBody.session.instructions
    expect(typeof instructions).toBe("string")
    expect((instructions as string).length).toBeGreaterThan(0)
    expect(instructions).not.toContain("undefined")
    expect(instructions).not.toContain("null")
    // Old hardcoded prompt must be gone — replaced by renderRealtimeInstructions.
    expect(instructions).not.toBe("You are a friendly assistant.")
  })

  it("handles a POST with no body at all (defaults to language='en')", async () => {
    setOpenAISuccess({ value: "s", expires_at: 1, id: "sid" })
    const res = await callClientSecretsPOST(undefined)
    expect(res.status).toBe(200)
    const capturedBody = openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>
    expect(capturedBody.session.audio.input.transcription.language).toBe("en")
    expect(capturedBody.session.tools[0].name).toBe("bookContext")
    expect(capturedBody.session.tools[1].name).toBe("currentPageContext")
  })

  it("GET /api/realtime/client_secrets is not registered (returns 404)", async () => {
    // Hono returns 404 (not 405) for unmatched routes since the GET handler is
    // removed entirely in this migration. iOS Plan 25-08 ships POST atomically.
    const res = await callClientSecretsGET()
    expect(res.status).toBe(404)
  })
})
