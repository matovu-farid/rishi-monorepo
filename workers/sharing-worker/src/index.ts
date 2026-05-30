import { Hono } from "hono";
import { CreateSessionBody } from "./schemas";
import { issueJoinToken } from "./tokens";
import { verifyAuth } from "./auth";

type Env = {
  SESSION_ROOM: DurableObjectNamespace;
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
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

async function getUser(req: Request, env: Env) {
  // Test-mode shortcut: a global stub is set in beforeEach when present.
  const stub = (globalThis as any).__TEST_AUTH__;
  if (stub) return stub;
  return verifyAuth(req, env);
}

export default app;
export { SessionRoom } from "./SessionRoom";
