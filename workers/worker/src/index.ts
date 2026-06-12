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
import { devicesRoutes } from "./routes/devices";
import { conversationsRoutes } from "./routes/conversations";
import { messagesRoutes } from "./routes/messages";
import { testAuthRoutes } from "./routes/test-auth";
import { createAuth } from "./auth";
import { ensureCreditAndSubscription } from "./billing/backfill";
import { meterFromContext } from "./billing/meter";
import { createPortalSession } from "./billing/portal";
import { parseRealtimeUsageBody } from "./billing/realtime-usage";
import { ensureCustomerAndPortal } from "./billing/start";
import { registerVerifyReceiptRoute } from "./billing/apple-verify-receipt";
import { registerAppleWebhookRoute } from "./billing/apple-webhook";
import { registerBillingMeRoute } from "./billing/apple-me";
import { createStripeClient } from "./billing/stripe";
import { requireActiveSubscription } from "./billing/sub-gate";
import { createDb } from "./db/drizzle";
import { user as userTable } from "@rishi/shared/schema";
import { getStripeIdsForKey } from "@rishi/shared/billing/stripe-config";
import { eq } from "drizzle-orm";

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
  // Stripe billing. Both are wrangler secrets — STRIPE_SECRET_KEY is the
  // sk_test_/sk_live_ key, STRIPE_WEBHOOK_SECRET is the whsec_ value for
  // the endpoint registered at /api/auth/stripe/webhook.
  STRIPE_SECRET_KEY?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  // Apple Sign-In (native iOS). All four required to register the Better
  // Auth Apple social provider; set via `wrangler secret put`. APPLE_TEAM_ID
  // is shared with Phase 14 (IAP S2S) — do not duplicate. CLIENT_ID is the
  // iOS bundle identifier (e.g. "org.fidexa.rishi"), KEY_ID is the 10-char
  // Apple Key ID, PRIVATE_KEY is the .p8 file contents (PKCS8 PEM).
  APPLE_SIWA_CLIENT_ID?: string;
  APPLE_SIWA_KEY_ID?: string;
  APPLE_SIWA_PRIVATE_KEY?: string;
  APPLE_TEAM_ID?: string;
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
  const auth = await createAuth(c.env);
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

  const auth = await createAuth(c.env);
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
// Phase 16 — chat sync (conversations + messages). Both behind requireAuth
// (declared inside each router). Parallel to the existing /api/sync mounts.
app.route("/api/sync/conversations", conversationsRoutes);
app.route("/api/sync/messages", messagesRoutes);
app.route("/desktop", desktopRoutes);
app.route("/mobile", mobileRoutes);
// Quick-VPX VPX-02 — APNs device registration for silent-push sync wake.
app.route("/api/devices", devicesRoutes);
// ─── Test-only routes (hard-gated by ENABLE_TEST_AUTH + TEST_AUTH_SECRET) ────
// All endpoints under /test/* return 404 unless three checks pass — see
// src/routes/test-auth.ts. Production keeps both env vars unset.
app.route("/test", testAuthRoutes);

// Gate-only probe used by scripts/billing-e2e-clock.ts. Same gate stack as
// the AI endpoints (requireAuth + requireActiveSubscription) but with no
// downstream work, so a missing OPENAI_API_KEY can't muddy the result.
// 404 in prod because ENABLE_TEST_AUTH is unset.
app.get(
  "/test/billing-gate-check",
  async (c, next) => {
    if (c.env.ENABLE_TEST_AUTH !== "true") {
      return new Response("Not Found", { status: 404 });
    }
    return next();
  },
  requireAuth,
  requireActiveSubscription,
  (c) => c.json({ ok: true }),
);

// ─── Apple IAP routes (Phase 14) ──────────────────────────────────────────────
// POST /api/billing/verify-receipt — mounted behind requireAuth by the
// route factory; iOS calls this after Product.purchase() to re-verify the
// signed JWS server-side and persist the canonical subscription row.
// `requireAuth` is passed in to avoid a circular import: the route factory
// lives in ./billing/apple-verify-receipt.ts and this module imports from
// there; an `import { requireAuth } from "../index"` on the other side
// would form a runtime cycle Vitest's ESM loader rejects.
registerVerifyReceiptRoute(app, requireAuth);

// POST /api/billing/apple-webhook — Apple App Store Server Notifications V2
// endpoint. NO requireAuth: Apple posts unauthenticated; trust is the JWS
// chain (verifyAppleJWS). Idempotent on notificationUUID via INSERT ... ON
// CONFLICT DO NOTHING. Always ACKs 200 once the envelope is validated so
// Apple's ~24h retry storm halts; dispatch errors persist to the log row's
// processing_error column for daily reconciliation.
registerAppleWebhookRoute(app);

// GET /api/billing/me — single source-of-truth entitlement read. Apple row
// wins (status in 'active' | 'in_grace'); falls back to the existing Stripe
// `subscription` table (status in 'active' | 'trialing') so users who paid
// before IAP shipped do not regress to "free". Returns
// {premium:boolean, premiumUntil: ISO8601 string | null} with a 30s
// private Cache-Control header to dampen the iOS reconciler hot path.
registerBillingMeRoute(app, requireAuth);

// ─── Protected routes ─────────────────────────────────────────────────────────
app.get("/api/redis-test", requireAuth, async (c) => {
  const redis = Redis.fromEnv(c.env);
  await redis.set("foo", "bar");
  const value = await redis.get("foo");
  return c.json({ value });
});

