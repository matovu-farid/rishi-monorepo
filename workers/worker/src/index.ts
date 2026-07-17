import axios from "axios";
import OpenAI from "openai";

import { Hono } from "hono";
import { cors } from "hono/cors";

import { createOpenAI } from "@ai-sdk/openai";
import { generateText, embedMany, APICallError } from "ai";
import { z } from "zod";

import * as Sentry from "@sentry/cloudflare";
import { syncRoutes } from "./routes/sync";
import { uploadRoutes } from "./routes/upload";
import { desktopRoutes } from "./routes/desktop";
import { mobileRoutes } from "./routes/mobile";
import { voiceSessionsRoutes } from "./routes/voice-sessions";
import { devicesRoutes } from "./routes/devices";
import { chatRoutes } from "./routes/chat";
import { conversationsRoutes } from "./routes/conversations";
import { messagesRoutes } from "./routes/messages";
import { changesRoutes } from "./routes/changes";
import { testAuthRoutes } from "./routes/test-auth";
import { ensureCreditAndSubscription } from "./billing/backfill";
import { meterFromContext } from "./billing/meter";
import { createPortalSession } from "./billing/portal";
import { parseRealtimeUsageBody } from "./billing/realtime-usage";
import { ensureCustomerAndPortal } from "./billing/start";
import { registerVerifyReceiptRoute } from "./billing/apple-verify-receipt";
import { registerAppleWebhookRoute } from "./billing/apple-webhook";
import { registerBillingMeRoute } from "./billing/apple-me";
import { registerEntitlementSyncRoute } from "./billing/entitlement-sync";
import { createStripeClient } from "./billing/stripe";
import { requireActiveSubscription } from "./billing/sub-gate";
import { createDb } from "./db/drizzle";
import { user, user as userTable } from "@rishi/shared/schema";
import { getStripeIdsForKey } from "@rishi/shared/billing/stripe-config";
import authRoutes from "./routes/auth";
import {
  BOOK_CONTEXT_TOOL_SPEC,
  renderRealtimeInstructions,
} from "@rishi/shared/voice-chat/build-realtime-agent";
import { eq } from "drizzle-orm";
import { Effect, Layer } from "effect";
import { AppleBucket, createTestNotification } from "./apple-connect/functions";
import { value } from "effect/Redacted";
import { createRemoteJWKSet, jwtVerify } from "jose";
import { requireAuth } from "./middleware";
import { signAccessToken, signRefreshToken, verifyRefreshToken } from "./jwt";
import { findOrCreateUser } from "./findOrCreateUser";
import { incrementApiUsage } from "./usage/api-usage";
import { error } from "node:console";
import { userRoutes } from "./routes/user";
import { estimateNarrationSeconds } from "./tts/reservation-estimate";
import { InsufficientAllowanceError } from "./durable-objects/user-usage-ledger/errors";
export { requireAuth } from "./middleware";
export { UserUsageLedger } from "./durable-objects/user-usage-ledger/ledger";

