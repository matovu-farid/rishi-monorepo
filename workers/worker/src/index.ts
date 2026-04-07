import axios, { AxiosError } from "axios";
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

export interface CloudflareBindings {
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  CLERK_SECRET_KEY: string;
  CLERK_PUBLISHABLE_KEY: string;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
  JWT_SECRET: string;
  DB: D1Database;
  BOOK_STORAGE: R2Bucket;
  R2_ACCESS_KEY_ID: string;
  R2_SECRET_ACCESS_KEY: string;
  CLOUDFLARE_ACCOUNT_ID: string;
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
  const clerkUser = await clerkClient.users.getUser(userId);

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
  try {
    const body = await c.req.json<{ state: string; code_verifier: string }>();
    const { state, code_verifier } = body;

    if (!state || !code_verifier) {
      return c.json({ error: "Missing state or code_verifier" }, 400);
    }

    const redis = Redis.fromEnv(c.env);
    const redisKey = `auth:state:${state}`;

    // Look up auth flow data from Redis
    const rawData = await redis.get(redisKey);
    if (!rawData) {
      return c.json({ error: "Auth state not found or expired" }, 404);
    }

    // Parse the stored auth flow data
    const authData = typeof rawData === "string" ? JSON.parse(rawData) : rawData as {
      userId: string;
      status: string;
      retryCount?: number;
      createdAt?: number;
      codeChallenge?: string;
    };

    if (!authData.userId) {
      return c.json({ error: "Invalid auth state data" }, 400);
    }

    // If already completed, prevent replay
    if (authData.status === "completed") {
      return c.json({ error: "Auth state already used" }, 409);
    }

    // If another exchange is in progress, signal retry
    if (authData.status === "exchanging") {
      return c.json({ error: "Token exchange in progress" }, 409);
    }

    // Verify PKCE code_challenge if one was stored
    if (authData.codeChallenge) {
      const encoded = new TextEncoder().encode(code_verifier);
      const hashBuffer = await crypto.subtle.digest("SHA-256", encoded);
      const hashArray = Array.from(new Uint8Array(hashBuffer));
      const computedChallenge = hashArray
        .map((b) => b.toString(16).padStart(2, "0"))
        .join("");

      if (computedChallenge !== authData.codeChallenge) {
        return c.json({ error: "PKCE verification failed" }, 403);
      }
    }

    // Mark as exchanging to prevent concurrent attempts
    await redis.set(redisKey, JSON.stringify({
      ...authData,
      status: "exchanging",
    }), { ex: 600 });

    // Fetch user from Clerk and issue JWT
    const clerkClient = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
    const clerkUser = await clerkClient.users.getUser(authData.userId);

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

    return c.json({ token, expiresAt: exp, user });
  } catch (error) {
    if (error instanceof Error) {
      return c.json({ error: "Auth completion failed: " + error.message }, 500);
    }
    return c.json({ error: "Auth completion failed" }, 500);
  }
});

// ─── GET /api/auth/status/:state ────────────────────────────────────────────
// Check auth flow status from Redis for monitoring and retry decisions.
app.get("/api/auth/status/:state", async (c) => {
  try {
    const state = c.req.param("state");
    if (!state) {
      return c.json({ error: "Missing state parameter" }, 400);
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
    };

    return c.json({
      status: authData.status || "unknown",
      retryCount: authData.retryCount || 0,
      createdAt: authData.createdAt || null,
    });
  } catch (error) {
    if (error instanceof Error) {
      return c.json({ error: "Status check failed: " + error.message }, 500);
    }
    return c.json({ error: "Status check failed" }, 500);
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
    if (error instanceof Error) {
      return c.json({ error: "Revocation failed: " + error.message }, 500);
    }
    return c.json({ error: "Revocation failed" }, 500);
  }
});

// ─── Protected routes ─────────────────────────────────────────────────────────
app.get("/api/redis-test", requireWorkerAuth, async (c) => {
  const redis = Redis.fromEnv(c.env);
  await redis.set("foo", "bar");
  const value = await redis.get("foo");
  return c.json({ value });
});

