import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { deleteAccount } from "../account-deletion";
import { requireAuth, requireAuthForDeletion } from "../middleware";

export const userRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();
userRoutes.get("/", requireAuth, async (c) => {
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);

    const retrieveduser = await db.query.user.findFirst({
      where: { id: userId },
    });
    if (!retrieveduser) {
      return c.json({
        error: "No user retrieved",
      });
    }

    return c.json(retrieveduser);
  } catch (e) {
    console.log(e);
    c.json({
      error: "Failed to get a user",
    });
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