// Must stay in sync with apps/rishi-electron/src/renderer/src/lib/languages.ts
const ALLOWED_REALTIME_LANGUAGES = [
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

function coerceLanguage(raw: string | undefined): string {
  if (!raw) return "en";
  return (ALLOWED_REALTIME_LANGUAGES as readonly string[]).includes(raw)
    ? raw
    : "en";
}

// Lazily memoize the AI SDK provider so we don't re-allocate it (and any
// internal state it caches) on every request. The Cloudflare Workers env
// binding is only available at request time, so we key the cache on apiKey.
let _openai: ReturnType<typeof createOpenAI> | null = null;
let _openaiApiKey: string | null = null;
function getOpenAI(apiKey: string): ReturnType<typeof createOpenAI> {
  if (_openai && _openaiApiKey === apiKey) return _openai;
  _openai = createOpenAI({ apiKey });
  _openaiApiKey = apiKey;
  return _openai;
}

// Separate client for the direct Speech API path.
let _speechOpenAI: OpenAI | null = null;
let _speechOpenAIKey: string | null = null;
function getSpeechOpenAI(apiKey: string): OpenAI {
  if (_speechOpenAI && _speechOpenAIKey === apiKey) return _speechOpenAI;
  _speechOpenAI = new OpenAI({ apiKey });
  _speechOpenAIKey = apiKey;
  return _speechOpenAI;
}

const ELEVENLABS_MODEL_ID = "eleven_v3";
const ELEVENLABS_ALLOWED_MODEL_IDS = new Set([
  "eleven_v3",
  "eleven_flash_v2_5",
  "eleven_flash_v2",
  "eleven_multilingual_v2",
]);
const ELEVENLABS_DEFAULT_VOICE_ID = "21m00Tcm4TlvDq8ikWAM";
const ELEVENLABS_VOICE_IDS: Record<string, string> = {
  alloy: "JBFqnCBsd6RMkjVDRZzb",
  ash: "29vD33N1CtxCmqQRPOHJ",
  ballad: "EXAVITQu4vr4xnSDxMaL",
  coral: "ErXwobaYiN019PkySvjV",
  echo: "MF3mGyEYCl7XYWbV9V6O",
  fable: "TxGEqnHWrfWFTfGW9XjX",
  nova: "VR6AewLTigWG4xSOukaG",
  onyx: "pNInz6obpgDQGcFmaJgB",
  sage: "yoZ06aMxZJJ28mfd3POQ",
  shimmer: "pMsXgVXv3BLzUgSXRplE",
  verse: "IKne3meq5aSn9XLyUdCD",
  marin: ELEVENLABS_DEFAULT_VOICE_ID,
  cedar: "N2lVS1w4EtoT3dr4eOWO",
};

const OPENAI_TTS_VOICE_PRESETS = [
  "alloy",
  "ash",
  "ballad",
  "coral",
  "echo",
  "fable",
  "nova",
  "onyx",
  "sage",
  "shimmer",
  "verse",
  "marin",
  "cedar",
];
const OPENAI_TTS_DEFAULT_VOICE = "marin";
const OPENAI_TTS_MODEL_ID = "gpt-4o-mini-tts";
const OPENAI_TTS_MODEL_NAME = "GPT-4o mini TTS";

function displayName(id: string): string {
  return id
    .split(/[_-]/g)
    .filter(Boolean)
    .map((part) => part.slice(0, 1).toUpperCase() + part.slice(1))
    .join(" ");
}

function resolveElevenLabsVoiceId(voice: string | undefined): string {
  if (!voice) return ELEVENLABS_DEFAULT_VOICE_ID;
  return ELEVENLABS_VOICE_IDS[voice] ?? ELEVENLABS_DEFAULT_VOICE_ID;
}

function resolveElevenLabsModelId(model: string | undefined): string {
  const normalized = model?.trim();
  if (normalized && ELEVENLABS_ALLOWED_MODEL_IDS.has(normalized)) {
    return normalized;
  }
  return ELEVENLABS_MODEL_ID;
}

/**
 * Phase 25-06: the worker now bakes a book-aware system prompt + the
 * `bookContext` tool spec into the OpenAI realtime session, so the model can
 * actually invoke the iOS-side Responder. iOS (Plan 25-08) ships the matching
 * POST body atomically. The legacy `(language: string)` signature is gone —
 * callers pass an `BuildClientSecretsInput` object, all book-context fields
 * optional.
 *
 * Notes
 * - When `outline` / `pageText` / `activeParagraphText` are absent,
 *   `renderRealtimeInstructions` still produces a coherent generic prompt
 *   (no "undefined"/"null" leakage) — see packages/shared tests for that
 *   string-rendering contract.
 * - OpenAI requires `session.audio.input.transcription.model` whenever the
 *   `transcription` object is present — omitting it produces a 400
 *   `missing_required_parameter` and breaks voice chat activation. (Regression
 *   pinned by buildRealtimeClientSecretsBody tests.)
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
      model: "gpt-realtime",
      instructions,
      tools: [
        {
          type: "function",
          name: BOOK_CONTEXT_TOOL_SPEC.name,
          description: BOOK_CONTEXT_TOOL_SPEC.description,
          parameters: BOOK_CONTEXT_TOOL_SPEC.parameters,
        },
      ],
      audio: {
        input: {
          transcription: {
            model: "gpt-4o-mini-transcribe",
            language: input.language,
          },
        },
      },
    },
  } as const;
}

/**
 * Phase 22-01: TTS R2 cache key.
 *
 * Canonical string: "gpt-4o-mini-tts|" + voice + "|" + speed.toFixed(2) + "|" + text
 * Hash: SHA-256 of the UTF-8 bytes, hex-encoded lowercase.
 *
 * The model literal "gpt-4o-mini-tts" lets a future bump invalidate
 * the cache namespace cleanly without manual purge. The iOS companion at
 * apps/apple/Packages/RishiAudio/Sources/RishiAudio/TTS/TTSCacheKey.swift
 * computes the SAME hex for the SAME (text, voice, speed) tuple — a paired
 * test in audio-speech-cache.test.ts and TTSCacheKeyTests.swift asserts this
 * symmetry against the pinned canonical string
 * "gpt-4o-mini-tts|alloy|1.00|hello world".
 */
async function ttsCacheKey(
  text: string,
  voice: string,
  speed: number,
): Promise<string> {
  const canonical = `gpt-4o-mini-tts|${voice}|${speed.toFixed(2)}|${text}`;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function elevenLabsTtsCacheKey(
  text: string,
  voice: string,
  model: string,
  speed: number,
): Promise<string> {
  // Keep this canonical string byte-aligned with iOS TTSCacheKey.compute().
  const canonical = `elevenlabs-tts|${model}|${voice}|${speed.toFixed(2)}|${text}`;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(canonical),
  );
  return [...new Uint8Array(digest)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

type TtsResponseMode = "raw" | "events";

const TTS_EVENT_CHUNK_BYTES = 4096;

function resolveTtsResponseMode(value: unknown): TtsResponseMode {
  return value === "events" ? "events" : "raw";
}

function splitTtsBytes(bytes: Uint8Array, chunkSize = TTS_EVENT_CHUNK_BYTES) {
  const chunks: Uint8Array[] = [];
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    chunks.push(bytes.slice(offset, offset + chunkSize));
  }
  return chunks;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function encodeSseFrame(fields: Array<[string, string]>): string {
  return `${fields.map(([key, value]) => `${key}: ${value}`).join("\n")}\n\n`;
}

function ttsChunkId(requestKey: string, index: number): string {
  return `${requestKey}#${index.toString().padStart(8, "0")}`;
}

function ttsDoneId(requestKey: string): string {
  return `${requestKey}#done`;
}

function buildTtsRawResponse(
  bytes: Uint8Array,
  cacheStatus: "hit" | "miss",
  entitlementHeader?: string,
): Response {
  const headers: Record<string, string> = {
    "Content-Type": "audio/mpeg",
    "Content-Length": bytes.byteLength.toString(),
    "X-TTS-Cache": cacheStatus,
  };
  if (entitlementHeader) {
    headers["X-Entitlement-Remaining"] = entitlementHeader;
  }
  return new Response(bytes, { headers });
}

function buildTtsEventResponse(
  bytes: Uint8Array,
  requestKey: string,
  cacheStatus: "hit" | "miss",
  entitlementHeader?: string,
): Response {
  const encoder = new TextEncoder();
  const chunks = splitTtsBytes(bytes);

  const stream = new ReadableStream({
    start(controller) {
      for (let index = 0; index < chunks.length; index += 1) {
        const chunkId = ttsChunkId(requestKey, index);
        controller.enqueue(
          encoder.encode(
            encodeSseFrame([
              ["id", chunkId],
              ["event", "chunk"],
              [
                "data",
                JSON.stringify({
                  request_id: requestKey,
                  chunk_id: chunkId,
                  index,
                  audio_b64: bytesToBase64(chunks[index]!),
                }),
              ],
            ]),
          ),
        );
      }

      controller.enqueue(
        encoder.encode(
          encodeSseFrame([
            ["id", ttsDoneId(requestKey)],
            ["event", "done"],
            [
              "data",
              JSON.stringify({
                request_id: requestKey,
                done: true,
                cache: cacheStatus,
                chunk_count: chunks.length,
                byte_length: bytes.byteLength,
              }),
            ],
          ]),
        ),
      );

      controller.close();
    },
  });

  const headers: Record<string, string> = {
    "Content-Type": "text/event-stream; charset=utf-8",
    "Cache-Control": "no-cache",
    "X-TTS-Cache": cacheStatus,
  };
  if (entitlementHeader) {
    headers["X-Entitlement-Remaining"] = entitlementHeader;
  }
  return new Response(stream, { headers });
}

function respondWithTtsBytes(
  bytes: Uint8Array,
  requestKey: string,
  cacheStatus: "hit" | "miss",
  mode: TtsResponseMode,
  entitlementHeader?: string,
): Response {
  if (mode === "events") {
    return buildTtsEventResponse(bytes, requestKey, cacheStatus, entitlementHeader);
  }
  return buildTtsRawResponse(bytes, cacheStatus, entitlementHeader);
}

// Budget for the best-effort entitlement-snapshot read attached to a
// successful (cache-miss) TTS response as `X-Entitlement-Remaining`. This
// lets the client optimistically update its remaining-allowance UI without
// a separate round trip (design: "The response returns the last known
// entitlement snapshot"). It is intentionally informational only: never
// let a slow ledger read add latency to audio delivery, so this races the
// snapshot read against a fixed timeout and omits the header entirely
// (rather than blocking) if the read doesn't win that race or throws.
const ENTITLEMENT_HEADER_BUDGET_MS = 250;

async function bestEffortEntitlementHeader(
  ledger: { getEntitlementSnapshot(): Promise<unknown> },
  budgetMs = ENTITLEMENT_HEADER_BUDGET_MS,
): Promise<string | undefined> {
  try {
    const timeout = new Promise<undefined>((resolve) => {
      setTimeout(() => resolve(undefined), budgetMs);
    });
    const snapshot = await Promise.race([
      ledger.getEntitlementSnapshot(),
      timeout,
    ]);
    return snapshot === undefined ? undefined : JSON.stringify(snapshot);
  } catch (err) {
    console.error("tts.entitlement.header.failed", err);
    return undefined;
  }
}

export const app = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

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
  }),
);

