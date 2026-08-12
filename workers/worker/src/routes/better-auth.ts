import { Hono } from "hono";
import { createAuth } from "../auth";

export function registerBetterAuthRoutes(
  app: Hono<{ Bindings: Env; Variables: { userId: string } }>,
): void {
  app.on(["GET", "POST"], "/api/auth/*", async (c) => {
    const auth = await createAuth(c.env);
    return auth.handler(c.req.raw);
  });
}
