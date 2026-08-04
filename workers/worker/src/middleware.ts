import { createMiddleware } from "hono/factory";
import { Effect } from "effect";
import { verifyAccessToken } from "./jwt";
import { eq } from "drizzle-orm";
import { deletionState, user } from "./db/schema";
import { createDb } from "./db/drizzle";
import { ensureUsername, UsernameAllocationError } from "./usernames";

type AuthMiddlewareOptions = {
  allowMissingUser?: boolean;
};

export function makeRequireAuth(options: AuthMiddlewareOptions = {}) {
  return createMiddleware<{
    Variables: {
      userId: string;
    };
    Bindings: Env;
  }>(async (c, next) => {
  const auth = c.req.header("Authorization");

  if (!auth?.startsWith("Bearer ")) {
    return c.json(
      {
        error: "Unauthorized",
      },
      401,
    );
  }

  const token = auth.slice(7);

  const result = await Effect.runPromiseExit(verifyAccessToken(c.env, token));

  if (result._tag === "Failure") {
    return c.json(
      {
        error: "Unauthorized",
      },
      401,
    );
  }

  c.set("userId", result.value.userId);

  const db = createDb(c.env.DB);
  const existingUser = await db.select({ id: user.id, name: user.name })
    .from(user)
    .where(eq(user.id, result.value.userId))
    .get();
  if (!existingUser && !options.allowMissingUser) {
    return c.json({ error: "Account deleted" }, 410);
  }
  if (existingUser && !options.allowMissingUser) {
    const pendingDeletion = await db.select({ status: deletionState.status })
      .from(deletionState)
      .where(eq(deletionState.userId, result.value.userId))
      .get();
    if (pendingDeletion?.status === "pending" || pendingDeletion?.status === "purging") {
      return c.json({ error: "Account deletion in progress" }, 423);
    }
  }

  if (existingUser && !options.allowMissingUser) {
    try {
      await ensureUsername(db, existingUser.id, existingUser.name);
    } catch (error) {
      if (error instanceof UsernameAllocationError) {
        return c.json({
          error: "Username service unavailable",
          code: "USERNAME_UNAVAILABLE",
        }, 503);
      }
      throw error;
    }
  }

  await next();
  });
}

export const requireAuth = makeRequireAuth();
export const requireAuthForDeletion = makeRequireAuth({ allowMissingUser: true });
