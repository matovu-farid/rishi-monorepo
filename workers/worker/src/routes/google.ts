import { Effect } from "effect";
import { and, eq } from "drizzle-orm";
import { Hono } from "hono";
import { createRemoteJWKSet, jwtVerify, type JWTPayload } from "jose";

import { account, deletionState, user, usernames } from "../db/schema";
import { createDb, type WorkerDb } from "../db/drizzle";
import { signAccessToken, signRefreshToken } from "../jwt";
import {
  ensureUsername,
  generateUsernameCandidate,
  isUsernameAllocationError,
  isUsernameConflict,
  UsernameAllocationError,
} from "../usernames";
import {
  checkRateLimit,
  rateLimitSubjectKey,
  RATE_LIMITS,
} from "../ops/rate-limit";

const GOOGLE_JWKS = createRemoteJWKSet(
  new URL("https://www.googleapis.com/oauth2/v3/certs"),
);
const GOOGLE_ISSUERS = ["accounts.google.com", "https://accounts.google.com"];
const GOOGLE_ID_TOKEN_MAX_AGE = "1h";
const GOOGLE_PROVIDER_ID = "google";

const googleRoutes = new Hono<{ Bindings: Env }>();

type GoogleAccount = {
  id: string;
  accountId: string;
  providerId: string;
  userId: string;
};

type GoogleUser = {
  id: string;
  name: string;
  email: string | null;
  emailVerified: boolean;
  image: string | null;
  username: string;
};