// Backwards-compatible state route (deprecated)
app.get("api/user/:state", requireWorkerAuth, async (c) => {
  try {
    const redis = Redis.fromEnv(c.env);
    const state = c.req.param("state");
    const userId = (await redis.get(`auth:state:${state}`)) as string | null;
    if (!userId) {
      return c.json({ error: "User not found" }, 404);
    }
    const clerkClient = createClerkClient({
      secretKey: c.env.CLERK_SECRET_KEY,
    });

    const clerkUser = await clerkClient.users.getUser(userId);

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
    if (error instanceof Error) {
      return c.json({ error: "Failed to get user, " + error.message }, 500);
    }
    return c.json({ error: "Failed to get user, " }, 500);
  }
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
  const clerkClient = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
  const users = await clerkClient.users.getUserList();
  return c.json(users);
});

app.get("/api/clerk/user/:userId", requireWorkerAuth, async (c) => {
  try {
    const clerkClient = createClerkClient({
      secretKey: c.env.CLERK_SECRET_KEY,
    });
    const userId = c.req.param("userId");

    const clerkUser = await clerkClient.users.getUser(userId);

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
    if (error instanceof Error) {
      return c.json({ error: "Failed to get user, " + error.message }, 500);
    }
    return c.json({ error: "Failed to get user, " }, 500);
  }
});

app.post("/api/audio/speech", requireWorkerAuth, async (c) => {
  const { model, input, voice, ...otherParams } = await c.req.json();
  const openai = new OpenAI({
    apiKey: c.env.OPENAI_API_KEY,
  });
  const response = await openai.audio.speech.create({
    model: "tts-1",
    input,
    voice,
    ...otherParams,
  });
  return response;
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
      }
    );
    const responseSchema = z.object({
      value: z.string(),
      expires_at: z.number(),
    });
    const parsedResponse = responseSchema.parse(response.data);
    return c.json({ client_secret: { value: parsedResponse.value } });
  } catch (error) {
    if (error instanceof z.ZodError) {
      return c.json(
        { error: "Failed to get client secrets, " + error.message },
        500
      );
    }
    if (error instanceof AxiosError) {
      return c.json(
        {
          error:
            "Failed to get client secrets, " +
            error.response?.data.error.message,
        },
        500
      );
    }
    if (error instanceof Error) {
      return c.json(
        { error: "Failed to get client secrets, " + error.message },
        500
      );
    }
    return c.json({ error: "Failed to get client secrets, " }, 500);
  }
});

app.post("/api/text/completions", requireWorkerAuth, async (c) => {
  const { input, ...otherParams } = await c.req.json();
  const openai = new OpenAI({
    apiKey: c.env.OPENAI_API_KEY,
  });
  const response = await openai.responses.create({
    model: "gpt-5-nano",
    input,
    ...otherParams,
  });

  return c.json(response.output_text);
});

// ─── POST /api/embed — Server-side embedding fallback ────────────────────────
app.post("/api/embed", requireWorkerAuth, async (c) => {
  const body = await c.req.json<{ texts: string[] }>();

  if (!body.texts || body.texts.length === 0) {
    return c.json({ error: "texts array is required and must not be empty" }, 400);
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

  const dgResponse = await fetch(
    "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true&punctuate=true&language=en",
    {
      method: "POST",
      headers: {
        "Authorization": `Token ${c.env.DEEPGRAM_KEY}`,
        "Content-Type": contentType,
      },
      body: audioData,
    }
  );

  if (!dgResponse.ok) {
    const errorText = await dgResponse.text();
    console.error("Deepgram error:", dgResponse.status, errorText);
    return c.json({ error: "Transcription failed" }, 502);
  }

  const result = await dgResponse.json() as any;
  const transcript =
    result?.results?.channels?.[0]?.alternatives?.[0]?.transcript || "";

  return c.json({ transcript });
});

export default Sentry.withSentry((env: any) => {
  const { id: versionId } = env.CF_VERSION_METADATA;
  return {
    dsn: "https://94fe4a61653475c40e733e93a9479596@o4510586781958144.ingest.de.sentry.io/4510588453584976",
    release: versionId,
    // Adds request headers and IP for users, for more info visit:
    // https://docs.sentry.io/platforms/javascript/guides/cloudflare/configuration/options/#sendDefaultPii
    sendDefaultPii: true,
    enableLogs: true,
  };
}, app);

// export default app;
