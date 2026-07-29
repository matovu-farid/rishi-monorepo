import { createMiddleware } from "hono/factory";

export const AI_DATA_CONSENT_HEADER = "X-Rishi-Data-Use-Consent";
export const AI_DATA_CONSENT_VERSION = "2026-07-29";

export const requireAiDataConsent = createMiddleware<{
  Bindings: Env;
  Variables: { userId: string };
}>(async (c, next) => {
  if (c.req.header(AI_DATA_CONSENT_HEADER) !== AI_DATA_CONSENT_VERSION) {
    return c.json(
      {
        error: "AI_DATA_CONSENT_REQUIRED",
      },
      428,
    );
  }

  await next();
});