// Customer Portal — mints a Stripe-hosted URL where the user manages
// payment methods, views invoices, and cancels their subscription.
// Returns 503 when STRIPE_SECRET_KEY is not configured (local dev),
// 409 when the user has no stripe customer yet (signup pre-dated the
// plugin, or signup hasn't finished).
app.post("/api/billing/portal", requireAuth, async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json({ error: "Billing is not configured for this environment" }, 503);
  }
  const body = await c.req
    .json<{ returnUrl?: string }>()
    .catch((): { returnUrl?: string } => ({}));
  const returnUrl = body.returnUrl ?? `${c.env.PUBLIC_WEB_URL}/account`;
  const db = createDb(c.env.DB);
  const row = await db
    .select({ stripeCustomerId: userTable.stripeCustomerId })
    .from(userTable)
    .where(eq(userTable.id, c.get("userId")))
    .get();
  if (!row?.stripeCustomerId) {
    return c.json({ error: "No Stripe customer for this user yet" }, 409);
  }
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const url = await createPortalSession(stripe, row.stripeCustomerId, returnUrl);
  return c.json({ url });
});

// Unified billing entry. Same shape as /api/billing/portal but guarantees
// the user has a Stripe customer + subscription first, so callers never
// have to handle the 409 "No Stripe customer for this user yet" branch.
app.post("/api/billing/start", requireAuth, async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json({ error: "Billing is not configured for this environment" }, 503);
  }
  const body = await c.req
    .json<{ returnUrl?: string }>()
    .catch((): { returnUrl?: string } => ({}));
  const returnUrl = body.returnUrl ?? `${c.env.PUBLIC_WEB_URL}/account`;
  const db = createDb(c.env.DB);
  const stripe = createStripeClient(c.env.STRIPE_SECRET_KEY);
  const userId = c.get("userId");
  const { priceId } = getStripeIdsForKey(c.env.STRIPE_SECRET_KEY);
  const ip = c.req.header("cf-connecting-ip") ?? null;
  const { url } = await ensureCustomerAndPortal({
    stripe,
    priceId,
    userId,
    returnUrl,
    ip,
    getUserRow: async (id) =>
      (await db
        .select({
          stripeCustomerId: userTable.stripeCustomerId,
          email: userTable.email,
        })
        .from(userTable)
        .where(eq(userTable.id, id))
        .get()) ?? null,
    updateUserStripeCustomerId: async (stripeCustomerId) => {
      await db
        .update(userTable)
        .set({ stripeCustomerId })
        .where(eq(userTable.id, userId));
    },
    ensureCreditAndSubscription,
  });
  return c.json({ url });
});

// Client-reported realtime usage. The realtime audio stream doesn't pass
// through the worker (the client connects to OpenAI directly with a
// minted credential), so the client is responsible for posting the
// final token counts here when the session ends. Trust is bounded by:
//   - requireAuth (only the signed-in user can report)
//   - per-report cap inside parseRealtimeUsageBody
// Future: per-day soft cap + correlation with client_secrets mint
// events to detect padding.
app.post("/api/billing/realtime-usage", requireAuth, async (c) => {
  const raw = await c.req.json().catch(() => null);
  const parsed = parseRealtimeUsageBody(raw);
  if (!parsed.ok) {
    return c.json({ error: parsed.error }, 400);
  }
  c.executionCtx.waitUntil(
    meterFromContext(c.env, c.get("userId"), parsed.usage),
  );
  return c.json({ accepted: true });
});

// // Health check endpoint
app.get("/health", (c) => {
  return c.json({
    status: "healthy",
    timestamp: new Date().toISOString(),
    service: "openai-tts-proxy",
  });
});

app.post("/api/audio/speech", requireAuth, requireActiveSubscription, async (c) => {
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

    c.executionCtx.waitUntil(
      meterFromContext(c.env, c.get("userId"), {
        type: "tts",
        model: "tts-1",
        characters: input.length,
      }),
    );

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

app.get("/api/realtime/client_secrets", requireAuth, requireActiveSubscription, async (c) => {
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

app.post("/api/text/completions", requireAuth, requireActiveSubscription, async (c) => {
  try {
    const body = await c.req.json();
    const input = body?.input;
    if (!input || typeof input !== "string" || input.length > 50000) {
      return c.json({ error: "input must be a string under 50000 characters" }, 400);
    }
    const openai = getOpenAI(c.env.OPENAI_API_KEY);
    const { text, usage } = await generateText({
      model: openai.responses("gpt-5-nano"),
      prompt: input,
      // The AI SDK's OpenAI Responses provider defaults `store: true`, which
      // tells OpenAI to retain the request/response for later retrieval. We
      // proxy user book content here — opt out explicitly.
      providerOptions: { openai: { store: false } },
    });

    c.executionCtx.waitUntil(
      meterFromContext(c.env, c.get("userId"), {
        type: "chat",
        model: "gpt-5-nano",
        inputTokens: usage.inputTokens ?? 0,
        outputTokens: usage.outputTokens ?? 0,
      }),
    );

    return c.json(text);
  } catch (error) {
    if (APICallError.isInstance(error)) {
      return c.json({ error: error.message }, (error.statusCode as 400) || 500);
    }
    return c.json({ error: "Internal server error" }, 500);
  }
});

// ─── POST /api/embed — Server-side embedding fallback ────────────────────────
app.post("/api/embed", requireAuth, requireActiveSubscription, async (c) => {
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

  const { embeddings, usage } = await embedMany({
    model: openai.embeddingModel("text-embedding-3-small"),
    values: body.texts,
    providerOptions: {
      openai: {
        dimensions: 384, // Match on-device all-MiniLM-L6-v2 dimensions
      },
    },
  });

  c.executionCtx.waitUntil(
    meterFromContext(c.env, c.get("userId"), {
      type: "embedding",
      model: "text-embedding-3-small",
      tokens: usage?.tokens ?? 0,
    }),
  );

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
