import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { eq } from "drizzle-orm";
import { user, usernames } from "../db/schema";
import { accountDeletionErrorEnvelope, deleteAccount } from "../account-deletion";
import { requireAuth, requireAuthForDeletion } from "../middleware";
import {
  ensureUsername,
  isUsernameConflict,
  UsernameAllocationError,
  validateUsername,
} from "../usernames";

export const userRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

function deletionCorrelationId(c: any): string {
  const supplied = c.req.header("x-rishi-correlation-id");
  return supplied && /^[a-zA-Z0-9_-]{16,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}

async function getProfile(db: ReturnType<typeof createDb>, userId: string) {
  const retrievedUser = await db.query.user.findFirst({ where: { id: userId } });
  if (!retrievedUser) return null;

  await ensureUsername(db, retrievedUser.id, retrievedUser.name);
  return db.select({
    id: user.id,
    email: user.email,
    name: user.name,
    username: usernames.username,
  })
    .from(user)
    .leftJoin(usernames, eq(usernames.userId, user.id))
    .where(eq(user.id, userId))
    .get();
}

userRoutes.get("/", requireAuth, async (c) => {
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    const profile = await getProfile(db, userId);
    if (!profile) return c.json({ error: "User not found" }, 404);
    return c.json(profile);
  } catch (e) {
    console.log(e);
    if (e instanceof UsernameAllocationError) {
      return c.json({ error: "Username service unavailable", code: "USERNAME_UNAVAILABLE" }, 503);
    }
    return c.json({ error: "Failed to get a user" }, 500);
  }
});

userRoutes.patch("/", requireAuth, async (c) => {
  const body = await c.req.json().catch(() => null) as { username?: unknown } | null;
  if (!body || typeof body.username !== "string") {
    return c.json({ error: "Invalid username", code: "INVALID_USERNAME" }, 400);
  }

  const validation = validateUsername(body.username);
  if (!validation.ok) {
    return c.json({ error: "Invalid username", code: "INVALID_USERNAME" }, 400);
  }

  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    const profile = await getProfile(db, userId);
    if (!profile) return c.json({ error: "User not found" }, 404);

    await db.update(usernames)
      .set({ username: validation.value, updatedAt: new Date() })
      .where(eq(usernames.userId, userId));

    const updatedProfile = await getProfile(db, userId);
    if (!updatedProfile) return c.json({ error: "User not found" }, 404);
    return c.json(updatedProfile);
  } catch (e) {
    if (isUsernameConflict(e)) {
      return c.json({ error: "Username is already taken", code: "USERNAME_TAKEN" }, 409);
    }
    if (e instanceof UsernameAllocationError) {
      return c.json({ error: "Username service unavailable", code: "USERNAME_UNAVAILABLE" }, 503);
    }
    console.error("failed to update user profile", e);
    return c.json({ error: "Failed to update user" }, 500);
  }
});

userRoutes.delete("/", requireAuthForDeletion, async (c) => {
  const correlationId = deletionCorrelationId(c);
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    const result = await deleteAccount(db, c.env, userId, correlationId);

    return c.json({
      ok: true,
      alreadyDeleted: result.alreadyDeleted,
      revocationStatus: result.revocationStatus,
    });
  } catch (e) {
    const envelope = accountDeletionErrorEnvelope(e, correlationId);
    console.error("account deletion failed", {
      event: "account_deletion.request_failed",
      correlationId,
      category: e instanceof Error ? e.name : "unknown",
    });
    const status = envelope.code === "ACCOUNT_DELETION_CONFLICT" ? 409 : 503;
    return c.json(envelope, status);
  }
});
