import { Hono } from "hono";
import { CreateSessionBody, RedeemBody } from "./schemas";
import { issueJoinToken, verifyJoinToken } from "./tokens";
import { verifyAuth, resolveTestGlobalAuth } from "./auth";
import { GlobalLimiter } from "./perIpLimit";
import { UserSearchBody, searchUsers } from "./userSearch";
import { verify } from "./hmac";

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

const INTERNAL_ACTIONS = {
  createRoom: "createRoom",
  getRoomStatus: "getRoomStatus",
  getRedeemInfo: "getAppleRedeemInfo",
  issueAdmissionTicket: "markBookReadyAndIssueAdmissionTicket",
  startRoom: "startRoom",
  leaveRoom: "leaveRoom",
  transferController: "transferController",
  removeParticipant: "removeAppleParticipant",
  restoreParticipant: "restoreAppleParticipant",
  endRoom: "endRoom",
} as const;

type InternalClaims = { method: string; path: string; body: unknown; exp: number };

/** Primary Worker → sharing Worker command surface. The signed claims bind the
 * action to the exact path and JSON body so a bearer cannot be replayed for a
 * different room or mutation. */
app.post("/internal/rooms/:id", async (c) => {
  const token = c.req.header("x-rishi-internal-token");
  if (!token) return c.json({ code: "SERVICE_UNAVAILABLE", error: "missing internal authorization" }, 401);
  const body = await c.req.json().catch(() => null) as { action?: string; payload?: unknown } | null;
  if (!body || typeof body.action !== "string" || !(body.action in INTERNAL_ACTIONS)) return c.json({ code: "INVALID_COMMAND" }, 400);
  let claims: InternalClaims;
  try { claims = await verify<InternalClaims>(token, c.env.WORKER_HMAC_SECRET); }
  catch { return c.json({ code: "SERVICE_UNAVAILABLE", error: "invalid internal authorization" }, 401); }
  if (claims.exp <= Date.now() || claims.method !== "POST" || claims.path !== c.req.path || JSON.stringify(claims.body) !== JSON.stringify(body)) {
    return c.json({ code: "SERVICE_UNAVAILABLE", error: "invalid internal authorization" }, 401);
  }
  const id = c.req.param("id");
  const stub = c.env.SESSION_ROOM.get(c.env.SESSION_ROOM.idFromName(id));
  try {
    const method = INTERNAL_ACTIONS[body.action as keyof typeof INTERNAL_ACTIONS];
    // @ts-expect-error Durable Object RPC method is selected from a fixed allowlist.
    const result = await stub[method](body.payload ?? {});
    return c.json(result ?? { ok: true });
  } catch (e) {
    const error = e as { code?: string; message?: string };
    const code = error.code ?? "SERVICE_UNAVAILABLE";
    const status = code === "ROOM_FULL" ? 409 : code === "FORBIDDEN" ? 403 : code === "SESSION_NOT_FOUND" ? 404 : 400;
    return c.json({ code, error: error.message ?? code }, status as 400 | 401 | 403 | 404 | 409);
  }
});

app.get("/v1/sessions/:id/turn", async (c) => {
  let user;
  try { user = await getUser(c.req.raw, c.env); }
  catch (e) { return c.json({ code: "AUTH_REQUIRED", error: (e as Error).message }, 401); }
  const sessionId = c.req.param("id");
  const stub = c.env.SESSION_ROOM.get(c.env.SESSION_ROOM.idFromName(sessionId));
  try {
    // @ts-expect-error RPC on the Durable Object stub.
    return c.json(await stub.getTurnCredentials({ userId: user.userId, ttlSeconds: Number(c.req.query("ttl") ?? 3600) }));
  } catch (e) {
    const error = e as { code?: string; message?: string };
    return c.json({ code: error.code ?? "TURN_UNAVAILABLE", error: error.message ?? "TURN credentials unavailable" }, error.code === "FORBIDDEN" ? 403 : 503);
  }
});

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
  // Test-mode shortcut: a global stub is honored ONLY when
  // TEST_AUTH_ALLOWED === "1" (see resolveTestGlobalAuth).
  const stub = resolveTestGlobalAuth(env.TEST_AUTH_ALLOWED);
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
