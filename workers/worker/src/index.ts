import axios from "axios";
import { Hono } from "hono";
import { cors } from "hono/cors";

import { OpenAI } from "openai";
import { z } from "zod";
import { createClerkClient } from "@clerk/backend";
import * as Sentry from "@sentry/cloudflare";
import { Redis } from "@upstash/redis/cloudflare";
import { clerkMiddleware, getAuth } from "@hono/clerk-auth";
import jwt from "@tsndr/cloudflare-worker-jwt";
import { syncRoutes } from "./routes/sync";
import { uploadRoutes } from "./routes/upload";

/** UUID v4 format validation for state parameters used as Redis keys. */
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Constant-time string comparison to prevent timing attacks on PKCE challenges. */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  // crypto.subtle.timingSafeEqual is available in Cloudflare Workers
  return crypto.subtle.timingSafeEqual(bufA, bufB);
}

export interface CloudflareBindings {
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  CLERK_SECRET_KEY: string;
  CLERK_PUBLISHABLE_KEY: string;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  JWT_SECRET: string;
  DEV_BYPASS_SECRET?: string;
  SENTRY_DSN?: string;
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
}

/** Wrap an async function with a timeout via Promise.race. */
async function withTimeout<T>(fn: () => Promise<T>, ms: number = 10000): Promise<T> {
  return Promise.race([
    fn(),
    new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error(`Operation timed out after ${ms}ms`)), ms)
    ),
  ]);
}

const app = new Hono<{ Bindings: CloudflareBindings; Variables: { userId: string } }>();

// CORS must come before clerkMiddleware
app.use(
  "*",
  cors({
    origin: ["https://rishi.fidexa.org", "tauri://localhost", "http://tauri.localhost"],
    allowHeaders: ["Content-Type", "Authorization"],
    allowMethods: ["GET", "POST", "OPTIONS"],
  })
);

app.use("*", clerkMiddleware());

app.get("/", (c) => {
  return c.text("Hello Hono!");
});

// ─── Sync routes ─────────────────────────────────────────────────────────────
app.route("/api/sync", syncRoutes);
app.route("/api/sync", uploadRoutes);

