import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { eq } from "drizzle-orm";
import { user, usernames } from "../db/schema";
import { deleteAccount } from "../account-deletion";
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
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    const result = await deleteAccount(db, c.env, userId);

    return c.json({
      ok: true,
      alreadyDeleted: result.alreadyDeleted,
      revocationStatus: result.revocationStatus,
    });
  } catch (e) {
    console.error("account deletion failed", {
      error: e instanceof Error ? e.message : "unknown",
    });
    return c.json({
      error: "Failed to delete user",
    }, 500);
  }
});
