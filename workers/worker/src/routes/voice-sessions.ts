// workers/worker/src/routes/voice-sessions.ts

import { Hono } from "hono";
import { requireAuth } from "../middleware";

/**
 * Control WebSocket for an in-progress voice session. See
 * `docs/superpowers/plans/2026-07-17-voice-control-websocket.md` for the
 * full design and
 * `docs/superpowers/specs/2026-07-17-no-card-credit-trial-design.md`
 * ("Control WebSocket") for the product contract.
 *
 * The iOS client sets a normal `Authorization: Bearer <token>` header on
 * its WebSocket upgrade request (`URLSessionWebSocketTask` supports
 * arbitrary headers, unlike the browser `WebSocket` constructor), so
 * `requireAuth` covers this route exactly like every other authenticated
 * route in this worker — no subprotocol-smuggled credential needed.
 */
export const voiceSessionsRoutes = new Hono<{
  Bindings: Env;
  Variables: { userId: string };
}>();

voiceSessionsRoutes.get("/:id/control", requireAuth, async (c) => {
  if (c.req.header("upgrade")?.toLowerCase() !== "websocket") {
    return c.json({ error: "expected_websocket" }, 426);
  }

  const rishiSessionId = c.req.param("id");
  const userId = c.get("userId");
  const stub = c.env.USER_USAGE_LEDGER.getByName(userId);

  const snapshot = await stub.getSessionSnapshot(rishiSessionId);
  if (!snapshot) {
    return c.json({ error: "no_active_session" }, 404);
  }
  if (snapshot.status === "terminal") {
    return c.json({ error: "session_ended" }, 404);
  }

  // The DO's own fetch() re-validates and performs the actual upgrade —
  // forward the raw request so the Upgrade/Connection headers survive.
  return stub.fetch(c.req.raw);
});