// ─── requireWorkerAuth middleware ────────────────────────────────────────────
export async function requireWorkerAuth(c: any, next: () => Promise<void>) {
  // Dev bypass: skip JWT validation when the client sends the dev secret.
  // Set DEV_BYPASS_SECRET as a Cloudflare Worker secret to enable this.
  const devSecret = c.env.DEV_BYPASS_SECRET;
  if (devSecret) {
    const devHeader = c.req.header("X-Dev-Bypass");
    if (devHeader && timingSafeEqual(devHeader, devSecret)) {
      c.set("userId", "dev-user");
      return next();
    }
  }

  const authHeader = c.req.header("Authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const token = authHeader.slice(7);
  try {
    const isValid = await jwt.verify(token, c.env.JWT_SECRET);
    if (!isValid) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    const decoded = jwt.decode(token);
    const payload = decoded?.payload as { sub?: string; exp?: number } | undefined;
    if (!payload?.sub) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    // Check expiry manually
    const now = Math.floor(Date.now() / 1000);
    if (payload.exp && payload.exp < now) {
      return c.json({ error: "Token expired" }, 401);
    }
    // Check if the token has been revoked
    const redis = Redis.fromEnv(c.env);
    const isRevoked = await redis.get(`auth:revoked:${token}`);
    if (isRevoked) {
      return c.json({ error: "Token revoked" }, 401);
    }

    c.set("userId", payload.sub);
  } catch {
    return c.json({ error: "Unauthorized" }, 401);
  }
  await next();
}

// ─── POST /api/auth/exchange ─────────────────────────────────────────────────
app.post("/api/auth/exchange", async (c) => {
  const auth = getAuth(c);
  if (!auth?.userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const userId = auth.userId;

  const clerkClient = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
  const clerkUser = await withTimeout(() => clerkClient.users.getUser(userId));

  const iat = Math.floor(Date.now() / 1000);
  const exp = iat + 60 * 60 * 24 * 7; // 7 days

  const token = await jwt.sign({ sub: userId, iat, exp }, c.env.JWT_SECRET);

  const user = {
    id: clerkUser.id,
    firstName: clerkUser.firstName,
    lastName: clerkUser.lastName,
    fullName: clerkUser.fullName,
    username: clerkUser.username,
    imageUrl: clerkUser.imageUrl,
    hasImage: clerkUser.hasImage,
    lastSignInAt: clerkUser.lastSignInAt,
    externalId: clerkUser.externalId,
  };

  return c.json({ token, expiresAt: exp, user });
});

// ─── POST /api/auth/complete ────────────────────────────────────────────────
// Desktop PKCE auth completion: looks up userId from Redis using state,
// verifies code_verifier against stored code_challenge, issues a JWT.
app.post("/api/auth/complete", async (c) => {
  const redis = Redis.fromEnv(c.env);

  // Helper to log debug events for this auth flow
  const debugLog = async (state: string, step: string, data?: unknown, error?: string) => {
    try {
      const now = Date.now();
      await redis.rpush(
        `auth:debug:${state}`,
        JSON.stringify({ source: "worker", step, data: data ?? null, error: error ?? null, timestamp: now, ts: new Date().toISOString() })
      );
      await redis.expire(`auth:debug:${state}`, 7200);
      await redis.zadd("auth:debug:_index", { score: now, member: state });
      await redis.expire("auth:debug:_index", 7200);
    } catch { /* best-effort */ }
  };

  let state = "unknown";
  try {
    const body = await c.req.json<{ state: string; code_verifier: string }>();
    state = body.state || "unknown";
    const { code_verifier } = body;

    await debugLog(state, "complete_called", { hasState: !!body.state, hasVerifier: !!code_verifier, verifierLen: code_verifier?.length });

    if (!state || state === "unknown" || !code_verifier) {
      await debugLog(state, "complete_rejected_missing_params");
      return c.json({ error: "Authentication failed" }, 400);
    }

    if (!UUID_RE.test(state)) {
      return c.json({ error: "Invalid state parameter" }, 400);
    }

    const redisKey = `auth:state:${state}`;

    // Look up auth flow data from Redis
    const rawData = await redis.get(redisKey);
    if (!rawData) {
      await debugLog(state, "complete_state_not_found", { redisKey });
      return c.json({ error: "Authentication failed" }, 400);
    }

    await debugLog(state, "complete_state_found", { rawDataType: typeof rawData });

    // Parse the stored auth flow data
    const authData = typeof rawData === "string" ? JSON.parse(rawData) : rawData as {
      userId: string;
      status: string;
      retryCount?: number;
      createdAt?: number;
      codeChallenge?: string;
    };

    await debugLog(state, "complete_parsed_state", {
      userId: authData.userId ? authData.userId.slice(0, 10) + "..." : null,
      status: authData.status,
      hasCodeChallenge: !!authData.codeChallenge,
      challengeLen: authData.codeChallenge?.length,
      createdAt: authData.createdAt,
      ageMs: authData.createdAt ? Date.now() - authData.createdAt : null,
    });

    if (!authData.userId) {
      await debugLog(state, "complete_no_userId");
      return c.json({ error: "Authentication failed" }, 400);
    }

    // If already completed, prevent replay
    if (authData.status === "completed") {
      await debugLog(state, "complete_already_used");
      return c.json({ error: "Authentication failed" }, 400);
    }

    // If another exchange is in progress, signal retry
    if (authData.status === "exchanging") {
      await debugLog(state, "complete_already_exchanging");
      return c.json({ error: "Authentication failed" }, 409);
    }

    // Atomically mark as "exchanging" before PKCE verification to close TOCTOU window
    await redis.set(redisKey, JSON.stringify({ ...authData, status: "exchanging" }), { ex: 600 });

    // PKCE is mandatory — reject if no code_challenge was stored
    if (!authData.codeChallenge) {
      await debugLog(state, "complete_missing_pkce_challenge");
      return c.json({ error: "Authentication failed" }, 400);
    }

    // Verify PKCE code_challenge (timing-safe comparison)
    // Support both base64url (RFC 7636, current) and hex (legacy pre-v1.3.7 clients)
    const encoded = new TextEncoder().encode(code_verifier);
    const hashBuffer = await crypto.subtle.digest("SHA-256", encoded);
    const hashBytes = new Uint8Array(hashBuffer);

    // RFC 7636 base64url encoding (43 chars)
    const base64urlChallenge = btoa(String.fromCharCode(...hashBytes))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");

    // Legacy hex encoding (64 chars, used by desktop app <= v1.3.6)
    const hexChallenge = Array.from(hashBytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");

    // Match against whichever encoding the stored challenge uses
    const storedLen = authData.codeChallenge.length;
    const computedChallenge = storedLen === 64 ? hexChallenge : base64urlChallenge;

    const pkceMatch = timingSafeEqual(computedChallenge, authData.codeChallenge);
    await debugLog(state, "complete_pkce_check", {
      computedLen: computedChallenge.length,
      storedLen,
      match: pkceMatch,
      encoding: storedLen === 64 ? "hex-legacy" : "base64url",
      computedPrefix: computedChallenge.slice(0, 8),
      storedPrefix: authData.codeChallenge.slice(0, 8),
    });

    if (!pkceMatch) {
      // Increment retry counter and reject after max retries to prevent brute-force
      const retryCount = (authData.retryCount || 0) + 1;
      if (retryCount > 5) {
        await redis.set(redisKey, JSON.stringify({ ...authData, status: "failed" }), { ex: 600 });
        return c.json({ error: "Too many PKCE verification attempts" }, 429);
      }
      await redis.set(redisKey, JSON.stringify({ ...authData, status: "authenticated", retryCount }), { ex: 600 });
      return c.json({ error: "PKCE verification failed" }, 403);
    }

    await debugLog(state, "complete_fetching_clerk_user", { userId: authData.userId.slice(0, 10) + "..." });

    // Fetch user from Clerk and issue JWT
    const clerkClient = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
    const clerkUser = await withTimeout(() => clerkClient.users.getUser(authData.userId));

    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + 60 * 60 * 24 * 7; // 7 days

    const token = await jwt.sign({ sub: authData.userId, iat, exp }, c.env.JWT_SECRET);

    const user = {
      id: clerkUser.id,
      firstName: clerkUser.firstName,
      lastName: clerkUser.lastName,
      fullName: clerkUser.fullName,
      username: clerkUser.username,
      imageUrl: clerkUser.imageUrl,
      hasImage: clerkUser.hasImage,
      lastSignInAt: clerkUser.lastSignInAt,
      externalId: clerkUser.externalId,
    };

    // Mark as completed and log success
    await redis.set(redisKey, JSON.stringify({
      ...authData,
      status: "completed",
    }), { ex: 60 }); // Short TTL after completion

    await redis.lpush(`auth:log:${state}`, JSON.stringify({
      step: "token_issued",
      timestamp: Date.now(),
    }));

    await debugLog(state, "complete_success", { userId: user.id.slice(0, 10) + "...", hasToken: !!token });

    return c.json({ token, expiresAt: exp, user });
  } catch (error) {
    const errMsg = error instanceof Error ? error.message : "unknown";
    await debugLog(state, "complete_error", null, errMsg);

    // Reset status back to "authenticated" so retries aren't blocked by "exchanging"
    if (state !== "unknown") {
      try {
        const rawData = await redis.get(`auth:state:${state}`);
        if (rawData) {
          const authData = typeof rawData === "string" ? JSON.parse(rawData) : rawData as Record<string, unknown>;
          if (authData.status === "exchanging") {
            await redis.set(`auth:state:${state}`, JSON.stringify({
              ...authData,
              status: "failed",
              retryCount: ((authData.retryCount as number) || 0) + 1,
            }), { ex: 600 });
            await debugLog(state, "complete_status_reset_to_failed");
          }
        }
      } catch { /* best-effort */ }
    }

    return c.json({ error: "Authentication failed" }, 500);
  }
});

// ─── POST /api/auth/status/:state ───────────────────────────────────────────
// Check auth flow status from Redis for monitoring and retry decisions.
app.post("/api/auth/status/:state", requireWorkerAuth, async (c) => {
  try {
    const state = c.req.param("state");
    if (!state) {
      return c.json({ error: "Missing state parameter" }, 400);
    }

    if (!UUID_RE.test(state)) {
      return c.json({ error: "Invalid state parameter" }, 400);
    }

    const body = await c.req.json<{ code_challenge?: string }>();
    const codeChallenge = body.code_challenge;
    if (!codeChallenge) {
      return c.json({ error: "Missing code_challenge" }, 400);
    }

    const redis = Redis.fromEnv(c.env);
    const rawData = await redis.get(`auth:state:${state}`);

    if (!rawData) {
      return c.json({ status: "not_found" });
    }

    const authData = typeof rawData === "string" ? JSON.parse(rawData) : rawData as {
      userId?: string;
      status?: string;
      retryCount?: number;
      createdAt?: number;
      codeChallenge?: string;
    };

    // Verify the code_challenge matches the stored one (timing-safe)
    if (authData.codeChallenge && !timingSafeEqual(authData.codeChallenge, codeChallenge ?? "")) {
      return c.json({ error: "Invalid code_challenge" }, 403);
    }

    return c.json({
      status: authData.status || "unknown",
    });
  } catch (error) {
    console.error("Status check failed:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Status check failed" }, 500);
  }
});

// ─── POST /api/auth/debug ───────────────────────────────────────────────────
// Log a debug event to Redis for auth flow tracing.
// Each event is stored in a list keyed by state UUID.
// A global index tracks all known states for discovery.
app.post("/api/auth/debug", requireWorkerAuth, async (c) => {
  try {
    const body = await c.req.json<{
      state: string;
      source: string;
      step: string;
      data?: unknown;
      error?: string;
    }>();

    if (!body.state || !body.source || !body.step) {
      return c.json({ error: "Missing state, source, or step" }, 400);
    }

    if (!UUID_RE.test(body.state)) {
      return c.json({ error: "Invalid state parameter" }, 400);
    }

    const redis = Redis.fromEnv(c.env);
    const key = `auth:debug:${body.state}`;
    const now = Date.now();

    await redis.rpush(
      key,
      JSON.stringify({
        source: body.source,
        step: body.step,
        data: body.data ?? null,
        error: body.error ?? null,
        timestamp: now,
        ts: new Date().toISOString(),
      })
    );
    await redis.expire(key, 7200); // 2 hour TTL

    // Track this state in a global index so we can list all recent flows
    // Use a sorted set with timestamp as score for easy chronological listing
    await redis.zadd("auth:debug:_index", { score: now, member: body.state });
    await redis.expire("auth:debug:_index", 7200);

    return c.json({ ok: true });
  } catch (error) {
    return c.json({ error: "Debug log failed" }, 500);
  }
});

// ─── GET /api/auth/debug — list all recent auth flows ───────────────────────
// Returns the most recent auth flows from the global index with summary info.
app.get("/api/auth/debug", requireWorkerAuth, async (c) => {
  try {
    const redis = Redis.fromEnv(c.env);

    // Get the 20 most recent flows (highest score = most recent)
    const entries = await redis.zrange("auth:debug:_index", 0, 19, { rev: true, withScores: true }) as (string | number)[];

    // entries comes back as [member, score, member, score, ...]
    const flows: { state: string; startedAt: string; eventCount: number; lastStep: string | null; authStatus: string | null; hasError: boolean }[] = [];

    for (let i = 0; i < entries.length; i += 2) {
      const state = String(entries[i]);
      const score = Number(entries[i + 1]);

      // Get summary info for each flow
      const eventCount = await redis.llen(`auth:debug:${state}`);
      const lastEventRaw = await redis.lindex(`auth:debug:${state}`, -1);
      let lastStep: string | null = null;
      let hasError = false;
      if (lastEventRaw) {
        try {
          const parsed = typeof lastEventRaw === "string" ? JSON.parse(lastEventRaw) : lastEventRaw as { step?: string; error?: string | null };
          lastStep = parsed.step ?? null;
          hasError = !!parsed.error;
        } catch { /* ignore */ }
      }

      // Check auth state status
      const rawAuthState = await redis.get(`auth:state:${state}`);
      let authStatus: string | null = null;
      if (rawAuthState) {
        try {
          const parsed = typeof rawAuthState === "string" ? JSON.parse(rawAuthState) : rawAuthState as { status?: string };
          authStatus = parsed.status ?? null;
        } catch { /* ignore */ }
      }

      flows.push({
        state,
        startedAt: new Date(score).toISOString(),
        eventCount,
        lastStep,
        authStatus,
        hasError,
      });
    }

    return c.json({ flows, count: flows.length });
  } catch (error) {
    console.error("Debug list failed:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Debug list failed" }, 500);
  }
});

// ─── GET /api/auth/debug/:state ─────────────────────────────────────────────
// Retrieve all debug events and auth state for a given state UUID.
app.get("/api/auth/debug/:state", requireWorkerAuth, async (c) => {
  try {
    const state = c.req.param("state");
    if (!state) {
      return c.json({ error: "Missing state" }, 400);
    }

    if (!UUID_RE.test(state)) {
      return c.json({ error: "Invalid state parameter" }, 400);
    }

    const redis = Redis.fromEnv(c.env);
    const events = await redis.lrange(`auth:debug:${state}`, 0, -1);
    const rawAuthState = await redis.get(`auth:state:${state}`);
    const authLog = await redis.lrange(`auth:log:${state}`, 0, -1);

    // Parse events (they're stored as JSON strings)
    const parsedEvents = events.map((e: unknown) => {
      if (typeof e === "string") {
        try { return JSON.parse(e); } catch { return e; }
      }
      return e;
    });

    const parsedLog = authLog.map((e: unknown) => {
      if (typeof e === "string") {
        try { return JSON.parse(e); } catch { return e; }
      }
      return e;
    });

    let authState = null;
    if (rawAuthState) {
      authState = typeof rawAuthState === "string" ? JSON.parse(rawAuthState) : rawAuthState;
      // Redact sensitive fields
      if (authState.codeChallenge) {
        authState.codeChallenge = authState.codeChallenge.slice(0, 8) + "...";
      }
    }

    return c.json({
      state,
      authState,
      debugEvents: parsedEvents,
      authLog: parsedLog,
    });
  } catch (error) {
    console.error("Debug fetch failed:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Debug fetch failed" }, 500);
  }
});

