import { Hono } from "hono";
import { eq, inArray } from "drizzle-orm";
import { sessionInvites, user } from "../db/schema";
import { createDb } from "../db/drizzle";
import { createAuth } from "../auth";
import { deleteAccount } from "../account-deletion";
import {
  isSessionSharingServiceError,
  SessionSharingService,
  type SessionSharingRoomStatus,
} from "../session-sharing-service";


/**
 * Test-only auth routes mounted at /test/*.
 *
 * These exist so end-to-end tests (Playwright + Detox in the parity effort)
 * can spin up a fresh user account, exercise sync, and tear it down — without
 * going through the OAuth browser dance. They are HARD GATED by three checks:
 *
 *   a. c.env.ENABLE_TEST_AUTH === 'true'   (wrangler vars are strings)
 *   b. X-Test-Auth-Secret header matches c.env.TEST_AUTH_SECRET (constant-time)
 *   c. c.env.ENABLE_TEST_AUTH must be PRESENT (defense in depth)
 *
 * Any gate failure returns 404 — NOT 401/403 — so probers see "no such
 * endpoint". Production wrangler.jsonc deliberately does NOT define either
 * variable; they must be set explicitly on dev/staging via `wrangler secret put`.
 */

export const testAuthRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

const GENERATED_E2E_EMAIL = /^rishi-e2e-[^@\s]+@[^@\s]+$/;

type RemoteCleanupFailure = {
  sessionId: string;
  code: string;
};

class RemoteCleanupError extends Error {
  constructor(readonly code: string) {
    super(code);
  }
}

function cleanupErrorCode(error: unknown): string {
  if (error instanceof RemoteCleanupError) return error.code;
  if (isSessionSharingServiceError(error)) return error.code;
  if (error && typeof error === "object" && "code" in error && typeof error.code === "string") {
    return error.code;
  }
  return "CLEANUP_FAILED";
}

function requireGeneratedController(
  room: SessionSharingRoomStatus,
  generatedUserIds: ReadonlySet<string>,
): void {
  if (!generatedUserIds.has(room.controllerUserId)) {
    throw new RemoteCleanupError("UNKNOWN_CONTROLLER");
  }
}

async function endRoomWithOneStaleRetry(
  service: SessionSharingService,
  room: SessionSharingRoomStatus,
  generatedUserIds: ReadonlySet<string>,
): Promise<boolean> {
  if (room.status === "ended") return true;
  requireGeneratedController(room, generatedUserIds);

  try {
    await service.endRoom({
      sessionId: room.sessionId,
      actingUserId: room.controllerUserId,
      expectedControllerGeneration: room.controllerGeneration,
    });
    return true;
  } catch (error) {
    if (cleanupErrorCode(error) !== "STALE_CONTROLLER_GENERATION") throw error;
  }

  const refreshed = await service.getRoomStatus({ sessionId: room.sessionId });
  if (!refreshed || refreshed.status === "ended") return Boolean(refreshed);
  requireGeneratedController(refreshed, generatedUserIds);
  // A second stale-generation response is deliberately not retried.
  await service.endRoom({
    sessionId: refreshed.sessionId,
    actingUserId: refreshed.controllerUserId,
    expectedControllerGeneration: refreshed.controllerGeneration,
  });
  return true;
}

async function cleanupRoom(
  service: SessionSharingService,
  sessionId: string,
  generatedUserIds: ReadonlySet<string>,
): Promise<void> {
  const initial = await service.getRoomStatus({ sessionId });
  if (!initial) return;

  const roomRemainedPresent = await endRoomWithOneStaleRetry(service, initial, generatedUserIds);
  if (!roomRemainedPresent) return;

  const ended = await service.getRoomStatus({ sessionId });
  // A room that disappears after a successful end is already authoritatively
  // absent, so it is an idempotent success rather than a purge failure.
  if (!ended) return;
  if (ended.status !== "ended") throw new RemoteCleanupError("END_NOT_VERIFIED");

  await service.purgeAppleRoom({ sessionId });
  const absent = await service.getRoomStatus({ sessionId });
  if (absent !== null) throw new RemoteCleanupError("ROOM_NOT_ABSENT");
}

function sessionSharingService(c: { env: Env }): SessionSharingService {
  return new SessionSharingService(c.env.SHARING_WORKER, {
    internalTokenSecret: c.env.SHARING_INTERNAL_SECRET,
    internalPathPrefix: "/v2/internal",
  });
}

/**
 * Constant-time string comparison.
 *
 * We do the XOR-then-OR ourselves instead of using `crypto.subtle.timingSafeEqual`
 * (which exists on the Cloudflare Workers runtime but NOT on Node, breaking
 * vitest). The loop runs to the longer length so an attacker can't time the
 * mismatch by sending a 1-char header.
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

/**
 * Verifies all three gates. Returns null on success, or a 404 Response that
 * the caller should return immediately. We use 404 (not 401/403) so an
 * attacker probing production sees the same response as for any other
 * unknown path.
 */
function gateOrNotFound(c: {
  env: Env;
  req: { header: (name: string) => string | undefined };
}): Response | null {
  const enabled = c.env.ENABLE_TEST_AUTH;
  if (!enabled || enabled !== "true") {
    return new Response("404 Not Found", { status: 404 });
  }
  const expected = c.env.TEST_AUTH_SECRET;
  if (!expected) {
    return new Response("404 Not Found", { status: 404 });
  }
  const provided = c.req.header("X-Test-Auth-Secret");
  if (!provided || !timingSafeEqual(provided, expected)) {
    return new Response("404 Not Found", { status: 404 });
  }
  return null;
}

