import { Hono } from "hono";
import { Effect } from "effect";
import { and, eq, gt, inArray } from "drizzle-orm";

import {
  verifyRefreshToken,
  signAccessToken,
  signRefreshToken,
  verifyAccessToken,
} from "../jwt";
import { findOrCreateUser } from "../findOrCreateUser";
import { createDb, WorkerDb } from "../db/drizzle";
import { allowancePeriod, appleUsers, retainedAppleEntitlement, retainedAppleTransaction, restoredAppleEntitlement } from "../db/schema";
import { encryptSiwaRefreshToken } from "../siwa-token-crypto";
import { mintAppleClientSecret } from "../auth-apple-secret";
import { createRemoteJWKSet, jwtVerify } from "jose";
import {
  AppleBucket,
  verifySignedTransaction,
} from "../apple-connect/functions";
import { hashAppleIdentity } from "../entitlement-retention";
import type { AccountEntitlementSnapshot } from "../durable-objects/user-usage-ledger/types";

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
  if (!response.ok) {
    const body = await response.text();
    throw new Error(
      `Apple authorization exchange failed (${response.status}): ${body.slice(0, 240)}`,
    );
  }
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

function isNonEmptyLedgerConflict(error: unknown): boolean {
  return error instanceof Error && error.message === "cannot restore a non-empty ledger";
}