// ─── POST /api/auth/revoke ──────────────────────────────────────────────────
// Invalidate a desktop JWT by adding it to a Redis deny-list.
// Best-effort: the desktop client calls this on sign-out.
app.post("/api/auth/revoke", async (c) => {
  try {
    const authHeader = c.req.header("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    const token = authHeader.slice(7);

    // Verify the JWT signature before revoking
    const isValid = await jwt.verify(token, c.env.JWT_SECRET);
    if (!isValid) {
      return c.json({ error: "Invalid token" }, 401);
    }

    // Decode to get expiry so we can set an appropriate TTL on the revocation entry
    let exp = 0;
    try {
      const decoded = jwt.decode(token);
      const payload = decoded?.payload as { sub?: string; exp?: number } | undefined;
      exp = payload?.exp || 0;
    } catch {
      // If we can't decode, still attempt to revoke
    }

    const redis = Redis.fromEnv(c.env);

    // Store the token in a revocation list with TTL matching token expiry
    const now = Math.floor(Date.now() / 1000);
    const ttl = exp > now ? exp - now : 60 * 60 * 24 * 7; // Default 7 days if no expiry
    await redis.set(`auth:revoked:${token}`, "1", { ex: ttl });

    return c.json({ success: true });
  } catch (error) {
    console.error("Revocation failed:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Revocation failed" }, 500);
  }
});

