import axios from "axios";
import { Hono } from "hono";
import { cors } from "hono/cors";

import { OpenAI } from "openai";
import { z } from "zod";
import { createClerkClient } from "@clerk/backend";
import * as Sentry from "@sentry/cloudflare";
import { Redis } from "@upstash/redis/cloudflare";
import { clerkMiddleware, getAuth } from "@hono/clerk-auth";
import { syncRoutes } from "./routes/sync";
import { uploadRoutes } from "./routes/upload";
import { createAuth } from "./auth";

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

app.use("*", clerkMiddleware());

app.get("/", (c) => {
  return c.text("Hello Hono!");
});

// ─── requireClerkAuth middleware ─────────────────────────────────────────────
// Verifies the Clerk session token populated by clerkMiddleware() and exposes
// the Clerk userId via c.get("userId"). Preserves the dev bypass header.
export async function requireClerkAuth(c: any, next: () => Promise<void>) {
  const devSecret = c.env.DEV_BYPASS_SECRET;
  if (devSecret) {
    const devHeader = c.req.header("X-Dev-Bypass");
    if (devHeader && timingSafeEqual(devHeader, devSecret)) {
      c.set("userId", "dev-user");
      return next();
    }
  }

  const auth = getAuth(c);
  if (!auth?.userId) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  c.set("userId", auth.userId);
  await next();
}

// ─── Sync routes ─────────────────────────────────────────────────────────────
app.route("/api/sync", syncRoutes);
app.route("/api/sync", uploadRoutes);

// ─── Protected routes ─────────────────────────────────────────────────────────
app.get("/api/redis-test", requireClerkAuth, async (c) => {
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

app.get("/api/clerk/users", requireClerkAuth, async (c) => {
  return c.json({ error: "Forbidden" }, 403);
});

app.get("/api/clerk/user/:userId", requireClerkAuth, async (c) => {
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

app.post("/api/audio/speech", requireClerkAuth, async (c) => {
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

app.get("/api/realtime/client_secrets", requireClerkAuth, async (c) => {
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

app.post("/api/text/completions", requireClerkAuth, async (c) => {
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
app.post("/api/embed", requireClerkAuth, async (c) => {
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
app.post("/api/audio/transcribe", requireClerkAuth, async (c) => {
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