authRoutes.post("/apple", async (c) => {
  let failureStage = "parse-request";
  const appleJWKS = createRemoteJWKSet(
    new URL("https://appleid.apple.com/auth/keys"),
  );
  const { identityToken, authorizationCode, nonce } = await c.req.json<{
    identityToken: string;
    authorizationCode?: string | null;
    nonce?: string | null;
  }>();

  if (!identityToken) {
    return c.json(
      {
        error: "Missing identity token",
      },
      400,
    );
  }

  console.info("apple sign-in request", {
    hasIdentityToken: Boolean(identityToken),
    identityTokenLength: typeof identityToken === "string" ? identityToken.length : 0,
    hasAuthorizationCode: typeof authorizationCode === "string" && authorizationCode.length > 0,
    hasNonce: typeof nonce === "string" && nonce.length > 0,
  });

  const authorizationCodeValue =
    typeof authorizationCode === "string" ? authorizationCode : undefined;
  if (authorizationCodeValue !== undefined && authorizationCodeValue.trim().length === 0) {
    return c.json({ error: "Invalid Apple authorization code" }, 400);
  }
  const suppliedAuthorizationCode = authorizationCodeValue !== undefined;
  const expectedNonce = typeof nonce === "string" && nonce.length > 0 ? nonce : undefined;
  if (!expectedNonce) {
    return c.json({ error: "Missing Apple sign-in nonce" }, 400);
  }

  try {
    failureStage = "verify-identity-token";
    const jwtOptions = {
      issuer: "https://appleid.apple.com",

      // Your iOS Bundle Identifier
      audience: "org.fidexa.rishi",
      nonce: expectedNonce,
    } as Parameters<typeof jwtVerify>[2];
    const { payload } = await jwtVerify(identityToken, appleJWKS, {
      ...jwtOptions,
    });
    failureStage = "lookup-apple-user";
    const db = createDb(c.env.DB);
    const existingAppleUser = await db.select({
      userId: appleUsers.userId,
      hasRefreshToken: appleUsers.siwaRefreshTokenCiphertext,
    })
      .from(appleUsers)
      .where(eq(appleUsers.appleUserId, payload.sub!))
      .get();

    if (!existingAppleUser && !suppliedAuthorizationCode) {
      console.info("apple sign-in creating account without authorization code", {
        appleSubjectPresent: Boolean(payload.sub),
      });
    }

    if (existingAppleUser && !suppliedAuthorizationCode) {
      console.info("apple sign-in legacy authorization path", {
        revocationTokenPresent: Boolean(existingAppleUser.hasRefreshToken),
      });
    }

    // When configured, exchange an authorization code so its refresh token
    // can be encrypted and retained for revocation during account deletion.
    // If the encryption secret is unavailable, continue with the verified
    // identity-only path rather than blocking account recreation. No token is
    // exchanged or retained in that degraded mode.
    if (suppliedAuthorizationCode && !c.env.SIWA_TOKEN_ENCRYPTION_SECRET) {
      console.warn("apple sign-in proceeding without authorization-code exchange", {
        reason: "SIWA_TOKEN_ENCRYPTION_SECRET is not configured",
      });
    }

    let siwaRefreshToken: string | undefined;
    if (authorizationCodeValue !== undefined && c.env.SIWA_TOKEN_ENCRYPTION_SECRET) {
      failureStage = "exchange-authorization-code";
      try {
        const decodedAuthorizationCode = decodeAppleAuthorizationCode(authorizationCodeValue);
        siwaRefreshToken = await exchangeAppleAuthorizationCode(c.env, decodedAuthorizationCode);
      } catch (error) {
        console.error("Apple authorization exchange failed", error);
        return c.json({
          error: "Could not complete Apple sign-in. Please try again.",
          code: "APPLE_AUTHORIZATION_EXCHANGE_FAILED",
        }, 502);
      }
    }
    failureStage = "find-or-create-user";
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

    failureStage = "restore-retained-entitlements";
    const retentionEnv = c.env as Env & {
      APPLE_IDENTITY_RETENTION_SECRET_CURRENT?: string;
      APPLE_IDENTITY_RETENTION_SECRET_PREVIOUS?: string;
      APPLE_TRANSACTION_HASH_SECRET?: string;
    };
    if (!retentionEnv.APPLE_IDENTITY_RETENTION_SECRET_CURRENT || !retentionEnv.APPLE_TRANSACTION_HASH_SECRET || !c.env.USER_USAGE_LEDGER) {
      return c.json({ error: "Apple entitlement restoration is temporarily unavailable" }, 503);
    }
    const identitySecrets = [
      retentionEnv.APPLE_IDENTITY_RETENTION_SECRET_CURRENT,
      retentionEnv.APPLE_IDENTITY_RETENTION_SECRET_PREVIOUS,
    ].filter((secret): secret is string => Boolean(secret));
    let identity = await hashAppleIdentity(payload.sub!, identitySecrets[0]);
    let retained = await db.select().from(retainedAppleEntitlement).where(and(
      eq(retainedAppleEntitlement.identityHashVersion, identity.identityHashVersion),
      eq(retainedAppleEntitlement.identityHash, identity.identityHash),
    )).get();
    for (const secret of identitySecrets.slice(1)) {
      if (retained) break;
      const candidate = await hashAppleIdentity(payload.sub!, secret);
      const candidateRow = await db.select().from(retainedAppleEntitlement).where(and(
        eq(retainedAppleEntitlement.identityHashVersion, candidate.identityHashVersion),
        eq(retainedAppleEntitlement.identityHash, candidate.identityHash),
      )).get();
      if (candidateRow) { identity = candidate; retained = candidateRow; }
    }
    {
      if (retained) {
        const ledger = c.env.USER_USAGE_LEDGER.getByName(user.id);
        let restoredSnapshot: AccountEntitlementSnapshot | null = null;
        try {
          restoredSnapshot = await ledger.restoreAccountEntitlements({
            trialState: retained.trialState,
            trialInitialCredits: retained.trialInitialCredits,
            trialUsedCredits: retained.trialUsedCredits,
            reader: {
              total: retained.readerCreditsTotal,
              used: retained.readerCreditsUsed,
              activeUntil: retained.readerActiveUntil?.getTime() ?? null,
              status: retained.readerStatus,
            },
            voice: {
              total: retained.voiceCreditsTotal,
              used: retained.voiceCreditsUsed,
              activeUntil: retained.voiceActiveUntil?.getTime() ?? null,
              status: retained.voiceStatus,
            },
          });
        } catch (error) {
          if (!isNonEmptyLedgerConflict(error)) {
            console.error("Apple entitlement restoration failed", error);
            return c.json({
              error: "Apple entitlement restoration is temporarily unavailable",
              code: "APPLE_ENTITLEMENT_RESTORATION_FAILED",
            }, 503);
          }
          console.warn("Apple entitlement restoration skipped for populated ledger", {
            userIdPresent: Boolean(user.id),
          });
        }

        // The Durable Object is authoritative. Only mirror the snapshot it
        // accepted, never the retained D1 row that may have been superseded
        // by existing per-feature state.
        if (restoredSnapshot) {
          const restoredPeriodEnd = Math.max(restoredSnapshot.reader.activeUntil ?? 0, restoredSnapshot.voice.activeUntil ?? 0);
          if (restoredPeriodEnd > Date.now()) {
            const nowMs = Date.now();
            const readerActive = (restoredSnapshot.reader.activeUntil ?? 0) > nowMs;
            const voiceActive = (restoredSnapshot.voice.activeUntil ?? 0) > nowMs;
            const plan = readerActive && voiceActive
              ? "combined"
              : readerActive
                ? "reader"
                : "voice";
            await db.insert(allowancePeriod).values({
              id: `retained:${user.id}`,
              userId: user.id,
              plan,
              periodStart: new Date(),
              periodEnd: new Date(restoredPeriodEnd),
              narrationSecondsTotal: restoredSnapshot.reader.total,
              narrationSecondsUsed: restoredSnapshot.reader.used,
              voiceChatSecondsTotal: restoredSnapshot.voice.total,
              voiceChatSecondsUsed: restoredSnapshot.voice.used,
              transitionReason: "initial",
              priorPeriodId: null,
              sourceTransactionId: null,
              createdAt: new Date(),
            }).onConflictDoUpdate({
              target: allowancePeriod.id,
              set: {
                plan,
                periodEnd: new Date(restoredPeriodEnd),
                narrationSecondsTotal: restoredSnapshot.reader.total,
                narrationSecondsUsed: restoredSnapshot.reader.used,
                voiceChatSecondsTotal: restoredSnapshot.voice.total,
                voiceChatSecondsUsed: restoredSnapshot.voice.used,
              },
            });
          }
          const now = new Date();
          const transactions = await db.select().from(retainedAppleTransaction).where(and(
            eq(retainedAppleTransaction.identityHashVersion, identity.identityHashVersion),
            eq(retainedAppleTransaction.identityHash, identity.identityHash),
            inArray(retainedAppleTransaction.status, ["active", "in_grace"]),
            gt(retainedAppleTransaction.periodEnd, now),
          )).all();
          for (const transaction of transactions) {
            await db.insert(restoredAppleEntitlement).values({
              userId: user.id,
              identityHashVersion: identity.identityHashVersion,
              identityHash: identity.identityHash,
              transactionHashVersion: transaction.transactionHashVersion,
              environment: transaction.environment,
              originalTransactionHash: transaction.originalTransactionHash,
              feature: transaction.feature,
              status: transaction.status,
              periodEnd: transaction.periodEnd,
              updatedAt: new Date(),
            }).onConflictDoUpdate({
              target: [restoredAppleEntitlement.userId, restoredAppleEntitlement.transactionHashVersion, restoredAppleEntitlement.environment, restoredAppleEntitlement.originalTransactionHash],
              set: { feature: transaction.feature, status: transaction.status, periodEnd: transaction.periodEnd, updatedAt: new Date() },
            });
          }
        }
      }
    }

    failureStage = "sign-session-tokens";

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

    console.info("apple sign-in succeeded", {
      existingAppleUser: Boolean(existingAppleUser),
      usedAuthorizationCode: suppliedAuthorizationCode,
      userIdPresent: Boolean(user.id),
    });
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
    console.error("apple sign-in failed", {
      stage: failureStage,
      error: err instanceof Error ? err.message : String(err),
    });

    const identityVerificationFailed = failureStage === "verify-identity-token";
    return c.json(
      {
        error: identityVerificationFailed
          ? "Invalid Apple identity token"
          : "Apple sign-in is temporarily unavailable",
        ...(identityVerificationFailed ? {} : { code: "APPLE_SIGN_IN_UNAVAILABLE" }),
      },
      identityVerificationFailed ? 401 : 503,
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