// ─── POST /api/auth/refresh ─────────────────────────────────────────────────
// Refresh a valid (but possibly near-expiry) JWT with a fresh one.
// The old token is revoked to prevent reuse.
app.post("/api/auth/refresh", requireWorkerAuth, async (c) => {
  try {
    const userId = c.get("userId");
    const oldToken = c.req.header("Authorization")!.slice(7);

    // Revoke old token FIRST to prevent reuse — if this fails, we never
    // issue a new token, avoiding a window where both tokens are valid.
    const redis = Redis.fromEnv(c.env);
    const decoded = jwt.decode(oldToken);
    const oldExp = (decoded?.payload as { exp?: number })?.exp || 0;
    const now = Math.floor(Date.now() / 1000);
    const ttl = oldExp > now ? oldExp - now : 60 * 60 * 24 * 7;
    await redis.set(`auth:revoked:${oldToken}`, "1", { ex: ttl });

    // Issue new token only after old one is revoked
    const iat = Math.floor(Date.now() / 1000);
    const exp = iat + 60 * 60 * 24 * 7; // 7 days
    const token = await jwt.sign({ sub: userId, iat, exp }, c.env.JWT_SECRET);

    return c.json({ token, expiresAt: exp });
  } catch (error) {
    console.error("Token refresh failed:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Token refresh failed" }, 500);
  }
});