// ─── POST /sign-in ────────────────────────────────────────────────────────────
// Either creates a new user (via Better-Auth signUpEmail) and signs them in,
// or — if the user already exists — just signs them in. Returns the bearer
// session token along with userId + email.
testAuthRoutes.post("/sign-in", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "Invalid JSON" }, 400);
  }
  const { email, password } = (body ?? {}) as {
    email?: string;
    password?: string;
  };
  if (
    !email ||
    typeof email !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
    !password ||
    typeof password !== "string" ||
    password.length < 1
  ) {
    return c.json({ error: "email and password required" }, 400);
  }

  const auth = await createAuth(c.env);
  const headers = c.req.raw.headers;

  // Try to sign up first. If the user already exists, Better-Auth throws
  // (or returns a recognisable error) — we swallow it and fall through to
  // signInEmail. This matches the brief's "create if missing" semantics.
  try {
    await auth.api.signUpEmail({
      body: {
        email,
        password,
        name: email.split("@")[0] || "Test User",
      },
      headers,
      asResponse: false,
    });
  } catch (err) {
    // Likely "user exists" — proceed to sign in. We don't differentiate here
    // because all other errors will surface again in the signInEmail call.
    void err;
  }

  let signed;
  try {
    signed = await auth.api.signInEmail({
      body: { email, password },
      headers,
      asResponse: false,
    });
  } catch (err) {
    const message = err instanceof Error ? err.message : "sign-in failed";
    return c.json({ error: message }, 401);
  }

  // Better-Auth's signInEmail returns { user, token } in v1.6+.
  const token = (signed as { token?: string })?.token;
  const userId = (signed as { user?: { id?: string } })?.user?.id;
  if (!token || !userId) {
    return c.json({ error: "sign-in did not return a token" }, 500);
  }
  return c.json({ token, userId, email });
});

// ─── POST /rooms/cleanup ──────────────────────────────────────────────────────
// Resolve two generated test accounts server-side, remove every room owned by
// either account, and prove each room absent before callers delete accounts.
// Caller-supplied user and session identifiers are intentionally ignored.
testAuthRoutes.post("/rooms/cleanup", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  const body = await c.req.json().catch(() => null) as { emails?: unknown } | null;
  const suppliedEmails = body?.emails;
  if (
    !Array.isArray(suppliedEmails) ||
    suppliedEmails.length !== 2 ||
    suppliedEmails.some((email) => typeof email !== "string")
  ) {
    return c.json({ error: "exactly two generated emails are required" }, 400);
  }
  const emails = suppliedEmails.map((email) => email.toLowerCase());
  if (new Set(emails).size !== 2 || emails.some((email) => !GENERATED_E2E_EMAIL.test(email))) {
    return c.json({ error: "exactly two generated emails are required" }, 400);
  }

  const db = createDb(c.env.DB);
  const users = await db.select({ id: user.id }).from(user).where(inArray(user.email, emails)).all();
  const generatedUserIds = new Set(users.map((row) => row.id));
  const ownedRooms = generatedUserIds.size === 0
    ? []
    : await db.select({ sessionId: sessionInvites.sessionId })
      .from(sessionInvites)
      .where(inArray(sessionInvites.ownerUserId, [...generatedUserIds]))
      .all();
  const service = sessionSharingService(c);
  const failures: RemoteCleanupFailure[] = [];

  for (const sessionId of new Set(ownedRooms.map((room) => room.sessionId))) {
    try {
      await cleanupRoom(service, sessionId, generatedUserIds);
    } catch (error) {
      failures.push({ sessionId, code: cleanupErrorCode(error) });
    }
  }

  if (failures.length > 0) {
    return c.json({ error: "remote room cleanup failed", failures }, 500);
  }
  return c.json({ ok: true });
});

// ─── DELETE /users/:email ─────────────────────────────────────────────────────
// This bearer-independent recovery route is intentionally only for generated
// E2E accounts. It delegates all mutation and verification to the canonical
// deletion workflow rather than attempting a best-effort local teardown.
testAuthRoutes.delete("/users/:email", async (c) => {
  const gate = gateOrNotFound(c);
  if (gate) return gate;

  const email = decodeURIComponent(c.req.param("email")).toLowerCase();
  if (!GENERATED_E2E_EMAIL.test(email)) {
    return c.json({ error: "user not found" }, 404);
  }
  const db = createDb(c.env.DB);
  const userRow = await db.select({ id: user.id }).from(user).where(eq(user.email, email)).get();
  if (!userRow) {
    return c.json({ error: "user not found" }, 404);
  }
  try {
    const result = await deleteAccount(db, c.env, userRow.id);
    if (result.alreadyDeleted) return c.json({ error: "user not found" }, 404);
    return c.json({
      deleted: true,
      userId: userRow.id,
      r2ObjectsRemoved: result.r2ObjectsRemoved,
    });
  } catch (error) {
    console.error("test account deletion failed", {
      error: error instanceof Error ? error.message : "unknown",
    });
    return c.json({ error: "Failed to delete user" }, 500);
  }
});
