import { describe, it, expect } from "vitest"
import { buildRealtimeClientSecretsBody } from "./index"

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