// ─── Protected routes ─────────────────────────────────────────────────────────
app.get("/api/redis-test", requireWorkerAuth, async (c) => {
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

app.get("/api/clerk/users", requireWorkerAuth, async (c) => {
  return c.json({ error: "Forbidden" }, 403);
});

app.get("/api/clerk/user/:userId", requireWorkerAuth, async (c) => {
  try {
    const userId = c.req.param("userId");

    // Only allow users to fetch their own data
    if (c.get("userId") !== userId) {
      return c.json({ error: "Forbidden" }, 403);
    }

    const clerkClient = createClerkClient({
      secretKey: c.env.CLERK_SECRET_KEY,
    });

    const clerkUser = await withTimeout(() => clerkClient.users.getUser(userId));

    return c.json({
      id: clerkUser.id,
      firstName: clerkUser.firstName,
      lastName: clerkUser.lastName,
      fullName: clerkUser.fullName,
      username: clerkUser.username,
      imageUrl: clerkUser.imageUrl,
      hasImage: clerkUser.hasImage,
      lastSignInAt: clerkUser.lastSignInAt,
      externalId: clerkUser.externalId,
    });
  } catch (error) {
    console.error("Failed to get user:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Failed to get user" }, 500);
  }
});

app.post("/api/audio/speech", requireWorkerAuth, async (c) => {
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

    const openai = new OpenAI({
      apiKey: c.env.OPENAI_API_KEY,
    });

    const response = await openai.audio.speech.create({
      model: "tts-1",
      input,
      voice: validVoice,
    });

    const arrayBuffer = await response.arrayBuffer();
    return new Response(arrayBuffer, {
      headers: {
        "Content-Type": "audio/mpeg",
        "Content-Length": arrayBuffer.byteLength.toString(),
      },
    });
  } catch (error) {
    if (error instanceof OpenAI.APIError) {
      console.error("OpenAI API error:", error.status, error.message);
      return c.json(
        { error: "TTS generation failed" },
        error.status === 429 ? 429 : 502
      );
    }
    console.error("TTS error:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "TTS generation failed" }, 500);
  }
});

app.get("/api/realtime/client_secrets", requireWorkerAuth, async (c) => {
  try {
    const response = await axios.post(
      "https://api.openai.com/v1/realtime/client_secrets",
      {
        expires_after: {
          anchor: "created_at",
          seconds: 600,
        },
        session: {
          type: "realtime",
          model: "gpt-realtime",
          instructions: "You are a friendly assistant.",
        },
      },
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
    console.error("Failed to get client secrets:", error instanceof Error ? error.message : "unknown");
    return c.json({ error: "Failed to get client secrets" }, 500);
  }
});

app.post("/api/text/completions", requireWorkerAuth, async (c) => {
  try {
    const body = await c.req.json();
    const input = body?.input;
    if (!input || typeof input !== "string" || input.length > 50000) {
      return c.json({ error: "input must be a string under 50000 characters" }, 400);
    }
    const openai = new OpenAI({
      apiKey: c.env.OPENAI_API_KEY,
    });
    const response = await openai.responses.create({
      model: "gpt-5-nano",
      input,
    });

    return c.json(response.output_text);
  } catch (error) {
    if (error instanceof OpenAI.APIError) {
      return c.json({ error: error.message }, (error.status as 400) || 500);
    }
    return c.json({ error: "Internal server error" }, 500);
  }
});

// ─── POST /api/embed — Server-side embedding fallback ────────────────────────
app.post("/api/embed", requireWorkerAuth, async (c) => {
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

  const openai = new OpenAI({
    apiKey: c.env.OPENAI_API_KEY,
  });

  const response = await openai.embeddings.create({
    model: "text-embedding-3-small",
    input: body.texts,
    dimensions: 384, // Match on-device all-MiniLM-L6-v2 dimensions
  });

  const embeddings = response.data
    .sort((a, b) => a.index - b.index)
    .map(item => item.embedding);

  return c.json({ embeddings });
});

// ─── POST /api/audio/transcribe — Deepgram STT proxy ──────────────────────────
app.post("/api/audio/transcribe", requireWorkerAuth, async (c) => {
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
