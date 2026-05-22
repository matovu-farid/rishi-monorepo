import axios from "axios";
import { Hono } from "hono";
import { cors } from "hono/cors";

import { createOpenAI } from "@ai-sdk/openai";
import {
  experimental_generateSpeech as generateSpeech,
  generateText,
  embedMany,
  APICallError,
} from "ai";
import { z } from "zod";
import * as Sentry from "@sentry/cloudflare";
import { Redis } from "@upstash/redis/cloudflare";
import { syncRoutes } from "./routes/sync";
import { uploadRoutes } from "./routes/upload";
import { desktopRoutes } from "./routes/desktop";
import { mobileRoutes } from "./routes/mobile";
import { testAuthRoutes } from "./routes/test-auth";
import { createAuth } from "./auth";

// Must stay in sync with apps/rishi-electron/src/renderer/src/lib/languages.ts
const ALLOWED_REALTIME_LANGUAGES = [
  'en',
  'es',
  'fr',
  'de',
  'it',
  'pt',
  'ja',
  'ko',
  'zh',
  'ar',
  'hi',
  'ru'
] as const

function coerceLanguage(raw: string | undefined): string {
  if (!raw) return 'en'
  return (ALLOWED_REALTIME_LANGUAGES as readonly string[]).includes(raw) ? raw : 'en'
}

// Lazily memoize the AI SDK provider so we don't re-allocate it (and any
// internal state it caches) on every request. The Cloudflare Workers env
// binding is only available at request time, so we key the cache on apiKey.
let _openai: ReturnType<typeof createOpenAI> | null = null
let _openaiApiKey: string | null = null
function getOpenAI(apiKey: string): ReturnType<typeof createOpenAI> {
  if (_openai && _openaiApiKey === apiKey) return _openai
  _openai = createOpenAI({ apiKey })
  _openaiApiKey = apiKey
  return _openai
}

/**
 * Build the request body sent to OpenAI's POST /v1/realtime/client_secrets.
 *
 * Extracted as a pure function so we can assert on its shape in tests. OpenAI
 * requires `session.audio.input.transcription.model` whenever the
 * `transcription` object is present — omitting it produces a 400
 * `missing_required_parameter` and breaks voice chat activation.
 */
export function buildRealtimeClientSecretsBody(language: string) {
  return {
    expires_after: {
      anchor: "created_at",
      seconds: 600,
    },
    session: {
      type: "realtime",
      model: "gpt-realtime",
      instructions: "You are a friendly assistant.",
      audio: {
        input: {
          transcription: { model: "gpt-4o-mini-transcribe", language },
        },
      },
    },
  } as const
}

