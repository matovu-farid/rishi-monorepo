import { randomUUID } from "node:crypto";
import { Hono } from "hono";
import { and, eq } from "drizzle-orm";
import { hashPassword, verifyPassword } from "better-auth/crypto";
import { account, user } from "../db/schema";
import { createDb } from "../db/drizzle";
import { createAuth } from "../auth";
import {
  accountDeletionErrorBody,
  accountDeletionErrorEnvelope,
  deleteAccount,
} from "../account-deletion";

type TestAuthEnv = Env & {
  TEST_AUTH_EMAIL_DOMAIN?: string;
};

/**
 * Test-only auth routes mounted at /test/*.
 *
 * These exist so end-to-end tests can spin up a disposable user account,
 * exercise sync, and tear it down without going through an OAuth browser
 * dance. They are hard-gated by the explicit test flag, secret, and an
 * allowlisted email domain. Production wrangler configuration defines none of
 * those test controls.
 */
export const testAuthRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

/**
 * Constant-time string comparison.
 *
 * The loop runs to the longer encoded length so a short mismatching header
 * does not immediately reveal the expected secret length.
 */
function timingSafeEqual(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const bufA = encoder.encode(a);
  const bufB = encoder.encode(b);
  let diff = bufA.length ^ bufB.length;
  const len = Math.max(bufA.length, bufB.length);
  for (let i = 0; i < len; i++) {
    diff |= (bufA[i] ?? 0) ^ (bufB[i] ?? 0);
  }
  return diff === 0;
}

function testEmailDomain(env: Env): string | null {
  const configured = (env as TestAuthEnv).TEST_AUTH_EMAIL_DOMAIN
    ?.trim()
    .toLowerCase()
    .replace(/^@/, "");
  return configured || null;
}

function gateOrNotFound(c: {
  env: Env;
  req: { header: (name: string) => string | undefined };
}): Response | null {
  if (c.env.ENABLE_TEST_AUTH !== "true") {
    return new Response("Not Found", { status: 404 });
  }

  const expected = c.env.TEST_AUTH_SECRET;
  const provided = c.req.header("X-Test-Auth-Secret");
  if (!expected || !provided || !timingSafeEqual(provided, expected)) {
    return new Response("Not Found", { status: 404 });
  }

  return null;
}

function isAllowedTestEmail(email: string, domain: string | null): boolean {
  return domain === null || email.toLowerCase().endsWith(`@${domain}`);
}

async function rollbackCreatedUser(
  db: ReturnType<typeof createDb>,
  env: Env,
  userId: string,
): Promise<boolean> {
  try {
    await deleteAccount(db, env, userId);
    return true;
  } catch (error) {
    console.error("test account cleanup failed", { userId, error });
    return false;
  }
}

// ─── POST /sign-in ────────────────────────────────────────────────────────────
// Creates a disposable credential account when missing, provisions its trial,
// and returns a Better Auth session token. Existing disposable users receive a
// fresh session without modifying their account.
testAuthRoutes.post("/sign-in", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  // Fail closed before reading the request body: no test account can be
  // created unless its trial ledger can be addressed and provisioned.
  if (!c.env.USER_USAGE_LEDGER || typeof c.env.USER_USAGE_LEDGER.getByName !== "function") {
    return c.json(
      { error: "Trial credit provisioning is temporarily unavailable" },
      503,
    );
  }

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "Invalid JSON" }, 400);
  }

  const { email: rawEmail, password } = (body ?? {}) as {
    email?: unknown;
    password?: unknown;
  };
  if (
    typeof rawEmail !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(rawEmail) ||
    typeof password !== "string" ||
    password.length < 1
  ) {
    return c.json({ error: "email and password required" }, 400);
  }

  const email = rawEmail.toLowerCase();
  const domain = testEmailDomain(c.env);
  if (!isAllowedTestEmail(email, domain)) {
    return c.json({ error: "email must use the configured test domain" }, 400);
  }

  const db = createDb(c.env.DB);
  const auth = await createAuth(c.env);
  const authContext = await auth.$context;
  const adapter = authContext.internalAdapter;
  const existingUser = await db
    .select()
    .from(user)
    .where(eq(user.email, email))
    .get();

  let userId = existingUser?.id;
  let createdUser = false;

  try {
    if (userId) {
      const credentialAccount = await db
        .select()
        .from(account)
        .where(and(eq(account.userId, userId), eq(account.providerId, "credential")))
        .get();
      let passwordMatches = false;
      if (credentialAccount?.password) {
        try {
          passwordMatches = await verifyPassword({ hash: credentialAccount.password, password });
        } catch {
          passwordMatches = false;
        }
      }
      if (!passwordMatches) {
        return c.json({ error: "Invalid email or password" }, 401);
      }
    }

    if (!userId) {
      const passwordHash = await hashPassword(password);
      const created = await adapter.createUser({
        id: randomUUID(),
        email,
        name: email.split("@")[0] || "Test User",
        emailVerified: true,
      });
      if (!created?.id) throw new Error("Better Auth did not create a user");

      userId = created.id;
      createdUser = true;
      await adapter.createAccount({
        accountId: userId,
        providerId: "credential",
        userId,
        password: passwordHash,
      });
    }

    await c.env.USER_USAGE_LEDGER.getByName(userId).grantTrialIfAbsent();
    const session = await adapter.createSession(userId);
    if (!session?.token) throw new Error("Better Auth did not create a session");

    return c.json({ token: session.token, userId, email });
  } catch (error) {
    if (createdUser && userId) {
      const cleaned = await rollbackCreatedUser(db, c.env, userId);
      if (!cleaned) return c.json({ error: "test account cleanup failed" }, 500);
    }

    console.error("test auth provisioning failed", { userId, error });
    return c.json(
      { error: "Trial credit provisioning is temporarily unavailable" },
      503,
    );
  }
});

// ─── DELETE /users/:email ─────────────────────────────────────────────────────
// Account teardown is delegated to the canonical deletion workflow so this
// route cannot silently omit ledger, sharing, retention, or future cleanup.
testAuthRoutes.delete("/users/:email", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  let email: string;
  try {
    email = decodeURIComponent(c.req.param("email")).toLowerCase();
  } catch {
    return c.json({ error: "user not found" }, 404);
  }

  const domain = testEmailDomain(c.env);
  if (!isAllowedTestEmail(email, domain)) {
    return c.json({ error: "user not found" }, 404);
  }

  const db = createDb(c.env.DB);
  const userRow = await db
    .select()
    .from(user)
    .where(eq(user.email, email))
    .get();
  if (!userRow) return c.json({ error: "user not found" }, 404);

  try {
    const deletion = await deleteAccount(db, c.env, userRow.id);
    return c.json({ deleted: true, userId: userRow.id, ...deletion });
  } catch (error) {
    console.error("test account teardown failed", { userId: userRow.id, error });
    const body = accountDeletionErrorEnvelope(error, randomUUID());
    return c.json(body, accountDeletionErrorBody(error)?.status ?? 500);
  }
});
