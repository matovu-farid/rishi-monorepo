import axios, { AxiosError } from "axios";
import { Hono } from "hono";

import { OpenAI } from "openai";
import { z } from "zod";
import { createClerkClient } from "@clerk/backend";
import * as Sentry from "@sentry/cloudflare";
import { Redis } from "@upstash/redis/cloudflare";
import { clerkMiddleware, getAuth } from "@hono/clerk-auth";

const app = new Hono<{ Bindings: CloudflareBindings }>();
app.use("*", clerkMiddleware());
app.get("/", (c) => {
  return c.text("Hello Hono!");
});

interface CloudflareBindings {
  DEEPGRAM_KEY: string;
  OPENAI_API_KEY: string;
  CLERK_SECRET_KEY: string;
  CLERK_PUBLISHABLE_KEY: string;
  UPSTASH_REDIS_REST_URL: string;
  UPSTASH_REDIS_REST_TOKEN: string;
}

app.get("/api/redis-test", async (c) => {
  const auth = getAuth(c);

  if (!auth?.isAuthenticated) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const redis = Redis.fromEnv(c.env);
  await redis.set("foo", "bar");
  const value = await redis.get("foo");
  return c.json({ value });
});
app.get("api/user/:state", async (c) => {
  try {
    const redis = Redis.fromEnv(c.env);
    const state = c.req.param("state");
    const userId = (await redis.hget("users", state)) as string;
    const clerkClient = createClerkClient({
      secretKey: c.env.CLERK_SECRET_KEY,
    });

    const user = await clerkClient.users.getUser(userId);

    return c.json(user);
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
app.get("/api/clerk/users", async (c) => {
  const clerkClient = createClerkClient({ secretKey: c.env.CLERK_SECRET_KEY });
  const users = await clerkClient.users.getUserList();
  return c.json(users);
});

app.get("/api/clerk/user/:userId", async (c) => {
  try {
    const clerkClient = createClerkClient({
      secretKey: c.env.CLERK_SECRET_KEY,
    });
    const userId = c.req.param("userId");

    const user = await clerkClient.users.getUser(userId);

    return c.json(user);
  } catch (error) {
    if (error instanceof Error) {
      return c.json({ error: "Failed to get user, " + error.message }, 500);
    }
    return c.json({ error: "Failed to get user, " }, 500);
  }
});

// Proxy all requests to /api/openai/* to OpenAI API
// app.use('/api/openai', createProxyMiddleware(openaiProxyOptions))

app.post("/api/audio/speech", async (c) => {
  const auth = getAuth(c);

  if (!auth?.isAuthenticated) {
    Sentry.captureException(new Error("Unauthorized"));
    return c.json({ error: "Unauthorized" }, 401);
  }
  // Validate and fix the request body
  const { model, input, voice, apiKey, ...otherParams } = await c.req.json();
  const openai = new OpenAI({
    apiKey: apiKey || c.env.OPENAI_API_KEY,
  });
  const response = await openai.audio.speech.create({
    model: "tts-1",
    input,
    voice,
    ...otherParams,
  });
  return response;
});

app.get("/api/realtime/client_secrets", async (c) => {
  try {
    const auth = getAuth(c);

    if (!auth?.isAuthenticated) {
      return c.json({ error: "Unauthorized" }, 401);
    }
    //console.log("env", c.env);

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
      },
    );
    const responseSchema = z.object({
      value: z.string(),
      expires_at: z.number(),
    });
    const parsedResponse = responseSchema.parse(response.data);
    return c.text(parsedResponse.value);
  } catch (error) {
    if (error instanceof z.ZodError) {
      return c.json(
        { error: "Failed to get client secrets, " + error.message },
        500,
      );
    }
    if (error instanceof AxiosError) {
      return c.json(
        {
          error:
            "Failed to get client secrets, " +
            error.response?.data.error.message,
        },
        500,
      );
    }
    if (error instanceof Error) {
      return c.json(
        { error: "Failed to get client secrets, " + error.message },
        500,
      );
    }
    return c.json({ error: "Failed to get client secrets, " }, 500);
  }
});

app.post("/api/text/completions", async (c) => {
  const auth = getAuth(c);

  if (!auth?.isAuthenticated) {
    return c.json({ error: "Unauthorized" }, 401);
  }
  const { input, apiKey, ...otherParams } = await c.req.json();
  const openai = new OpenAI({
    apiKey: apiKey || c.env.OPENAI_API_KEY,
  });
  const response = await openai.responses.create({
    model: "gpt-5-nano",
    input,
    ...otherParams,
  });

  return c.json(response.output_text);
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
