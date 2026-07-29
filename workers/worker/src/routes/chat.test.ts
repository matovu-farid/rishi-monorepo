// RED tests — handler not yet implemented. See plan 260612-f7p Task 2 for GREEN.
//
// Tests for POST /api/chat — quick task 260612-f7p.
//
// The iOS ChatStreamEndpoint (apps/apple/Packages/RishiChat/.../ChatStreamEndpoint.swift)
// POSTs to this endpoint with a ChatRequest body and expects a text/event-stream
// response whose frame bodies decode as ChatResponseChunk ({ delta?, tool_call?, done? }).
//
// Six cases mapped 1:1 to plan must_haves truths:
//   1. Unauthenticated -> 401 { error: "Unauthorized" }
//   2. Authenticated but no active subscription -> 402, body.code === "BILLING_INACTIVE"
//   3. Empty query -> 400 with "query" in detail
//   4. Query > 50000 chars -> 400 with "50000" or "query" in detail
//   5. Invalid (non-uuid) book_id -> 400 with "book_id" or "uuid" in detail
//   6. Happy path: valid auth + body -> 200, text/event-stream, SSE frames matching
//      iOS ChatResponseChunk shape (snake_case delta + done keys), streamText called
//      with model "gpt-5-nano" and a system message mentioning the book_id.
//
// Mock strategy mirrors src/routes/devices.test.ts:
//   - vi.hoisted authState + subState so the requireAuth / requireActiveSubscription
//     stubs can flip per-test.
//   - vi.mock("../index") -> stub requireAuth.
//   - vi.mock("../billing/sub-gate") -> stub requireActiveSubscription that emits
//     the 402 envelope ({ error, code: "BILLING_INACTIVE", subscriptionStatus }).
//   - vi.mock("ai") -> streamText fake that captures call args + returns a fake
//     textStream yielding two deltas. No network.
//   - vi.mock("@ai-sdk/openai") -> createOpenAI returns { responses: (m) => ({ modelId: m }) }.
//   - vi.mock("../billing/meter") -> meterFromContext as a no-op spy.
//   - vi.mock("../auth") -> createAuth getSession stub (defensive; route should not
//     hit this directly because requireAuth is mocked, but other transitive imports
//     may pull ../index).

import { describe, it, expect, beforeEach, vi } from "vitest"

// ─── Hoisted shared mutable state ────────────────────────────────────────────
const { authState, subState, streamTextSpy, meterSpy } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
  subState: {
    allowed: true,
    subscriptionStatus: "active" as string | null,
  },
  streamTextSpy: { lastArgs: null as unknown as Record<string, unknown> | null },
  meterSpy: { calls: [] as Array<unknown> },
}))

function setUser(id: string | null) {
  authState.userId = id
}

function setSubscription(allowed: boolean, status: string | null = "active") {
  subState.allowed = allowed
  subState.subscriptionStatus = status
}

// ─── Mock the `ai` SDK ───────────────────────────────────────────────────────
// streamText is captured; its return value exposes a `textStream` async iterable
// that yields a deterministic 2-token stream and an `onFinish` callback that the
// handler may pass in.
vi.mock("ai", () => {
  return {
    streamText: (args: Record<string, unknown>) => {
      streamTextSpy.lastArgs = args
      // Build an async iterable yielding two deltas.
      const tokens = ["Hello", " world"]
      const textStream = (async function* () {
        for (const t of tokens) {
          yield t
        }
        // Best-effort: fire onFinish once stream completes so the metering
        // assertion (when present) can fire. Some handlers attach onFinish
        // via streamText({ onFinish }); call it with a synthetic usage.
        const onFinish = args["onFinish"] as
          | ((arg: { usage: { inputTokens: number; outputTokens: number } }) => void)
          | undefined
        if (typeof onFinish === "function") {
          onFinish({ usage: { inputTokens: 5, outputTokens: 2 } })
        }
      })()
      return {
        textStream,
        // Provide minimal `fullStream` so handlers that opt for it still work.
        fullStream: textStream,
      }
    },
    APICallError: class APICallError extends Error {
      static isInstance(_e: unknown): _e is APICallError {
        return false
      }
    },
  }
})

