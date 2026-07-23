import axios from "axios";
import { z } from "zod";

import {
  BOOK_CONTEXT_TOOL_SPEC,
  renderRealtimeInstructions,
} from "@rishi/shared/voice-chat/build-realtime-agent";

// Must stay in sync with apps/rishi-electron/src/renderer/src/lib/languages.ts
export const ALLOWED_REALTIME_LANGUAGES = [
  "en",
  "es",
  "fr",
  "de",
  "it",
  "pt",
  "ja",
  "ko",
  "zh",
  "ar",
  "hi",
  "ru",
] as const;

export function coerceLanguage(raw: string | undefined): string {
  if (!raw) return "en";
  return (ALLOWED_REALTIME_LANGUAGES as readonly string[]).includes(raw)
    ? raw
    : "en";
}

/**
 * Phase 25-06: the worker bakes a book-aware system prompt + the
 * `bookContext` tool spec into the OpenAI realtime session, so the model can
 * actually invoke the iOS-side Responder. All book-context fields are
 * optional so a voice session started without an open book still works.
 *
 * Notes
 * - When `outline` / `pageText` / `activeParagraphText` are absent,
 *   `renderRealtimeInstructions` still produces a coherent generic prompt
 *   (no "undefined"/"null" leakage) — see packages/shared tests for that
 *   string-rendering contract.
 * - OpenAI requires `session.audio.input.transcription.model` whenever the
 *   `transcription` object is present — omitting it produces a 400
 *   `missing_required_parameter` and breaks voice chat activation. (Regression
 *   pinned by `realtime-client-secrets.test.ts`.)
 *
 * Moved verbatim from `workers/worker/src/index.ts` by
 * `2026-07-17-voice-sessions-route.md` so `/api/realtime/client_secrets` and
 * the new `POST /api/voice-sessions` share one body-builder instead of two
 * copies drifting apart. `index.ts` re-exports this symbol so the
 * pre-existing `realtime-client-secrets.test.ts` import
 * (`import { buildRealtimeClientSecretsBody } from "./index"`) keeps working
 * unchanged.
 */
export interface BuildClientSecretsInput {
  language: string;
  bookId?: string;
  currentPage?: number;
  pageText?: string;
  outline?: {
    title: string;
    author?: string;
    chapters: string[];
  };
  activeParagraphText?: string;
}

export function buildRealtimeClientSecretsBody(input: BuildClientSecretsInput) {
  // renderOutlineSection reads `outline.author` with a truthy check, so the
  // shared `BookOutline.author: string | null` and our wire-side
  // `author?: string` are behaviourally equivalent. Normalize undefined → null
  // for the type-level handshake.
  const outline = input.outline
    ? {
        title: input.outline.title,
        author: input.outline.author ?? null,
        chapters: input.outline.chapters,
      }
    : undefined;
  const instructions = renderRealtimeInstructions({
    pageText: input.pageText ?? "",
    language: input.language,
    outline,
    activeParagraphText: input.activeParagraphText,
  });
  return {
    expires_after: {
      anchor: "created_at",
      seconds: 600,
    },
    session: {
      type: "realtime",
      model: "gpt-realtime-mini",
      instructions,
      tools: [
        {
          type: "function",
          name: BOOK_CONTEXT_TOOL_SPEC.name,
          description: BOOK_CONTEXT_TOOL_SPEC.description,
          parameters: BOOK_CONTEXT_TOOL_SPEC.parameters,
        },
      ],
      // Keep the complete realtime session configuration on the ephemeral
      // key. The iOS WebRTC client deliberately does not send a second
      // `session.update` after the data channel opens: duplicating the full
      // payload there adds another data-channel round trip before audio can
      // start. These values mirror RealtimeSessionConfigBuilder on iOS.
      tool_choice: "auto",
      audio: {
        input: {
          format: {
            type: "audio/pcm",
            rate: 24000,
          },
          noise_reduction: {
            type: "near_field",
          },
          transcription: {
            model: "gpt-4o-mini-transcribe",
            language: input.language,
          },
          turn_detection: {
            type: "server_vad",
            prefix_padding_ms: 300,
            silence_duration_ms: 700,
            threshold: 0.7,
          },
        },
        output: {
          voice: "alloy",
          speed: 1.0,
          format: {
            type: "audio/pcm",
            rate: 24000,
          },
        },
      },
    },
  } as const;
}

const OpenAiClientSecretResponseSchema = z.object({
  value: z.string(),
  expires_at: z.number(),
  id: z.string().optional(),
});

export interface MintedRealtimeClientSecret {
  clientSecret: string;
  sessionId: string;
  expiresAt: number;
}

/**
 * Mints a short-lived OpenAI Realtime ephemeral client secret — the exact
 * same OpenAI request the pre-existing `/api/realtime/client_secrets` route
 * used to make inline (same endpoint, same `buildRealtimeClientSecretsBody`,
 * same `OPENAI_API_KEY` env binding, same response projection). Extracted
 * here so `POST /api/voice-sessions`
 * (`workers/worker/src/routes/voice-sessions.ts`) can call it without a
 * second copy of the axios call or the response-shape parsing; `index.ts`'s
 * own route calls this function too.
 */
export async function mintRealtimeClientSecret(
  apiKey: string,
  input: BuildClientSecretsInput,
): Promise<MintedRealtimeClientSecret> {
  const response = await axios.post(
    "https://api.openai.com/v1/realtime/client_secrets",
    buildRealtimeClientSecretsBody(input),
    {
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      timeout: 30_000,
    },
  );
  // OpenAI's POST /v1/realtime/client_secrets returns a richer payload than
  // either caller consumes: `value` is the JWT ephemeral key, `expires_at` is
  // the JWT TTL, and `id` is the realtime session id. If OpenAI ever omits
  // `id` (defensive — it's present in production today), synthesise a
  // `local_<uuid>` so callers always get a non-empty string and logs can
  // distinguish synthesised ids from real OpenAI session ids. (Phase 17-05,
  // Gap 8 of the 2026-06-12 wire-contract audit — behavior preserved from
  // the original inline implementation.)
  const parsed = OpenAiClientSecretResponseSchema.parse(response.data);
  return {
    clientSecret: parsed.value,
    sessionId: parsed.id ?? `local_${crypto.randomUUID()}`,
    expiresAt: parsed.expires_at,
  };
}
