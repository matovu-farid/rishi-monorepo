import { beforeEach, describe, expect, it, vi } from "vitest"

const { openaiNext, openaiCaptured } = vi.hoisted(() => ({
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

import {
  buildRealtimeClientSecretsBody,
  MAX_REALTIME_OUTLINE_CHAPTERS,
  MAX_REALTIME_OUTLINE_TEXT_LENGTH,
  mintRealtimeClientSecret,
  normalizeRealtimeOutline,
} from "./realtime/client-secrets"
import { REALTIME_VOICE_MODEL } from "@rishi/shared/realtime/model"

beforeEach(() => {
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

  it("preserves a normal outline exactly", () => {
    expect(
      normalizeRealtimeOutline({
        title: "  Moby Dick  ",
        author: "  Herman Melville  ",
        chapters: ["  Loomings  ", "The Carpet-Bag"],
      }),
    ).toEqual({
      title: "  Moby Dick  ",
      author: "  Herman Melville  ",
      chapters: ["  Loomings  ", "The Carpet-Bag"],
    })
  })

  it("bounds oversized outline metadata before rendering the realtime prompt", () => {
    const longText = "x".repeat(MAX_REALTIME_OUTLINE_TEXT_LENGTH + 100)
    const oversizedOutline = {
      title: ` ${longText} `,
      author: longText,
      chapters: Array.from(
        { length: MAX_REALTIME_OUTLINE_CHAPTERS + 5 },
        (_, index) => ` chapter-${index}-${longText} `,
      ),
    }
    const normalized = normalizeRealtimeOutline(oversizedOutline)
    expect(normalized).toBeDefined()
    if (!normalized) throw new Error("outline normalization unexpectedly returned undefined")

    expect(normalized.title).toHaveLength(MAX_REALTIME_OUTLINE_TEXT_LENGTH)
    expect(normalized.author).toHaveLength(MAX_REALTIME_OUTLINE_TEXT_LENGTH)
    expect(normalized.chapters).toHaveLength(MAX_REALTIME_OUTLINE_CHAPTERS)
    expect(normalized.chapters.every((chapter) => chapter.length <= MAX_REALTIME_OUTLINE_TEXT_LENGTH)).toBe(true)

    const prompt = buildRealtimeClientSecretsBody({ language: "en", outline: oversizedOutline }).session.instructions
    expect(prompt).toContain(`- ${"chapter-0-"}${"x".repeat(MAX_REALTIME_OUTLINE_TEXT_LENGTH - "chapter-0-".length)}`)
    expect(prompt.match(/^- chapter-/gm)).toHaveLength(MAX_REALTIME_OUTLINE_CHAPTERS)
    expect(prompt).not.toContain(`chapter-${MAX_REALTIME_OUTLINE_CHAPTERS}-`)
  })

  it("preserves an absent outline and optional author at the shared boundary", () => {
    expect(normalizeRealtimeOutline(undefined)).toBeUndefined()
    expect(
      normalizeRealtimeOutline({ title: "Title", chapters: [] }),
    ).toEqual({ title: "Title", chapters: [] })
  })
})

describe("buildRealtimeClientSecretsBody tool specs", () => {
  it("includes the bookContext and currentPageContext tools", () => {
    const tools = buildRealtimeClientSecretsBody({ language: "en" }).session.tools

    expect(tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ type: "function", name: "bookContext" }),
        expect.objectContaining({ type: "function", name: "currentPageContext" }),
      ]),
    )
    expect(tools.find((tool) => tool.name === "bookContext")?.parameters.required).toEqual([
      "queryText",
    ])
  })

  it("includes chapterIndex bounds and automatic tool choice", () => {
    const session = buildRealtimeClientSecretsBody({ language: "en" }).session

    expect(session.tool_choice).toBe("auto")
    expect(session.tools).toEqual(
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
})

describe("mintRealtimeClientSecret", () => {
  it("projects OpenAI's response into the voice-session secret shape", async () => {
    setOpenAISuccess({
      value: "sec_abc123",
      expires_at: 1700000000,
      id: "sess_xyz",
    })
    await expect(mintRealtimeClientSecret("sk-test", { language: "es" })).resolves.toEqual({
      clientSecret: "sec_abc123",
      sessionId: "sess_xyz",
      expiresAt: 1700000000,
    })
    expect(openaiCaptured.url).toBe("https://api.openai.com/v1/realtime/client_secrets")
    expect(
      (openaiCaptured.body as ReturnType<typeof buildRealtimeClientSecretsBody>).session.audio.input
        .transcription.language,
    ).toBe("es")
  })

  it("synthesizes a local session ID when OpenAI omits id", async () => {
    setOpenAISuccess({
      value: "sec_abc",
      expires_at: 1700000000,
    })
    const secret = await mintRealtimeClientSecret("sk-test", { language: "en" })

    expect(secret.clientSecret).toBe("sec_abc")
    expect(secret.sessionId).toMatch(/^local_/)
    expect(secret.expiresAt).toBe(1700000000)
  })

  it("propagates OpenAI failures to the voice-session route", async () => {
    const error = {
      message: "Request failed with status code 401",
      response: { status: 401, data: { error: "invalid_api_key" } },
    }
    setOpenAIError(error)

    await expect(mintRealtimeClientSecret("sk-test", { language: "en" })).rejects.toBe(error)
  })
})
