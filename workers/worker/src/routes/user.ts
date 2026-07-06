import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { eq } from "drizzle-orm";
import { user } from "@rishi/shared";
import { requireAuth } from "../middleware";

export const userRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();
userRoutes.get("/", requireAuth, async (c) => {
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);

    const retrieveduser = await db.query.user.findFirst({
      where: eq(user.id, userId),
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

userRoutes.delete("/", requireAuth, async (c) => {
  try {
    const userId = c.get("userId");
    const db = createDb(c.env.DB);

    await db.delete(user).where(eq(user.id, userId));

    return c.json({
      message: "Deleted successfully",
    });
  } catch (e) {
    console.log(e);
    c.json({
      error: "Failed to get a user",
    });
  }
});