/** Constant-time string comparison to prevent timing attacks. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  return crypto.subtle.timingSafeEqual(bufA, bufB);
}

export interface CloudflareBindings {
  BETTER_AUTH_SECRET: string;
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  GOOGLE_CLIENT_ID: string;
  GOOGLE_CLIENT_SECRET: string;
  RESEND_API_KEY: string;
  PUBLIC_API_URL: string;
  PUBLIC_WEB_URL: string;
  RISHI_DESKTOP_STATE: KVNamespace;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  DEV_BYPASS_SECRET?: string;
  SENTRY_DSN?: string;
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
  // Storage caps for /api/sync/upload-url. wrangler passes numeric vars as
  // strings — parse with Number(...) || DEFAULT in the consuming code.
  BOOK_MAX_FILE_BYTES?: string;
  BOOK_MAX_PER_USER?: string;
  BOOK_MAX_USER_BYTES?: string;
  // Test-only auth routes. All three gates (env=true, header matches secret,
  // var present) must pass or /test/* returns 404 — strangers see "no such
  // endpoint".
  ENABLE_TEST_AUTH?: string;
  TEST_AUTH_SECRET?: string;
}

const app = new Hono<{ Bindings: CloudflareBindings; Variables: { userId: string } }>();

// CORS must be registered before any auth middleware
app.use(
  "*",
  cors({
    origin: [
      "https://rishi.fidexa.org",
      "https://app.fidexa.org",
      "tauri://localhost",
      "http://tauri.localhost",
      "http://localhost:3000",
      "http://localhost:5173",
      "http://localhost:5174",
    ],
    allowHeaders: ["Content-Type", "Authorization", "X-Dev-Bypass"],
    allowMethods: ["GET", "POST", "OPTIONS", "DELETE"],
    credentials: true,
  })
);

// Better Auth handles all /api/auth/* internally
app.on(["GET", "POST"], "/api/auth/*", async (c) => {
  const auth = createAuth(c.env);
  return auth.handler(c.req.raw);
});

app.get("/", (c) => {
  return c.text("Hello Hono!");
});

// ─── requireAuth middleware ─────────────────────────────────────────────────
// Validates the caller's Better Auth session token (cookie or Authorization
// header) and exposes the user id via c.get("userId"). Preserves the dev
// bypass header for local development.
export async function requireAuth(c: any, next: () => Promise<void>) {
  const devSecret = c.env.DEV_BYPASS_SECRET;
  if (devSecret) {
    const devHeader = c.req.header("X-Dev-Bypass");
    if (devHeader && timingSafeEqual(devHeader, devSecret)) {
      c.set("userId", "dev-user");
      return next();
    }
  }

  const auth = createAuth(c.env);
  const session = await auth.api.getSession({ headers: c.req.raw.headers });
  if (!session) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  c.set("userId", session.user.id);
  await next();
}

// ─── Sync routes ─────────────────────────────────────────────────────────────
app.route("/api/sync", syncRoutes);
app.route("/api/sync", uploadRoutes);
app.route("/desktop", desktopRoutes);
app.route("/mobile", mobileRoutes);
// ─── Test-only routes (hard-gated by ENABLE_TEST_AUTH + TEST_AUTH_SECRET) ────
// All endpoints under /test/* return 404 unless three checks pass — see
// src/routes/test-auth.ts. Production keeps both env vars unset.
app.route("/test", testAuthRoutes);

// ─── Protected routes ─────────────────────────────────────────────────────────
app.get("/api/redis-test", requireAuth, async (c) => {
  const redis = Redis.fromEnv(c.env);
  await redis.set("foo", "bar");
  const value = await redis.get("foo");
  return c.json({ value });
});

// // Health check endpoint
app.get("/health", (c) => {
  return c.json({
    status: "healthy",
    timestamp: new Date().toISOString(),
    service: "openai-tts-proxy",
  });
});

app.post("/api/audio/speech", requireAuth, async (c) => {
  try {
    const { input, voice } = await c.req.json();

    if (!input || typeof input !== "string" || input.trim().length === 0) {
      return c.json({ error: "Missing or empty input text" }, 400);
    }

    if (input.length > 4096) {
      return c.json({ error: "Input text must be 4096 characters or fewer" }, 400);
    }

    const allowedVoices = ["alloy", "echo", "fable", "onyx", "nova", "shimmer"];
    const validVoice = allowedVoices.includes(voice) ? voice : "alloy";

    const openai = getOpenAI(c.env.OPENAI_API_KEY);

    const speech = await generateSpeech({
      model: openai.speech("tts-1"),
      text: input,
      voice: validVoice,
    });

    const audioBytes = speech.audio.uint8Array;
    return new Response(audioBytes, {
      headers: {
        "Content-Type": "audio/mpeg",
        "Content-Length": audioBytes.byteLength.toString(),
      },
    });
  } catch (error) {
    if (APICallError.isInstance(error)) {
      console.error("OpenAI API error:", error.statusCode, error.message);
      return c.json(
        { error: "TTS generation failed" },
        error.statusCode === 429 ? 429 : 502
      );
    }
    console.error("TTS error:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "TTS generation failed" }, 500);
  }
});

app.get("/api/realtime/client_secrets", requireAuth, async (c) => {
  try {
    const language = coerceLanguage(c.req.query("language"));
    const response = await axios.post(
      "https://api.openai.com/v1/realtime/client_secrets",
      buildRealtimeClientSecretsBody(language),
      {
        headers: {
          Authorization: `Bearer ${c.env.OPENAI_API_KEY}`,
          "Content-Type": "application/json",
        },
        timeout: 30_000,
      }
    );
    const responseSchema = z.object({
      value: z.string(),
      expires_at: z.number(),
    });
    const parsedResponse = responseSchema.parse(response.data);
    return c.json({ client_secret: { value: parsedResponse.value } });
  } catch (error) {
    const axiosErr = error as { response?: { status?: number; data?: unknown }; message?: string }
    const upstreamStatus = axiosErr.response?.status ?? null
    const upstreamBody = axiosErr.response?.data ?? null
    const message = error instanceof Error ? error.message : "unknown"
    console.error("Failed to get client secrets:", { message, upstreamStatus, upstreamBody })
    return c.json(
      { error: "Failed to get client secrets", detail: { message, upstreamStatus, upstreamBody } },
      500
    );
  }
});

app.post("/api/text/completions", requireAuth, async (c) => {
  try {
    const body = await c.req.json();
    const input = body?.input;
    if (!input || typeof input !== "string" || input.length > 50000) {
      return c.json({ error: "input must be a string under 50000 characters" }, 400);
    }
    const openai = getOpenAI(c.env.OPENAI_API_KEY);
    const { text } = await generateText({
      model: openai.responses("gpt-5-nano"),
      prompt: input,
      // The AI SDK's OpenAI Responses provider defaults `store: true`, which
      // tells OpenAI to retain the request/response for later retrieval. We
      // proxy user book content here — opt out explicitly.
      providerOptions: { openai: { store: false } },
    });

    return c.json(text);
  } catch (error) {
    if (APICallError.isInstance(error)) {
      return c.json({ error: error.message }, (error.statusCode as 400) || 500);
    }
    return c.json({ error: "Internal server error" }, 500);
  }
});

// ─── POST /api/embed — Server-side embedding fallback ────────────────────────
app.post("/api/embed", requireAuth, async (c) => {
  const body = await c.req.json<{ texts: string[] }>();

  if (!body.texts || body.texts.length === 0) {
    return c.json({ error: "texts array is required and must not be empty" }, 400);
  }

  if (!Array.isArray(body.texts)) {
    return c.json({ error: "texts must be an array" }, 400);
  }

  if (body.texts.length > 100) {
    return c.json({ error: "texts array must not exceed 100 items" }, 400);
  }

  for (const text of body.texts) {
    if (typeof text !== "string" || text.length > 50000) {
      return c.json({ error: "Each text must be a string under 50000 characters" }, 400);
    }
  }

  const openai = getOpenAI(c.env.OPENAI_API_KEY);

  const { embeddings } = await embedMany({
    model: openai.embeddingModel("text-embedding-3-small"),
    values: body.texts,
    providerOptions: {
      openai: {
        dimensions: 384, // Match on-device all-MiniLM-L6-v2 dimensions
      },
    },
  });

  return c.json({ embeddings });
});

// ─── POST /api/audio/transcribe — Deepgram STT proxy ──────────────────────────
app.post("/api/audio/transcribe", requireAuth, async (c) => {
  const contentType = c.req.header("Content-Type") || "audio/webm";
  const audioData = await c.req.arrayBuffer();

  if (audioData.byteLength === 0) {
    return c.json({ error: "Empty audio data" }, 400);
  }

  const dgAbort = new AbortController();
  const dgTimeout = setTimeout(() => dgAbort.abort(), 30_000);
  let dgResponse: Response;
  try {
    dgResponse = await fetch(
      "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&punctuate=true&language=en",
      {
        method: "POST",
        headers: {
          "Authorization": `Token ${c.env.DEEPGRAM_KEY}`,
          "Content-Type": contentType,
        },
        body: audioData,
        signal: dgAbort.signal,
      }
    );
  } catch (e) {
    clearTimeout(dgTimeout);
    throw e;
  }

  if (!dgResponse.ok) {
    const errorText = await dgResponse.text();
    clearTimeout(dgTimeout);
    console.error("Deepgram error:", dgResponse.status, errorText);
    return c.json({ error: "Transcription failed" }, 502);
  }

  const result = await dgResponse.json() as any;
  clearTimeout(dgTimeout);
  const transcript =
    result?.results?.channels?.[0]?.alternatives?.[0]?.transcript || "";

  return c.json({ transcript });
});

export default Sentry.withSentry((env: any) => {
  const { id: versionId } = env.CF_VERSION_METADATA;
  return {
    dsn: env.SENTRY_DSN || "",
    release: versionId,
    // Adds request headers and IP for users, for more info visit:
    // https://docs.sentry.io/platforms/javascript/guides/cloudflare/configuration/options/#sendDefaultPii
    sendDefaultPii: false,
    enableLogs: true,
  };
}, app);

// export default app;