// app.post("/auth/refresh", async (c) => {
//   const { refreshToken } = await c.req.json();

//   const payload = await Effect.runPromise(
//     verifyRefreshToken(c.env, refreshToken),
//   );

//   const accessToken = await Effect.runPromise(
//     signAccessToken(c.env, {
//       userId: payload.userId,
//     }),
//   );

//   return c.json({
//     accessToken,
//   });
// });
// Better Auth handles all /api/auth/* internally
// app.on(["GET", "POST"], "/api/auth/*", async (c) => {
//   const auth = await createAuth(c.env);
//   return auth.handler(c.req.raw);
// });

app.get("/", (c) => {
  return c.text("Hello Hono!");
});

// ─── requireAuth middleware ─────────────────────────────────────────────────
// Validates the caller's Better Auth session token (cookie or Authorization
// header) and exposes the user id via c.get("userId"). Preserves the dev
// bypass header for local development.
// export async function requireAuth(c: any, next: () => Promise<void>) {
//   // const devSecret = c.env.DEV_BYPASS_SECRET;
//   // if (devSecret) {
//   //   const devHeader = c.req.header("X-Dev-Bypass");
//   //   if (devHeader && timingSafeEqual(devHeader, devSecret)) {
//   //     c.set("userId", "dev-user");
//   //     return next();
//   //   }
//   // }

