import { beforeEach, describe, expect, it, vi } from "vitest"

const { authState, generateTextSpy } = vi.hoisted(() => ({
  authState: { userId: "user_alice" as string | null },
  generateTextSpy: { lastArgs: null as Record<string, unknown> | null },
}))

vi.mock("../index", () => ({
  requireAuth: async (
    c: { set: (key: string, value: unknown) => void; json: (body: unknown, status: number) => Response },
    next: () => Promise<void>,
  ) => {
    if (!authState.userId) return c.json({ error: "Unauthorized" }, 401)
    c.set("userId", authState.userId)
    return next()
  },
}))

vi.mock("ai", () => ({
  generateText: async (args: Record<string, unknown>) => {
    generateTextSpy.lastArgs = args
    return {
      output: { id: "model-id", name: "Model name", summary: "A concise summary." },
      usage: { inputTokens: 12, outputTokens: 8 },
    }
  },
  Output: { object: (args: unknown) => args },
}))

vi.mock("@ai-sdk/openai", () => ({
  createOpenAI: () => ({ responses: (modelId: string) => ({ modelId }) }),
}))

import { chapterSummariesRoutes } from "./chapter-summaries"

const env = { OPENAI_API_KEY: "sk-test" } as unknown as Env
const consent = { "X-Rishi-Data-Use-Consent": "2026-07-29" }
const validBody = {
  operation: "summarize",
  bookID: "11111111-2222-3333-4444-555555555555",
  contentVersion: "content-v1",
  chapterID: "chapter-1",
  chapterName: "The Beginning",
  input: "The chapter begins with a journey.",
  prompt: "Summarize this chapter.",
  store: false,
}

async function call(body: unknown, headers: Record<string, string> = consent) {
  return chapterSummariesRoutes.fetch(
    new Request("http://test.local/", {
      method: "POST",
      headers: { "Content-Type": "application/json", ...headers },
      body: JSON.stringify(body),
    }),
    env,
    { waitUntil: () => {}, passThroughOnException: () => {} } as unknown as ExecutionContext,
  )
}

beforeEach(() => {
  authState.userId = "user_alice"
  generateTextSpy.lastArgs = null
})

describe("POST /api/ai/chapter-summaries", () => {
  it("requires authentication and consent before generation", async () => {
    authState.userId = null
    expect((await call(validBody)).status).toBe(401)

    authState.userId = "user_alice"
    expect((await call(validBody, {})).status).toBe(428)
    expect(generateTextSpy.lastArgs).toBeNull()
  })

  it("rejects invalid identity, metadata, and bounded content", async () => {
    const cases = [
      { ...validBody, bookID: "not-a-uuid" },
      { ...validBody, contentVersion: "x".repeat(257) },
      { ...validBody, chapterID: "" },
      { ...validBody, chapterName: "x".repeat(257) },
      { ...validBody, input: "x".repeat(12001) },
      { ...validBody, operation: "unknown" },
      { ...validBody, sectionSummaries: [] },
    ]

    for (const body of cases) {
      expect((await call(body)).status).toBe(400)
    }
    expect(generateTextSpy.lastArgs).toBeNull()
  })

  it("generates a deterministic structured summary without storing user content", async () => {
    const response = await call(validBody)

    expect(response.status).toBe(200)
    expect(await response.json()).toEqual({
      id: "chapter-1",
      name: "The Beginning",
      summary: "A concise summary.",
    })
    expect(generateTextSpy.lastArgs).toMatchObject({
      model: { modelId: "gpt-5-nano" },
      providerOptions: { openai: { store: false } },
    })
    expect(generateTextSpy.lastArgs?.output).toEqual({
      schema: expect.anything(),
    })
    expect(String(generateTextSpy.lastArgs?.prompt)).toContain("chapter-1")
    expect(String(generateTextSpy.lastArgs?.prompt)).toContain("The Beginning")
  })

  it("supports merge requests with bounded section summaries", async () => {
    const response = await call({
      ...validBody,
      operation: "merge",
      input: undefined,
      sectionSummaries: ["First section.", "Second section."],
    })

    expect(response.status).toBe(200)
    expect(String(generateTextSpy.lastArgs?.prompt)).toContain("First section.")
    expect(String(generateTextSpy.lastArgs?.prompt)).toContain("Second section.")
  })
})