// ─── Mock @ai-sdk/openai ─────────────────────────────────────────────────────
vi.mock("@ai-sdk/openai", () => ({
  createOpenAI: (_opts: { apiKey: string }) => ({
    responses: (m: string) => ({ modelId: m }),
  }),
}))

// ─── Mock billing meter ──────────────────────────────────────────────────────
vi.mock("../billing/meter", () => ({
  meterFromContext: async (..._args: unknown[]) => {
    meterSpy.calls.push(_args)
  },
}))

// ─── Mock ../auth defensively (some imports transitively pull createAuth) ────
vi.mock("../auth", () => ({
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
  }),
}))

// ─── Mock ../index to stub requireAuth ───────────────────────────────────────
// chat.ts imports requireAuth from "../index"; we replace it with a fake that
// reads authState and short-circuits to 401 when unauthenticated.
vi.mock("../index", async () => {
  return {
    requireAuth: async (
      c: { set: (k: string, v: unknown) => void; json: (b: unknown, s: number) => Response },
      next: () => Promise<void>,
    ) => {
      if (!authState.userId) {
        return c.json({ error: "Unauthorized" }, 401)
      }
      c.set("userId", authState.userId)
      return next()
    },
  }
})

// ─── Mock ../billing/sub-gate ────────────────────────────────────────────────
// chat.ts imports requireActiveSubscription from "../billing/sub-gate".
vi.mock("../billing/sub-gate", () => ({
  requireActiveSubscription: async (
    c: { json: (b: unknown, s: number) => Response },
    next: () => Promise<void>,
  ) => {
    if (!subState.allowed) {
      return c.json(
        {
          error: "Active subscription required to use this feature",
          code: "BILLING_INACTIVE",
          subscriptionStatus: subState.subscriptionStatus,
        },
        402,
      )
    }
    return next()
  },
}))

// ─── Now import the route under test ─────────────────────────────────────────
// This import is what makes the file RED before chat.ts exists: vitest reports
// "Cannot find module './chat'".
import { chatRoutes } from "./chat"

const env = {
  BETTER_AUTH_SECRET: "test-secret",
  OPENAI_API_KEY: "sk-test",
  PUBLIC_API_URL: "https://api.fidexa.org",
  PUBLIC_WEB_URL: "https://rishi.fidexa.org",
  DB: {} as unknown,
} as unknown as Record<string, unknown>

const consentHeaders = { "X-Rishi-Data-Use-Consent": "2026-07-29" }

async function callChat(body: unknown) {
  const req = new Request("http://test.local/", {
    method: "POST",
    headers: { "Content-Type": "application/json", ...consentHeaders },
    body: JSON.stringify(body),
  })
  return chatRoutes.fetch(req, env, {
    waitUntil: (_p: Promise<unknown>) => {
      /* no-op for tests */
    },
    passThroughOnException: () => {
      /* no-op */
    },
  } as unknown as ExecutionContext)
}

beforeEach(() => {
  setUser("user_alice")
  setSubscription(true, "active")
  streamTextSpy.lastArgs = null
  meterSpy.calls.length = 0
})

// ─── Tests ───────────────────────────────────────────────────────────────────