//   const auth = await createAuth(c.env);
//   const session = await auth.api.getSession({ headers: c.req.raw.headers });
//   if (!session) {
//     return c.json({ error: "Unauthorized" }, 401);
//   }
//   c.set("userId", session.user.id);
//   await next();
// }

// ─── Sync routes ─────────────────────────────────────────────────────────────
// Quick task 260612-g89 — closes the Phase-7 inbound book + highlight bridge
// gap. iOS RishiSync/Inbound/RemoteChangeFetcher.swift calls this route on
// every sync tick; before this mount the live worker returned 404 for every
// caller. The handler enforces requireAuth + per-user filter and emits
// updated_at as seconds-since-2001 so the bare JSONDecoder() in
// apps/apple/Packages/RishiAPI/Sources/RishiAPI/WorkerClient.swift:96
// (.deferredToDate) decodes Date correctly. See changes.ts header for the
// full SyncChange envelope + Date wire-format contract.
// Mounted BEFORE the broader /api/sync prefix so the more-specific
// /api/sync/changes router wins regardless of Hono's prefix-match order.
app.route("/api/sync/changes", changesRoutes);
app.route("/api/sync", syncRoutes);
app.route("/api/sync", uploadRoutes);
app.route("/api/user", userRoutes);
// Phase 16 — chat sync (conversations + messages). Both behind requireAuth
// (declared inside each router). Parallel to the existing /api/sync mounts.
app.route("/api/sync/conversations", conversationsRoutes);
app.route("/auth", authRoutes);
app.route("/api/sync/messages", messagesRoutes);
app.route("/desktop", desktopRoutes);
app.route("/mobile", mobileRoutes);
app.route("/api/voice-sessions", voiceSessionsRoutes);
// Quick-VPX VPX-02 — APNs device registration for silent-push sync wake.
app.route("/api/devices", devicesRoutes);
// Quick task 260612-f7p — streaming chat for iOS RishiChat (v1 no RAG).
app.route("/api/chat", chatRoutes);
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

app.get("/api/groupID", async (c) => {
  return c.json({
    value: "22149819",
  });
});
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

// POST /api/billing/entitlement-sync — the authoritative-entitlement-model
// route (2026-07-17 pricing/trial-launch design doc). iOS calls this at
// launch, foreground, purchase completion, restore, and every StoreKit
// `Transaction.updates` event, posting the current signed transaction JWS.
// Verifies the JWS locally (verifyAppleJWS -- no Apple network call),
// cross-checks the derived appAccountToken against the authenticated user,
// rejects cross-account reuse, idempotently upserts apple_subscriptions,
// starts the user's first paid allowance period if none exists yet, and
// returns the resulting EntitlementSnapshot (read from the UserUsageLedger
// Durable Object).
registerEntitlementSyncRoute(app, requireAuth);

// Customer Portal — mints a Stripe-hosted URL where the user manages
// payment methods, views invoices, and cancels their subscription.
// Returns 503 when STRIPE_SECRET_KEY is not configured (local dev),
// 409 when the user has no stripe customer yet (signup pre-dated the
// plugin, or signup hasn't finished).
app.post("/api/billing/portal", requireAuth, async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json(
      { error: "Billing is not configured for this environment" },
      503,
    );
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
  const url = await createPortalSession(
    stripe,
    row.stripeCustomerId,
    returnUrl,
  );
  return c.json({ url });
});

