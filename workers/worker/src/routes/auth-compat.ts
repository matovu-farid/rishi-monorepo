import { Hono } from "hono";
import { createDb } from "../db/drizzle";
import { accountDeletionErrorEnvelope, deleteAccount } from "../account-deletion";
import { requireAuthForDeletion } from "../middleware";

export const authCompatRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

function deletionCorrelationId(c: any): string {
  const supplied = c.req.header("x-rishi-correlation-id");
  return supplied && /^[a-zA-Z0-9_-]{16,128}$/.test(supplied) ? supplied : crypto.randomUUID();
}

/**
 * Electron's Better Auth client historically called this endpoint. Keep it as
 * a compatibility route, but use the Worker's full deletion workflow rather
 * than Better Auth's generic user deletion handler.
 */
authCompatRoutes.on(["POST", "DELETE"], "/delete-user", requireAuthForDeletion, async (c) => {
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
  } catch (error) {
    const envelope = accountDeletionErrorEnvelope(error, correlationId);
    console.error("account deletion failed", {
      event: "account_deletion.request_failed",
      correlationId,
      category: error instanceof Error ? error.name : "unknown",
    });
    const status = envelope.code === "ACCOUNT_DELETION_CONFLICT" ? 409 : 503;
    return c.json(envelope, status);
  }
});