describe("POST /api/chat", () => {
  it("rejects missing consent before parsing the request or calling the provider", async () => {
    const req = new Request("http://test.local/", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not-json",
    })
    const res = await chatRoutes.fetch(req, env, {
      waitUntil: (_p: Promise<unknown>) => {},
      passThroughOnException: () => {},
    } as unknown as ExecutionContext)

    expect(res.status).toBe(428)
    expect(streamTextSpy.lastArgs).toBeNull()
    expect(await res.json()).toEqual({ error: "AI_DATA_CONSENT_REQUIRED" })
  })

  it("unauthenticated: no session -> 401 { error: 'Unauthorized' }", async () => {
    setUser(null)
    const res = await callChat({
      book_id: "11111111-2222-3333-4444-555555555555",
      query: "hi",
    })
    expect(res.status).toBe(401)
    const body = (await res.json()) as { error: string }
    expect(body.error).toBe("Unauthorized")
  })

  it("no active subscription -> 402 with code BILLING_INACTIVE", async () => {
    setSubscription(false, "past_due")
    const res = await callChat({
      book_id: "11111111-2222-3333-4444-555555555555",
      query: "hi",
    })
    expect(res.status).toBe(402)
    const body = (await res.json()) as {
      error: string
      code: string
      subscriptionStatus: string | null
    }
    expect(body.code).toBe("BILLING_INACTIVE")
    expect(body.subscriptionStatus).toBe("past_due")
  })

  it("empty query -> 400 with 'query' in error detail", async () => {
    const res = await callChat({ query: "" })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string; detail?: string }
    expect(body.error).toBe("bad_request")
    const haystack = (body.detail ?? "") + JSON.stringify(body)
    expect(haystack.toLowerCase()).toMatch(/query/)
  })

  it("query > 50000 chars -> 400 with '50000' or 'query' in error detail", async () => {
    const res = await callChat({ query: "a".repeat(50001) })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string; detail?: string }
    expect(body.error).toBe("bad_request")
    const haystack = ((body.detail ?? "") + JSON.stringify(body)).toLowerCase()
    expect(haystack).toMatch(/50000|query/)
  })

  it("invalid book_id (not a uuid) -> 400 with 'book_id' or 'uuid' in error detail", async () => {
    const res = await callChat({ book_id: "not-a-uuid", query: "hi" })
    expect(res.status).toBe(400)
    const body = (await res.json()) as { error: string; detail?: string }
    expect(body.error).toBe("bad_request")
    const haystack = ((body.detail ?? "") + JSON.stringify(body)).toLowerCase()
    expect(haystack).toMatch(/book_id|uuid/)
  })

  it("happy path: streams SSE frames matching iOS ChatResponseChunk shape", async () => {
    const bookId = "11111111-2222-3333-4444-555555555555"
    const res = await callChat({ book_id: bookId, query: "hi" })

    expect(res.status).toBe(200)
    const ct = res.headers.get("content-type") ?? ""
    expect(ct.toLowerCase().startsWith("text/event-stream")).toBe(true)
    const cc = res.headers.get("cache-control") ?? ""
    expect(cc.toLowerCase()).toContain("no-cache")

    // Read the entire SSE body as text.
    const text = await res.text()

    // At least one delta frame and one done frame, each \n\n terminated.
    expect(text).toMatch(/data: \{"delta":/)
    expect(text).toMatch(/data: \{"done":true\}\n\n/)

    // Extract first data: { ... } frame and confirm it parses to { delta: string }.
    const firstDataMatch = text.match(/data: (\{[^\n]*\})\n\n/)
    expect(firstDataMatch).not.toBeNull()
    const firstObj = JSON.parse(firstDataMatch![1]) as { delta?: string }
    expect(typeof firstObj.delta).toBe("string")
    expect(firstObj.delta!.length).toBeGreaterThan(0)

    // streamText must have been invoked with the gpt-5-nano model and a system
    // message hint that mentions the book_id.
    expect(streamTextSpy.lastArgs).not.toBeNull()
    const args = streamTextSpy.lastArgs!
    const model = args["model"] as { modelId?: string } | undefined
    expect(model?.modelId).toBe("gpt-5-nano")

    const messages = args["messages"] as Array<{ role: string; content: string }> | undefined
    expect(Array.isArray(messages)).toBe(true)
    const sys = messages!.find((m) => m.role === "system")
    expect(sys).toBeDefined()
    expect(sys!.content).toMatch(new RegExp(`book.*${bookId}`, "i"))
  })
})
