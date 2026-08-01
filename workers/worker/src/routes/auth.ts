import { Hono } from "hono";
import { Effect } from "effect";
import { eq } from "drizzle-orm";

import {
  verifyRefreshToken,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
} from "../jwt";
import { findOrCreateUser } from "../findOrCreateUser";
import { createDb, WorkerDb } from "../db/drizzle";
import { appleUsers } from "../db/schema";
import { encryptSiwaRefreshToken } from "../siwa-token-crypto";
import { mintAppleClientSecret } from "../auth-apple-secret";
import { createRemoteJWKSet, jwtVerify } from "jose";
import {
  AppleBucket,
  verifySignedTransaction,
} from "../apple-connect/functions";

const authRoutes = new Hono<{
  Bindings: Env;
  Variables: {
    db: WorkerDb;
  };
}>();

async function exchangeAppleAuthorizationCode(
  env: Env,
  authorizationCode: string,
): Promise<string> {
  const clientSecret = await mintAppleClientSecret({
    APPLE_SIWA_PRIVATE_KEY: env.APPLE_SIWA_PRIVATE_KEY,
    APPLE_SIWA_KEY_ID: env.APPLE_SIWA_KEY_ID,
    APPLE_TEAM_ID: env.APPLE_TEAM_ID,
    APPLE_SIWA_CLIENT_ID: env.APPLE_SIWA_CLIENT_ID,
  });
  const response = await fetch("https://appleid.apple.com/auth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: env.APPLE_SIWA_CLIENT_ID,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  });
  if (!response.ok) throw new Error(`Apple authorization exchange failed (${response.status})`);
  const payload = await response.json() as { refresh_token?: string };
  if (!payload.refresh_token) throw new Error("Apple authorization exchange returned no refresh token");
  return payload.refresh_token;
}

function decodeAppleAuthorizationCode(encodedAuthorizationCode: string): string {
  try {
    const binary = atob(encodedAuthorizationCode);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const decoded = new TextDecoder().decode(bytes);
    if (!decoded) throw new Error("empty authorization code");
    return decoded;
  } catch {
    throw new Error("Invalid Apple authorization code encoding");
  }
}

authRoutes.post("/apple", async (c) => {
  const appleJWKS = createRemoteJWKSet(
    new URL("https://appleid.apple.com/auth/keys"),
  );
  const { identityToken, authorizationCode } = await c.req.json<{
    identityToken: string;
    authorizationCode?: string;
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
    const existingAppleUser = await db.select({
      userId: appleUsers.userId,
      hasRefreshToken: appleUsers.siwaRefreshTokenCiphertext,
    })
      .from(appleUsers)
      .where(eq(appleUsers.appleUserId, payload.sub!))
      .get();

    if (!existingAppleUser && !authorizationCode) {
      return c.json({ error: "Missing Apple authorization code" }, 400);
    }

    if (existingAppleUser && !authorizationCode) {
      console.info("apple sign-in legacy authorization path", {
        revocationTokenPresent: Boolean(existingAppleUser.hasRefreshToken),
      });
    }

    // New accounts must retain the SIWA refresh token so deletion can revoke
    // the Apple authorization. Do not create an account that can never meet
    // that requirement because the encryption secret is absent.
    if (!existingAppleUser && !c.env.SIWA_TOKEN_ENCRYPTION_SECRET) {
      return c.json({ error: "Apple sign-in is temporarily unavailable" }, 503);
    }

    let siwaRefreshToken: string | undefined;
    if (authorizationCode) {
      try {
        const decodedAuthorizationCode = decodeAppleAuthorizationCode(authorizationCode);
        siwaRefreshToken = await exchangeAppleAuthorizationCode(c.env, decodedAuthorizationCode);
      } catch (error) {
        console.error("Apple authorization exchange failed", error);
        return c.json({ error: "Could not complete Apple sign-in. Please try again." }, 502);
      }
    }
    const user = await Effect.runPromise(
      findOrCreateUser(db, {
        sub: payload.sub!,
        email: (payload.email as string) || `${payload.sub}@apple.com`,
        email_verified:
          payload.email_verified === true || payload.email_verified === "true",
        is_private_email:
          payload.is_private_email === true ||
          payload.is_private_email === "true",
      }),
    );

    if (siwaRefreshToken && c.env.SIWA_TOKEN_ENCRYPTION_SECRET) {
      const encrypted = await encryptSiwaRefreshToken(
        siwaRefreshToken,
        c.env.SIWA_TOKEN_ENCRYPTION_SECRET,
      );
      await db.update(appleUsers)
        .set({
          siwaRefreshTokenCiphertext: encrypted.ciphertext,
          siwaRefreshTokenNonce: encrypted.nonce,
          updatedAt: new Date(),
        })
        .where(eq(appleUsers.userId, user.id));
    }

    const accessToken = await Effect.runPromise(
      signAccessToken(c.env, {
        userId: user.id,
      }),
    );

    const refreshToken = await Effect.runPromise(
      signRefreshToken(c.env, {
        userId: user.id,
      }),
    );

    return c.json({
      accessToken,
      refreshToken,
      userId: user.id,
      user: {
        id: user.id,
        email: user.email,
        name: user.name,
      },
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
          where: { id: payload.userId },
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

authRoutes.post("/verify-transaction", async (c) => {
  const { transactionId } = await c.req.json<{
    transactionId: string;
  }>();

  if (transactionId === undefined) {
    return c.json(
      {
        error: "Missing signedTransaction",
      },
      400,
    );
  }

  const result = await Effect.runPromiseExit(
    verifySignedTransaction(transactionId).pipe(
      Effect.provideService(AppleBucket, c.env.APPLE),
    ),
  );

  if (result._tag === "Failure") {
    return c.json(
      {
        verified: false,
        error: "Invalid transaction",
      },
      401,
    );
  }

  return c.json({
    verified: true,
    transaction: result.value,
  });
});

export default authRoutes;