type ExistingUserResult =
  | { kind: "user"; user: GoogleUser }
  | { kind: "deleting" }
  | { kind: "migration" };

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function isStringClaim(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isTrueClaim(value: unknown): boolean {
  return value === true || value === "true";
}

function sourceIp(c: { req: { header(name: string): string | undefined } }): string {
  return c.req.header("cf-connecting-ip") ?? "unknown";
}

async function findAccountByGoogleSubject(
  db: WorkerDb,
  sub: string,
): Promise<GoogleAccount | undefined> {
  return db
    .select({
      id: account.id,
      accountId: account.accountId,
      providerId: account.providerId,
      userId: account.userId,
    })
    .from(account)
    .where(
      and(
        eq(account.providerId, GOOGLE_PROVIDER_ID),
        eq(account.accountId, sub),
      ),
    )
    .get();
}

async function findAccountById(
  db: WorkerDb,
  id: string,
): Promise<GoogleAccount | undefined> {
  return db
    .select({
      id: account.id,
      accountId: account.accountId,
      providerId: account.providerId,
      userId: account.userId,
    })
    .from(account)
    .where(eq(account.id, id))
    .get();
}

async function resolveExistingUser(
  db: WorkerDb,
  linkedAccount: GoogleAccount,
): Promise<ExistingUserResult> {
  const linkedUser = await db
    .select({
      id: user.id,
      name: user.name,
      email: user.email,
      emailVerified: user.emailVerified,
      image: user.image,
    })
    .from(user)
    .where(eq(user.id, linkedAccount.userId))
    .get();

  if (!linkedUser || !isUuid(linkedUser.id)) {
    return { kind: "migration" };
  }

  const deletion = await db
    .select({ status: deletionState.status })
    .from(deletionState)
    .where(eq(deletionState.userId, linkedUser.id))
    .get();
  if (deletion?.status === "pending" || deletion?.status === "purging") {
    return { kind: "deleting" };
  }

  const username = await ensureUsername(db, linkedUser.id, linkedUser.name);
  return { kind: "user", user: { ...linkedUser, username } };
}

function identityConflict(
  deterministicAccount: GoogleAccount | undefined,
  sub: string,
): boolean {
  return Boolean(
    deterministicAccount &&
      (deterministicAccount.providerId !== GOOGLE_PROVIDER_ID ||
        deterministicAccount.accountId !== sub),
  );
}

async function resolveGoogleUser(
  db: WorkerDb,
  payload: JWTPayload,
): Promise<ExistingUserResult> {
  if (!isStringClaim(payload.sub)) {
    throw new Error("Google identity token is missing sub");
  }
  const sub = payload.sub;
  const deterministicId = `${GOOGLE_PROVIDER_ID}:${sub}`;

  const linkedAccount = await findAccountByGoogleSubject(db, sub);
  const deterministicAccount = await findAccountById(db, deterministicId);
  if (identityConflict(deterministicAccount, sub)) {
    return { kind: "migration" };
  }
  if (linkedAccount) {
    return resolveExistingUser(db, linkedAccount);
  }

  const userId = crypto.randomUUID();
  const now = new Date();
  const email = isStringClaim(payload.email) ? payload.email : null;
  const name = isStringClaim(payload.name)
    ? payload.name
    : email ?? "Google user";
  const newUser = {
    id: userId,
    name,
    email,
    emailVerified: isTrueClaim(payload.email_verified),
    image: isStringClaim(payload.picture) ? payload.picture : null,
    createdAt: now,
    updatedAt: now,
  };
  const newAccount = {
    id: deterministicId,
    accountId: sub,
    providerId: GOOGLE_PROVIDER_ID,
    userId,
    createdAt: now,
    updatedAt: now,
  };

  for (let attempt = 0; attempt < 8; attempt += 1) {
    const username = generateUsernameCandidate(name);
    try {
      await db.batch([
        db.insert(user).values(newUser),
        db.insert(usernames).values({
          userId,
          username,
          createdAt: now,
          updatedAt: now,
        }),
        db.insert(account).values(newAccount),
      ]);
      return { kind: "user", user: { ...newUser, username } };
    } catch (error) {
      // The deterministic account primary key serializes concurrent first
      // sign-ins without needing a new migration or a hand-written constraint.
      const winner = await findAccountByGoogleSubject(db, sub);
      if (winner) return resolveExistingUser(db, winner);

      if (isUsernameConflict(error)) continue;

      const conflictingAccount = await findAccountById(db, deterministicId);
      if (identityConflict(conflictingAccount, sub)) {
        return { kind: "migration" };
      }
      throw error;
    }
  }
  throw new UsernameAllocationError();
}

googleRoutes.post("/google", async (c) => {
  const ip = sourceIp(c);
  const limit = await checkRateLimit(
    c.env,
    rateLimitSubjectKey("googleSignInIp", "ip", ip),
    RATE_LIMITS.googleSignInIp,
  );
  if (!limit.allowed) {
    return c.json({ error: "Too many sign-in attempts" }, 429);
  }

  const googleClientId = c.env.GOOGLE_CLIENT_ID?.trim();
  if (!googleClientId) {
    return c.json({ error: "Google sign-in unavailable" }, 503);
  }

  const rawBody = await c.req.json().catch(() => null) as {
    identityToken?: unknown;
  } | null;
  if (!rawBody || !isStringClaim(rawBody.identityToken)) {
    return c.json({ error: "Missing identity token" }, 400);
  }

  let payload: JWTPayload;
  try {
    const verified = await jwtVerify(rawBody.identityToken, GOOGLE_JWKS, {
      algorithms: ["RS256"],
      issuer: GOOGLE_ISSUERS,
      audience: googleClientId,
      maxTokenAge: GOOGLE_ID_TOKEN_MAX_AGE,
      requiredClaims: ["sub", "exp"],
    });
    payload = verified.payload;
    if (!isStringClaim(payload.sub)) throw new Error("missing sub");
  } catch {
    return c.json({ error: "Invalid Google identity token" }, 401);
  }

  try {
    const db = createDb(c.env.DB);
    const resolved = await resolveGoogleUser(db, payload);
    if (resolved.kind === "migration") {
      return c.json({ error: "Account migration required" }, 503);
    }
    if (resolved.kind === "deleting") {
      return c.json({ error: "Account deletion in progress" }, 423);
    }

    const accessToken = await Effect.runPromise(
      signAccessToken(c.env, { userId: resolved.user.id }),
    );
    const refreshToken = await Effect.runPromise(
      signRefreshToken(c.env, { userId: resolved.user.id }),
    );

    return c.json({
      accessToken,
      refreshToken,
      userId: resolved.user.id,
      user: {
        id: resolved.user.id,
        email: resolved.user.email,
        name: resolved.user.name,
        username: resolved.user.username,
      },
    });
  } catch (error) {
    if (isUsernameAllocationError(error)) {
      return c.json({
        error: "Username service unavailable",
        code: "USERNAME_UNAVAILABLE",
      }, 503);
    }
    console.error("google sign-in failed", {
      error: error instanceof Error ? error.message : String(error),
    });
    return c.json({ error: "Could not complete Google sign-in" }, 500);
  }
});

export { googleRoutes };
export default googleRoutes;