// Unified billing entry. Same shape as /api/billing/portal but guarantees
// the user has a Stripe customer + subscription first, so callers never
// have to handle the 409 "No Stripe customer for this user yet" branch.
app.post("/api/billing/start", requireAuth, async (c) => {
  if (!c.env.STRIPE_SECRET_KEY) {
    return c.json(
      { error: "Billing is not configured for this environment" },
      503,
    );
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

app.post("/api/audio/speech", requireAuth, async (c) => {
  c.executionCtx.waitUntil(
    incrementApiUsage(c.env, c.get("userId"), "tts"),
  );

  const userId = c.get("userId");
  const ledger = c.env.USER_USAGE_LEDGER.getByName(userId);
  // Set only once reserveTts() succeeds, and cleared as soon as the
  // reservation is settled (committed or released) on any success path.
  // The catch block below releases it only if it is still set, so a
  // reservation is never released twice and never released after commit.
  let pendingReservationId: string | undefined;

  try {
    // Phase 17-03: iOS SpeechStreamEndpoint.Body sends {text, voice, speed}
    // (apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AudioAPI.swift).
    // The previous {input, voice} shape was an OpenAI passthrough that the iOS
    // client never matched, so every TTSStreamer.swift call short-circuited
    // to 400. Speed is forwarded into OpenAI's speech.create call so the
    // user-facing voice playback rate actually changes.
    const rawBody = await c.req
      .json<{
        text?: string;
        voice?: string;
        speed?: number;
        response_mode?: string;
      }>()
      .catch(
        (): {
          text?: string;
          voice?: string;
          speed?: number;
          response_mode?: string;
        } => ({}),
      );
    const { text, voice, speed, response_mode } = rawBody;
    const responseMode = resolveTtsResponseMode(response_mode);

    if (!text || typeof text !== "string" || text.trim().length === 0) {
      return c.json({ error: "Missing or empty text" }, 400);
    }

    if (text.length > 4096) {
      return c.json({ error: "text must be 4096 characters or fewer" }, 400);
    }

    const allowedVoices = [
      "alloy",
      "ash",
      "ballad",
      "coral",
      "echo",
      "fable",
      "nova",
      "onyx",
      "sage",
      "shimmer",
      "verse",
      "marin",
      "cedar",
    ];
    const validVoice = allowedVoices.includes(voice as string)
      ? (voice as string)
      : "marin";

    // Clamp speed to OpenAI TTS's supported 0.25-4.0 range; fall back to 1.0
    // for missing / non-finite / out-of-range values so the AI SDK never sees
    // a hostile float.
    const validSpeed =
      typeof speed === "number" &&
      Number.isFinite(speed) &&
      speed >= 0.25 &&
      speed <= 4.0
        ? speed
        : 1.0;

    // Phase 22-01: R2-backed content-addressed cache gate.
    // Hits skip both the OpenAI call AND metering; misses preserve all existing
    // behavior verbatim and fire-and-forget a writeback via waitUntil.
    //
    // Ledger note: per the pricing design's "Narration flow" step 2-3, the
    // cache is checked *before* any allowance is reserved, so a cache hit
    // never calls the ledger at all.
    const key = await ttsCacheKey(text, validVoice, validSpeed);

    const cached = await c.env.TTS_CACHE.get(key);
    if (cached !== null) {
      const bytes = await cached.bytes();
      return respondWithTtsBytes(bytes, key, "hit", responseMode);
    }

    // Cache miss: reserve allowance before calling the provider. The
    // reservation must exist before the OpenAI request begins so a failed
    // or slow provider call always has something to release.
    let reservationId: string;
    try {
      const reservation = await ledger.reserveTts(
        estimateNarrationSeconds(text),
      );
      reservationId = reservation.reservationId;
      pendingReservationId = reservationId;
    } catch (reserveErr) {
      if (InsufficientAllowanceError.isInstance(reserveErr)) {
        return c.json(
          {
            error: "Trial credits are exhausted",
            code: "INSUFFICIENT_ALLOWANCE",
          },
          402,
        );
      }
      throw reserveErr;
    }

    const openai = getSpeechOpenAI(c.env.OPENAI_API_KEY);

    const speech = await openai.audio.speech.create({
      model: "gpt-4o-mini-tts",
      voice: validVoice,
      input: text,
      speed: validSpeed,
      response_format: "mp3",
    });

    c.executionCtx.waitUntil(
      meterFromContext(c.env, c.get("userId"), {
        type: "tts",
        model: "gpt-4o-mini-tts",
        characters: text.length,
      }),
    );

    const audioBytes = new Uint8Array(await speech.arrayBuffer());

    // Fire-and-forget writeback; put errors must not surface to the response.
    c.executionCtx.waitUntil(
      c.env.TTS_CACHE.put(key, audioBytes, {
        httpMetadata: { contentType: "audio/mpeg" },
      }).catch((e) => console.error("tts.cache.put.failed", e)),
    );

    // Settle the reservation via waitUntil so commit latency never blocks
    // audio delivery (design: "must not wait for... cost reconciliation...
    // before streaming audio"). This commits the reservation's originally
    // estimated amount, not a measured generated duration — see this
    // plan's "Exports for downstream plans" for the flagged
    // precise-duration-parsing gap.
    c.executionCtx.waitUntil(
      ledger.commitTtsReservation(reservationId).catch((commitErr) =>
        console.error("tts.reservation.commit.failed", {
          reservationId,
          commitErr,
        }),
      ),
    );
    pendingReservationId = undefined;

    // Best-effort, budget-limited: never let a slow ledger read hold up the
    // response (see bestEffortEntitlementHeader).
    const entitlementHeader = await bestEffortEntitlementHeader(ledger);

    return respondWithTtsBytes(
      audioBytes,
      key,
      "miss",
      responseMode,
      entitlementHeader,
    );
  } catch (error) {
    // Release before responding, not fire-and-forget: a fast client retry
    // must not be blocked by a stale pending reservation.
    if (pendingReservationId) {
      const reservationId = pendingReservationId;
      await ledger.releaseTtsReservation(reservationId).catch((releaseErr) =>
        console.error("tts.reservation.release.failed", {
          reservationId,
          releaseErr,
        }),
      );
    }

    if (APICallError.isInstance(error)) {
      console.error("OpenAI API error:", error.statusCode, error.message);
      return c.json(
        { error: "TTS generation failed" },
        error.statusCode === 429 ? 429 : 502,
      );
    }
    console.error(
      "TTS error:",
      error instanceof Error ? error.message : "unknown",
    );
    return c.json({ error: "TTS generation failed" }, 500);
  }
});

app.get("/api/audio/speech/options", (_c) => {
  return _c.json({
    provider: "openai",
    voices: OPENAI_TTS_VOICE_PRESETS.map((id) => ({
      id,
      name: displayName(id),
    })),
    models: [
      {
        id: OPENAI_TTS_MODEL_ID,
        name: OPENAI_TTS_MODEL_NAME,
      },
    ],
    default_voice_id: OPENAI_TTS_DEFAULT_VOICE,
    default_model_id: OPENAI_TTS_MODEL_ID,
  });
});

app.post("/api/audio/speech/elevenlabs", requireAuth, async (c) => {
  c.executionCtx.waitUntil(
    incrementApiUsage(c.env, c.get("userId"), "tts"),
  );

  const userId = c.get("userId");
  const ledger = c.env.USER_USAGE_LEDGER.getByName(userId);
  // Same lifecycle contract as the OpenAI route above: set only once
  // reserveTts() succeeds, cleared as soon as the reservation is settled.
  let pendingReservationId: string | undefined;

  try {
    const rawBody = await c.req
      .json<{
        text?: string;
        voice?: string;
        model?: string;
        speed?: number;
        response_mode?: string;
      }>()
      .catch(
        (): {
          text?: string;
          voice?: string;
          model?: string;
          speed?: number;
          response_mode?: string;
        } => ({}),
      );
    const { text, voice, model, speed, response_mode } = rawBody;
    const responseMode = resolveTtsResponseMode(response_mode);

    if (!text || typeof text !== "string" || text.trim().length === 0) {
      return c.json({ error: "Missing or empty text" }, 400);
    }

    if (text.length > 4096) {
      return c.json({ error: "text must be 4096 characters or fewer" }, 400);
    }

    const validVoice = resolveElevenLabsVoiceId(voice);
    const validModel = resolveElevenLabsModelId(
      typeof model === "string" ? model : undefined,
    );

    const validSpeed =
      typeof speed === "number" &&
      Number.isFinite(speed) &&
      speed >= 0.25 &&
      speed <= 4.0
        ? speed
        : 1.0;

    const key = await elevenLabsTtsCacheKey(
      text,
      validVoice,
      validModel,
      validSpeed,
    );

    const cached = await c.env.TTS_CACHE.get(key);
    if (cached !== null) {
      const bytes = await cached.bytes();
      return respondWithTtsBytes(bytes, key, "hit", responseMode);
    }

    if (!c.env.ELEVEN_LABS_API_KEY) {
      return c.json({ error: "TTS generation failed" }, 503);
    }

    // Cache miss: reserve allowance before calling the provider.
    let reservationId: string;
    try {
      const reservation = await ledger.reserveTts(
        estimateNarrationSeconds(text),
      );
      reservationId = reservation.reservationId;
      pendingReservationId = reservationId;
    } catch (reserveErr) {
      if (InsufficientAllowanceError.isInstance(reserveErr)) {
        return c.json(
          {
            error: "Trial credits are exhausted",
            code: "INSUFFICIENT_ALLOWANCE",
          },
          402,
        );
      }
      throw reserveErr;
    }

    const elevenLabsUrl = new URL(
      `https://api.elevenlabs.io/v1/text-to-speech/${validVoice}`,
    );
    elevenLabsUrl.searchParams.set("output_format", "mp3_44100_128");

    const speech = await fetch(elevenLabsUrl, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "xi-api-key": c.env.ELEVEN_LABS_API_KEY,
      },
      body: JSON.stringify({
        text,
        model_id: validModel,
        voice_settings: {
          speed: validSpeed,
        },
      }),
    });

    if (!speech.ok) {
      const body = await speech.text().catch(() => "");
      console.error("ElevenLabs API error:", speech.status, body);
      // A non-ok fetch response is a returned failure, not a thrown
      // exception, so the shared catch block below never sees it — release
      // explicitly here, before responding, same contract as the catch
      // block: don't block a fast client retry on a stale reservation.
      await ledger.releaseTtsReservation(reservationId).catch((releaseErr) =>
        console.error("tts.reservation.release.failed", {
          reservationId,
          releaseErr,
        }),
      );
      pendingReservationId = undefined;
      return c.json(
        { error: "TTS generation failed" },
        speech.status === 429 ? 429 : 502,
      );
    }

    c.executionCtx.waitUntil(
      meterFromContext(c.env, c.get("userId"), {
        type: "tts",
        model: validModel,
        characters: text.length,
      }),
    );

    const audioBytes = new Uint8Array(await speech.arrayBuffer());

    c.executionCtx.waitUntil(
      c.env.TTS_CACHE.put(key, audioBytes, {
        httpMetadata: { contentType: "audio/mpeg" },
      }).catch((e) => console.error("tts.cache.put.failed", e)),
    );

    // Settle via waitUntil — see the identical comment in the OpenAI route
    // (Task 3) for why this never blocks the response, and for the
    // estimated-vs-measured-duration gap this defers.
    c.executionCtx.waitUntil(
      ledger.commitTtsReservation(reservationId).catch((commitErr) =>
        console.error("tts.reservation.commit.failed", {
          reservationId,
          commitErr,
        }),
      ),
    );
    pendingReservationId = undefined;

    const entitlementHeader = await bestEffortEntitlementHeader(ledger);

    return respondWithTtsBytes(
      audioBytes,
      key,
      "miss",
      responseMode,
      entitlementHeader,
    );
  } catch (error) {
    if (pendingReservationId) {
      const reservationId = pendingReservationId;
      await ledger.releaseTtsReservation(reservationId).catch((releaseErr) =>
        console.error("tts.reservation.release.failed", {
          reservationId,
          releaseErr,
        }),
      );
    }
    console.error(
      "TTS error:",
      error instanceof Error ? error.message : "unknown",
    );
    return c.json({ error: "TTS generation failed" }, 500);
  }
});

// Phase 25-06: POST migration (was GET ?language=). Body shape matches the iOS
// RishiAPI.RealtimeClientSecretsEndpoint.Body produced in Plan 25-08 — all
// fields optional so callers without a book (e.g. quick voice without a
// reader open) still work. Unparseable / empty bodies degrade to
// `{ language: "en" }`.
app.post(
  "/api/realtime/client_secrets",
  requireAuth,
  async (c) => {
    c.executionCtx.waitUntil(
      incrementApiUsage(c.env, c.get("userId"), "voiceChat"),
    );
    try {
      const rawBody = await c.req
        .json<Partial<BuildClientSecretsInput>>()
        .catch((): Partial<BuildClientSecretsInput> => ({}));
      const language = coerceLanguage(rawBody.language);
      const response = await axios.post(
        "https://api.openai.com/v1/realtime/client_secrets",
        buildRealtimeClientSecretsBody({
          language,
          bookId: rawBody.bookId,
          currentPage: rawBody.currentPage,
          pageText: rawBody.pageText,
          outline: rawBody.outline,
          activeParagraphText: rawBody.activeParagraphText,
        }),
        {
          headers: {
            Authorization: `Bearer ${c.env.OPENAI_API_KEY}`,
            "Content-Type": "application/json",
          },
          timeout: 30_000,
        },
      );
      // OpenAI's POST /v1/realtime/client_secrets returns a richer payload than
      // we used to consume: `value` is the JWT ephemeral key, `expires_at` is
      // the JWT TTL, and `id` is the realtime session id. iOS
      // RishiAPI/Endpoints/RealtimeAPI.swift:31-39 decodes the response as
      // `{client_secret: String, session_id: String}` — both flat strings.
      //
      // Project the OpenAI shape into the iOS contract. If OpenAI ever omits
      // `id` (defensive — it's present in production today), synthesise a
      // `local_<uuid>` so the iOS decoder still gets a non-empty string and
      // logs can distinguish synthesised ids from real OpenAI session ids.
      // Phase 17-05 (Gap 8 of the 2026-06-12 wire-contract audit).
      const responseSchema = z.object({
        value: z.string(),
        expires_at: z.number(),
        id: z.string().optional(),
      });
      const parsedResponse = responseSchema.parse(response.data);
      return c.json({
        client_secret: parsedResponse.value,
        session_id: parsedResponse.id ?? `local_${crypto.randomUUID()}`,
      });
    } catch (error) {
      const axiosErr = error as {
        response?: { status?: number; data?: unknown };
        message?: string;
      };
      const upstreamStatus = axiosErr.response?.status ?? null;
      const upstreamBody = axiosErr.response?.data ?? null;
      const message = error instanceof Error ? error.message : "unknown";
      console.error("Failed to get client secrets:", {
        message,
        upstreamStatus,
        upstreamBody,
      });
      return c.json(
        {
          error: "Failed to get client secrets",
          detail: { message, upstreamStatus, upstreamBody },
        },
        500,
      );
    }
  },
);

app.post(
  "/api/text/completions",
  requireAuth,
  requireActiveSubscription,
  async (c) => {
    try {
      const body = await c.req.json();
      const input = body?.input;
      if (!input || typeof input !== "string" || input.length > 50000) {
        return c.json(
          { error: "input must be a string under 50000 characters" },
          400,
        );
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
        return c.json(
          { error: error.message },
          (error.statusCode as 400) || 500,
        );
      }
      return c.json({ error: "Internal server error" }, 500);
    }
  },
);

// ─── POST /api/embed — Server-side embedding fallback ────────────────────────
app.post("/api/embed", requireAuth, requireActiveSubscription, async (c) => {
  const body = await c.req.json<{ texts: string[] }>();

  if (!body.texts || body.texts.length === 0) {
    return c.json(
      { error: "texts array is required and must not be empty" },
      400,
    );
  }

  if (!Array.isArray(body.texts)) {
    return c.json({ error: "texts must be an array" }, 400);
  }

  if (body.texts.length > 100) {
    return c.json({ error: "texts array must not exceed 100 items" }, 400);
  }

  for (const text of body.texts) {
    if (typeof text !== "string" || text.length > 50000) {
      return c.json(
        { error: "Each text must be a string under 50000 characters" },
        400,
      );
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
// Accepts iOS TranscribeEndpoint.Body shape — JSON `{audio: <base64>, mime_type}`
// — see apps/apple/Packages/RishiAPI/Sources/RishiAPI/Endpoints/AudioAPI.swift.
// Swift's default JSONEncoder() serializes `Data` as a base64 string, so the
// worker base64-decodes the audio field before forwarding raw bytes to
// Deepgram with `Content-Type: <mime_type>`. Phase 17-04 / Gap 7.
const ALLOWED_TRANSCRIBE_MIME_TYPES = new Set([
  "audio/webm",
  "audio/mp4",
  "audio/mpeg",
  "audio/wav",
  "audio/ogg",
  "audio/m4a",
]);

app.post("/api/audio/transcribe", requireAuth, async (c) => {
  // 1. Parse JSON body.
  const body = await c.req
    .json<{ audio?: unknown; mime_type?: unknown }>()
    .catch(() => null);
  if (
    !body ||
    typeof body.audio !== "string" ||
    typeof body.mime_type !== "string"
  ) {
    return c.json({ error: "Missing or invalid {audio, mime_type}" }, 400);
  }

  // 2. Base64-decode `audio`. atob throws on illegal base64 — catch and 400.
  let audioBytes: Uint8Array;
  try {
    const bin = atob(body.audio);
    audioBytes = Uint8Array.from(bin, (ch) => ch.charCodeAt(0));
  } catch {
    return c.json({ error: "audio must be valid base64" }, 400);
  }
  if (audioBytes.byteLength === 0) {
    return c.json({ error: "Empty audio data" }, 400);
  }

  // 3. Whitelist mime_type — fall back to audio/webm for unknown types so a
  // misconfigured client cannot tunnel an arbitrary Content-Type upstream.
  const validatedMimeType = ALLOWED_TRANSCRIBE_MIME_TYPES.has(body.mime_type)
    ? body.mime_type
    : "audio/webm";

  // 4. Forward to Deepgram with raw decoded bytes.
  const dgAbort = new AbortController();
  const dgTimeout = setTimeout(() => dgAbort.abort(), 30_000);
  let dgResponse: Response;
  try {
    dgResponse = await fetch(
      "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&punctuate=true&language=en",
      {
        method: "POST",
        headers: {
          Authorization: `Token ${c.env.DEEPGRAM_KEY}`,
          "Content-Type": validatedMimeType,
        },
        body: audioBytes,
        signal: dgAbort.signal,
      },
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

  const result = (await dgResponse.json()) as any;
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
