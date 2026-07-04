import { Hono } from "hono";
import { Effect } from "effect";
import { eq } from "drizzle-orm";

import { user } from "@rishi/shared";
import {
  verifyRefreshToken,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
} from "../jwt";
import { findOrCreateUser } from "../findOrCreateUser";
import { createDb, WorkerDb } from "../db/drizzle";
import { createRemoteJWKSet, jwtVerify } from "jose";

const authRoutes = new Hono<{
  Bindings: Env;
  Variables: {
    db: WorkerDb;
  };
}>();
authRoutes.post("/apple", async (c) => {
  const appleJWKS = createRemoteJWKSet(
    new URL("https://appleid.apple.com/auth/keys"),
  );
  const { identityToken } = await c.req.json<{
    identityToken: string;
  }>();

  if (!identityToken) {
    return c.json(
      {
        error: "Missing identity token",
      },
      400,
    );
  }

  try {
    const { payload } = await jwtVerify(identityToken, appleJWKS, {
      issuer: "https://appleid.apple.com",

      // Your iOS Bundle Identifier
      audience: "org.fidexa.rishi",
    });
    const db = createDb(c.env.DB);
    const userId = await Effect.runPromise(
      findOrCreateUser(db, {
        sub: payload.sub!,
        email: (payload.email as string) || "${payload.sub}@apple.com",
        email_verified:
          payload.email_verified === true || payload.email_verified === "true",
        is_private_email:
          payload.is_private_email === true ||
          payload.is_private_email === "true",
      }),
    );

    const accessToken = await Effect.runPromise(
      signAccessToken(c.env, {
        userId: userId,
      }),
    );

    const refreshToken = await Effect.runPromise(
      signRefreshToken(c.env, {
        userId: userId,
      }),
    );

    return c.json({
      accessToken,
      refreshToken,
      userId: userId,
    });
  } catch (err) {
    console.error(err);

    return c.json(
      {
        error: "Invalid Apple identity token",
      },
      401,
    );
  }
});
authRoutes.post("/refresh", async (c) => {
  const db = createDb(c.env.DB);

  const { refreshToken } = await c.req.json<{
    refreshToken: string;
  }>();

  const result = await Effect.runPromiseExit(
    Effect.gen(function* () {
      const payload = yield* verifyRefreshToken(c.env, refreshToken);

      const existingUser = yield* Effect.tryPromise(() =>
        db.query.user.findFirst({
          where: eq(user.id, payload.userId),
        }),
      );

      if (!existingUser) {
        return yield* Effect.fail(new Error("User not found"));
      }

      const accessToken = yield* signAccessToken(c.env, {
        userId: existingUser.id,
      });

      const newRefreshToken = yield* signRefreshToken(c.env, {
        userId: existingUser.id,
      });

      return {
        accessToken,
        refreshToken: newRefreshToken,
      };
    }),
  );

  if (result._tag === "Failure") {
    return c.json(
      {
        error: "Invalid refresh token",
      },
      401,
    );
  }

  return c.json(result.value);
});

authRoutes.post("/verify", async (c) => {
  const { token } = await c.req.json<{
    token: string;
  }>();

  if (!token) {
    return c.json(
      {
        error: "Missing token",
      },
      400,
    );
  }

  try {
    const payload = await Effect.runPromise(verifyAccessToken(c.env, token));
    return c.json({ payload });
  } catch (error) {
    console.error(error);

    return c.json(
      {
        valid: false,
        error: error instanceof Error ? error.name : "UnknownError",
        message: error instanceof Error ? error.message : String(error),
      },
      401,
    );
  }
});

export default authRoutes;
