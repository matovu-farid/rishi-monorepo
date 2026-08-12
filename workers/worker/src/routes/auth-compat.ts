import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { deleteAccount } from "../account-deletion";
import { requireAuthForDeletion } from "../middleware";

export const authCompatRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

/**
 * Electron's Better Auth client historically called this endpoint. Keep it as
 * a compatibility route, but use the Worker's full deletion workflow rather
 * than Better Auth's generic user deletion handler.
 */
authCompatRoutes.post("/delete-user", requireAuthForDeletion, async (c) => {
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);
    const result = await deleteAccount(db, c.env, userId);

    return c.json({
      ok: true,
      alreadyDeleted: result.alreadyDeleted,
      revocationStatus: result.revocationStatus,
    });
  } catch (error) {
    console.error("account deletion failed", {
      error: error instanceof Error ? error.message : "unknown",
    });
    return c.json({ error: "Failed to delete user" }, 500);
  }
});
