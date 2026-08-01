import { createMiddleware } from "hono/factory";
import { Effect } from "effect";
import { verifyAccessToken } from "./jwt";
import { eq } from "drizzle-orm";
import { deletionState, user } from "./db/schema";
import { createDb } from "./db/drizzle";

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

  const existingUser = await createDb(c.env.DB).select({ id: user.id })
    .from(user)
    .where(eq(user.id, result.value.userId))
    .get();
  if (!existingUser && !options.allowMissingUser) {
    return c.json({ error: "Account deleted" }, 410);
  }
  if (existingUser && !options.allowMissingUser) {
    const pendingDeletion = await createDb(c.env.DB).select({ status: deletionState.status })
      .from(deletionState)
      .where(eq(deletionState.userId, result.value.userId))
      .get();
    if (pendingDeletion?.status === "pending" || pendingDeletion?.status === "purging") {
      return c.json({ error: "Account deletion in progress" }, 423);
    }
  }

  await next();
  });
}

export const requireAuth = makeRequireAuth();
export const requireAuthForDeletion = makeRequireAuth({ allowMissingUser: true });
