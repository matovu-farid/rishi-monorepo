import { createMiddleware } from "hono/factory";
import { Effect } from "effect";
import { verifyAccessToken } from "./jwt";

export const requireAuth = createMiddleware<{
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

  await next();
});
