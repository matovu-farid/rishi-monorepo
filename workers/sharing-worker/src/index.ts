import { Hono } from "hono";
import { CreateSessionBody, RedeemBody } from "./schemas";
import { issueJoinToken, verifyJoinToken } from "./tokens";
import { verifyAuth } from "./auth";
import { GlobalLimiter } from "./perIpLimit";
import { UserSearchBody, searchUsers } from "./userSearch";

const createSessionLimiter = new GlobalLimiter({ capacity: 10, windowMs: 60 * 60_000 });
const redeemLimiter = new GlobalLimiter({ capacity: 5, windowMs: 60_000 });
const userSearchLimiter = new GlobalLimiter({ capacity: 30, windowMs: 60_000 });

type Env = {
  SESSION_ROOM: DurableObjectNamespace;
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
  /** "1" enables the `userId--DisplayName` bearer shortcut in verifyAuth. E2E only. */
  TEST_AUTH_ALLOWED?: string;
};

const app = new Hono<{ Bindings: Env }>();

app.get("/health", (c) => c.text("ok"));

app.post("/v1/sessions", async (c) => {
  let user;
  try {
    user = await getUser(c.req.raw, c.env);
  } catch (e) {
    return c.json({ error: (e as Error).message }, 401);
  }
  const parsed = CreateSessionBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid body", issues: parsed.error.issues }, 400);

  if (!createSessionLimiter.allow(user.userId)) return c.json({ error: "rate_limited" }, 429);

  const sessionId = "s_" + crypto.randomUUID();
  const stub = c.env.SESSION_ROOM.get(c.env.SESSION_ROOM.idFromName(sessionId));
  // @ts-expect-error RPC on DO stub
  await stub.createSession({
    sessionId,
    hostUserId: user.userId,
    hostProfile: { displayName: user.displayName, avatarUrl: user.avatarUrl },
    bookContext: parsed.data.bookContext,
    requiresApproval: parsed.data.requiresApproval,
  });
  const { token: joinToken } = await issueJoinToken(
    { sessionId, ttlMs: 24 * 60 * 60_000 },
    c.env.WORKER_HMAC_SECRET,
  );
  const wsUrl = new URL(c.req.url);
  wsUrl.pathname = `/v1/sessions/${sessionId}/wss`;
  wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
  return c.json({
    sessionId,
    joinToken,
    joinUrl: `rishi://sharing/join?t=${joinToken}`,
    wsUrl: wsUrl.toString(),
  });
});

app.post("/v1/sessions/:id/redeem", async (c) => {
  try { await getUser(c.req.raw, c.env); }
  catch (e) { return c.json({ error: (e as Error).message }, 401); }
  const parsed = RedeemBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid body" }, 400);

  const ip = c.req.header("cf-connecting-ip") ?? "unknown";
  if (!redeemLimiter.allow(`${ip}:${c.req.param("id")}`)) return c.json({ error: "rate_limited" }, 429);

  let payload;
  try { payload = await verifyJoinToken(parsed.data.joinToken, c.env.WORKER_HMAC_SECRET); }
  catch (e) { return c.json({ code: "token_invalid", error: (e as Error).message }, 400); }

  const sessionId = c.req.param("id");
  if (payload.sessionId !== sessionId) return c.json({ code: "token_invalid" }, 400);

  const stub = c.env.SESSION_ROOM.get(c.env.SESSION_ROOM.idFromName(sessionId));
  // @ts-expect-error RPC on DO stub
  const info = await stub.getInfoForRedeem();
  if (!info) return c.json({ code: "session_ended" }, 404);
  if (info.status === "ended") return c.json({ code: "session_ended" }, 404);

  const wsUrl = new URL(c.req.url);
  wsUrl.pathname = `/v1/sessions/${sessionId}/wss`;
  wsUrl.protocol = wsUrl.protocol === "https:" ? "wss:" : "ws:";
  return c.json({
    sessionId,
    bookContext: info.bookContext,
    requiresApproval: info.requiresApproval,
    hostProfile: info.hostProfile,
    wsUrl: wsUrl.toString(),
  });
});

app.post("/v1/users/search", async (c) => {
  let user;
  try { user = await getUser(c.req.raw, c.env); }
  catch (e) { return c.json({ error: (e as Error).message }, 401); }

  const parsed = UserSearchBody.safeParse(await c.req.json().catch(() => ({})));
  if (!parsed.success) return c.json({ error: "invalid body", issues: parsed.error.issues }, 400);

  if (!userSearchLimiter.allow(user.userId)) return c.json({ error: "rate_limited" }, 429);

  const bearer = (c.req.header("authorization") ?? "").replace(/^Bearer\s+/i, "");
  const users = await searchUsers({
    q: parsed.data.q,
    authBaseUrl: c.env.AUTH_BASE_URL,
    bearer,
  });
  return c.json({ users });
});

async function getUser(req: Request, env: Env) {
  // Test-mode shortcut: a global stub is set in beforeEach when present.
  const stub = (globalThis as any).__TEST_AUTH__;
  if (stub) return stub;
  return verifyAuth(req, env);
}

app.get("/v1/sessions/:id/wss", async (c) => {
  if (c.req.header("upgrade") !== "websocket") {
    return c.text("Expected websocket", 426);
  }
  const creds = (await import("./wsCreds")).parseSubprotocols(c.req.header("sec-websocket-protocol") ?? null);
  if (!creds.valid) return c.text(creds.reason, 400);

  const sessionId = c.req.param("id");
  const stub = c.env.SESSION_ROOM.get(c.env.SESSION_ROOM.idFromName(sessionId));
  // The DO's fetch handles the upgrade.
  return stub.fetch(c.req.raw);
});

export default app;
export { SessionRoom } from "./SessionRoom";
