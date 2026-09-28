import { Hono } from "hono";
import { CreateSessionBody, RedeemBody } from "./legacySchemas";
import { issueJoinToken, verifyJoinToken } from "./tokens";
import { AuthVerificationError, verifyAuth, resolveTestGlobalAuth, verifyAuthRequestEffect } from "./auth";
import { GlobalLimiter } from "./perIpLimit";
import { UserSearchBody, searchUsers } from "./userSearch";
import type { AppleSessionRoom } from "./AppleSessionRoom";
import { Cause, Effect, Exit, Option } from "effect";
import {
  InternalCommandVerifier,
  makeSharingWorkerLayer,
  SharingDiagnostics,
  summarizeDiagnosticCause,
  type SharingDiagnostic,
} from "./session-sharing-effect";
import {
  InternalAuthorizationFailure,
  InvalidInternalCommandFailure,
  RoomRpcFailure,
} from "./session-sharing-errors";

const createSessionLimiter = new GlobalLimiter({ capacity: 10, windowMs: 60 * 60_000 });
const redeemLimiter = new GlobalLimiter({ capacity: 5, windowMs: 60_000 });
const userSearchLimiter = new GlobalLimiter({ capacity: 30, windowMs: 60_000 });

type Env = {
  SESSION_ROOM: DurableObjectNamespace;
  APPLE_SESSION_ROOM: DurableObjectNamespace<AppleSessionRoom>;
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
  /** "1" enables the `userId--DisplayName` bearer shortcut in verifyAuth. E2E only. */
  TEST_AUTH_ALLOWED?: string;
  ENVIRONMENT?: string;
};

const app = new Hono<{ Bindings: Env; Variables: { rishiCorrelationId: string } }>();

app.use("/v2/*", async (c, next) => {
  const requestCorrelationId = correlationId(c.req.raw);
  c.set("rishiCorrelationId", requestCorrelationId);
  c.header("X-Rishi-Correlation-ID", requestCorrelationId);
  const json = c.json.bind(c);
  (c as any).json = (body: unknown, status?: number, headers?: HeadersInit) => {
    if (body && typeof body === "object" && "code" in body && typeof (body as { code?: unknown }).code === "string") {
      c.header("X-Rishi-Error-Code", (body as { code: string }).code);
      c.header("X-Rishi-Error-Stage", c.req.path.includes("/turn") ? "turn.credentials" : "internal.room-command");
    }
    const correlated = body && typeof body === "object" && !Array.isArray(body)
      ? { ...body, correlationId: requestCorrelationId }
      : body;
    return json(correlated, status as any, headers as any);
  };
  await next();
});

const SAFE_DIAGNOSTIC_CODES = new Set([
  "ACCOUNT_DELETED", "ADMISSION_TICKET_EXPIRED", "ADMISSION_TICKET_MISMATCH", "ADMISSION_TICKET_STALE", "AUTH_REQUIRED",
  "ADMISSION_REQUIRED", "FORBIDDEN", "INVALID_ADMISSION", "MALFORMED_WEBSOCKET_REQUEST", "ROOM_FULL",
  "INTERNAL_ERROR", "SERVICE_UNAVAILABLE", "SESSION_ENDED", "SESSION_NOT_FOUND", "TURN_UNAVAILABLE", "WEBSOCKET_UPGRADE_REQUIRED",
]);

function wssFailure(env: Env, status: number, code: string, stage: string, requestCorrelationId: string): Response {
  const safeCode = SAFE_DIAGNOSTIC_CODES.has(code) ? code : "INTERNAL_ERROR";
  console.warn(JSON.stringify({ event: "sharing.wss.rejected", correlationId: requestCorrelationId, operation: "websocket.connect", stage, code: safeCode, status }));
  const headers = new Headers({
    "content-type": "application/json; charset=UTF-8",
    "x-rishi-correlation-id": requestCorrelationId,
    "x-rishi-error-code": safeCode,
    "x-rishi-error-stage": stage,
  });
  return new Response(JSON.stringify({
    code: safeCode,
    error: safeCode === "AUTH_REQUIRED" ? "Sign in to use this reading session." : "Could not connect to the reading session.",
    correlationId: requestCorrelationId,
    ...(env.ENVIRONMENT === "development" || env.ENVIRONMENT === "staging" ? { diagnostic: `${stage}:${safeCode}` } : {}),
  }), { status, headers });
}

function turnFailure(status: number, code: string, stage: string, requestCorrelationId: string): Response {
  const safeCode = SAFE_DIAGNOSTIC_CODES.has(code) ? code : "TURN_UNAVAILABLE";
  console.warn(JSON.stringify({ event: "sharing.turn.failed", correlationId: requestCorrelationId, operation: "turn.credentials", stage, code: safeCode, status }));
  return Response.json({ code: safeCode, error: safeCode === "AUTH_REQUIRED" ? "Sign in to use this reading session." : "Audio connection is unavailable.", correlationId: requestCorrelationId }, {
    status,
    headers: { "x-rishi-correlation-id": requestCorrelationId, "x-rishi-error-code": safeCode, "x-rishi-error-stage": stage },
  });
}

app.onError((error, c) => {
  if (!c.req.path.startsWith("/v2/")) {
    if ("getResponse" in error && typeof error.getResponse === "function") {
      const response = error.getResponse();
      return c.newResponse(response.body, response);
    }
    console.error(error);
    return c.text("Internal Server Error", 500);
  }

  const isAuthError = error instanceof AuthVerificationError;
  const code = isAuthError ? error.code : "INTERNAL_ERROR";
  const status = isAuthError ? error.status : 500;
  const stage = isAuthError
    ? "auth.provider"
    : c.req.path.includes("/turn")
      ? "turn.credentials"
      : c.req.path.includes("/wss")
        ? "websocket.room"
        : "internal.room-command";
  const requestCorrelationId = c.get("rishiCorrelationId") ?? correlationId(c.req.raw);
  console.error(JSON.stringify({
    event: "sharing.request.failed",
    correlationId: requestCorrelationId,
    operation: c.req.path.includes("/turn") ? "turn.credentials" : c.req.path.includes("/wss") ? "websocket.connect" : "room.command",
    stage,
    code,
    status,
  }));
  return new Response(JSON.stringify({
    code,
    error: code === "AUTH_REQUIRED" ? "Sign in to use this reading session." : "The reading session request could not be completed.",
    correlationId: requestCorrelationId,
    ...(c.env.ENVIRONMENT === "development" || c.env.ENVIRONMENT === "staging" ? { diagnostic: `${stage}:${code}` } : {}),
  }), {
    status,
    headers: {
      "content-type": "application/json; charset=UTF-8",
      "x-rishi-correlation-id": requestCorrelationId,
      "x-rishi-error-code": code,
      "x-rishi-error-stage": stage,
    },
  });
});

function correlationId(request: Request): string {
  const value = request.headers.get("x-rishi-correlation-id");
  // Correlation identifiers are opaque diagnostics handles, never identities.
  return value && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
    ? value
    : crypto.randomUUID();
}

function logInternalOutcome(correlationId: string, action: string, outcome: "ok" | "error", startedAt: number, code: string, status: number): void {
  console.log(JSON.stringify({
    event: "sharing.internal.command",
    correlationId,
    operation: action,
    stage: "internal.room-command",
    outcome,
    code,
    status,
    durationMs: Date.now() - startedAt,
  }));
}

const INTERNAL_ERROR_CODES = new Set([
  "ACCOUNT_DELETED", "ALREADY_INITIALIZED", "BOOK_HASH_MISMATCH", "CONFLICT", "FORBIDDEN",
  "INVALID_COMMAND", "NO_SUCH_PARTICIPANT", "OBSERVATION_CURSOR_EXPIRED", "REMOVED_FROM_SESSION",
  "ROOM_FULL", "SESSION_ENDED", "SESSION_NOT_FOUND", "STALE_CONTROLLER_GENERATION", "SERVICE_UNAVAILABLE",
]);

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
  revokeAccountReferences: "revokeAccountReferences",
  getMemberObservations: "getMemberObservations",
  purgeAppleRoom: "purgeAppleRoom",
} as const;

function internalStatus(code: string): 400 | 401 | 403 | 404 | 409 | 410 | 500 | 503 {
  if (code === "ROOM_FULL" || code === "CONFLICT") return 409;
  if (code === "FORBIDDEN") return 403;
  if (code === "SESSION_NOT_FOUND") return 404;
  if (code === "SESSION_ENDED") return 410;
  if (code === "SERVICE_UNAVAILABLE" || code === "TURN_UNAVAILABLE") return 503;
  if (code === "INTERNAL_ERROR") return 500;
  return 400;
}

function suppliedErrorCode(error: unknown): unknown {
  return error && typeof error === "object" && "code" in error ? error.code : undefined;
}

function emitEffectFailure(
  env: Env,
  requestCorrelationId: string,
  operation: string,
  stage: SharingDiagnostic["stage"],
  code: string,
  status: number,
  cause: Cause.Cause<unknown>,
): Promise<void> {
  const diagnostic: SharingDiagnostic = {
    event: "sharing.request.failed",
    correlationId: requestCorrelationId,
    operation,
    stage,
    outcome: "error",
    code,
    status,
    causeKind: summarizeDiagnosticCause(cause),
  };
  const program = Effect.gen(function* () {
    const diagnostics = yield* SharingDiagnostics;
    yield* diagnostics.emit(diagnostic);
  }).pipe(Effect.catchAllCause(() => Effect.void));
  return Effect.runPromise(Effect.provide(program, makeSharingWorkerLayer(env)));
}

/** Primary Worker → sharing Worker command surface. The signed claims bind the
 * action to the exact path and JSON body so a bearer cannot be replayed for a
 * different room or mutation. */
app.post("/v2/internal/rooms/:id", async (c) => {
  const requestCorrelationId = c.get("rishiCorrelationId");
  const startedAt = Date.now();
  const token = c.req.header("x-rishi-internal-token");
  const id = c.req.param("id");
  const program = Effect.gen(function* () {
    if (!token) return yield* Effect.fail(new InternalAuthorizationFailure("missing"));
    const body = yield* Effect.tryPromise({
      try: () => c.req.json() as Promise<{ action?: unknown; payload?: unknown }>,
      catch: () => null,
    }).pipe(Effect.catchAll(() => Effect.succeed(null)));
    if (!body || typeof body.action !== "string" || !(body.action in INTERNAL_ACTIONS)) {
      return yield* Effect.fail(new InvalidInternalCommandFailure(body ? "invalid_action" : "invalid_body"));
    }
    const verifier = yield* InternalCommandVerifier;
    const claims = yield* verifier.verify(token, c.env.WORKER_HMAC_SECRET);
    if (claims.exp <= Date.now()) return yield* Effect.fail(new InternalAuthorizationFailure("expired"));
    if (claims.method !== "POST" || claims.path !== c.req.path || JSON.stringify(claims.body) !== JSON.stringify(body)) {
      return yield* Effect.fail(new InternalAuthorizationFailure("claims_mismatch"));
    }
    if (body.action === "createRoom") {
      const payload = body.payload as { sessionId?: unknown } | null;
      if (!payload || payload.sessionId !== id) {
        return yield* Effect.fail(new InvalidInternalCommandFailure("session_mismatch"));
      }
    }
    const stub = c.env.APPLE_SESSION_ROOM.get(c.env.APPLE_SESSION_ROOM.idFromName(id));
    return yield* Effect.tryPromise({
      try: () => stub.executeInternal({
        action: INTERNAL_ACTIONS[body.action as keyof typeof INTERNAL_ACTIONS],
        payload: body.payload ?? {},
        correlationId: requestCorrelationId,
      }) as Promise<unknown>,
      catch: (cause) => new RoomRpcFailure(suppliedErrorCode(cause), cause),
    });
  });
  const exit = await Effect.runPromiseExit(Effect.provide(program, makeSharingWorkerLayer(c.env)));
  if (Exit.isFailure(exit)) {
    const failureOption = Cause.failureOption(exit.cause);
    const failure = Option.isSome(failureOption) ? failureOption.value : undefined;
    if (failure instanceof InternalAuthorizationFailure) {
      const message = failure.reason === "missing" ? "missing internal authorization" : "invalid internal authorization";
      await emitEffectFailure(c.env, requestCorrelationId, "internal.authorization", "internal.authorization", "SERVICE_UNAVAILABLE", 401, exit.cause);
      logInternalOutcome(requestCorrelationId, "internal.authorization", "error", startedAt, "SERVICE_UNAVAILABLE", 401);
      return c.json({ code: "SERVICE_UNAVAILABLE", error: message }, 401);
    }
    if (failure instanceof InvalidInternalCommandFailure) {
      await emitEffectFailure(c.env, requestCorrelationId, "internal.command", "internal.room-command", "INVALID_COMMAND", 400, exit.cause);
      logInternalOutcome(requestCorrelationId, "internal.command", "error", startedAt, "INVALID_COMMAND", 400);
      return failure.reason === "session_mismatch"
        ? c.json({ code: "INVALID_COMMAND", error: "sessionId must match room path" }, 400)
        : c.json({ code: "INVALID_COMMAND" }, 400);
    }
    const suppliedCode = failure instanceof RoomRpcFailure ? failure.suppliedCode : undefined;
    const code = typeof suppliedCode === "string" && INTERNAL_ERROR_CODES.has(suppliedCode) ? suppliedCode : "SERVICE_UNAVAILABLE";
    const status = code === "SERVICE_UNAVAILABLE" ? 503 : internalStatus(code);
    await emitEffectFailure(c.env, requestCorrelationId, "room.command", "internal.room-command", code, status, exit.cause);
    logInternalOutcome(requestCorrelationId, "room.command", "error", startedAt, code, status);
    return c.json({ code, error: "Room command could not be completed" }, status);
  }
  const result = exit.value;
  if (
    result &&
    typeof result === "object" &&
    "ok" in result &&
    result.ok === false &&
    "code" in result &&
    "error" in result &&
    typeof result.code === "string"
  ) {
    const failure = result as { ok: false; code: string; error: string };
    const code = INTERNAL_ERROR_CODES.has(failure.code) ? failure.code : "SERVICE_UNAVAILABLE";
    const status = internalStatus(code);
    logInternalOutcome(requestCorrelationId, "room.command", "error", startedAt, code, status);
    return c.json({
      ok: false,
      code,
      error: typeof failure.error === "string" ? failure.error : "Room command could not be completed",
    }, status);
  }
  logInternalOutcome(requestCorrelationId, "room.command", "ok", startedAt, "OK", 200);
  return c.json(result ?? { ok: true });
});

app.get("/v2/sessions/:id/turn", async (c) => {
  const requestCorrelationId = c.get("rishiCorrelationId");
  const sessionId = c.req.param("id");
  const program = Effect.gen(function* () {
    const user = yield* getUserEffect(c.req.raw, c.env, requestCorrelationId);
    const stub = c.env.APPLE_SESSION_ROOM.get(c.env.APPLE_SESSION_ROOM.idFromName(sessionId));
    return yield* Effect.tryPromise({
      try: () => stub.getTurnCredentials({
        userId: user.userId,
        ttlSeconds: Number(c.req.query("ttl") ?? 3600),
        correlationId: requestCorrelationId,
      }) as Promise<unknown>,
      catch: (cause) => new RoomRpcFailure(suppliedErrorCode(cause), cause),
    });
  });
  const exit = await Effect.runPromiseExit(Effect.provide(program, makeSharingWorkerLayer(c.env)));
  if (Exit.isFailure(exit)) {
    const failureOption = Cause.failureOption(exit.cause);
    const failure = Option.isSome(failureOption) ? failureOption.value : undefined;
    if (failure instanceof AuthVerificationError) {
      await emitEffectFailure(c.env, requestCorrelationId, "turn.credentials", "auth.provider", failure.code, failure.status, exit.cause);
      return turnFailure(failure.status, failure.code, "auth.provider", requestCorrelationId);
    }
    const code = failure instanceof RoomRpcFailure && typeof failure.suppliedCode === "string"
      ? failure.suppliedCode
      : "TURN_UNAVAILABLE";
    await emitEffectFailure(c.env, requestCorrelationId, "turn.credentials", "turn.credentials", code, code === "FORBIDDEN" ? 403 : 503, exit.cause);
    return turnFailure(code === "FORBIDDEN" ? 403 : 503, code, "turn.room", requestCorrelationId);
  }
  const result = exit.value;
  if (result && typeof result === "object" && "ok" in result && result.ok === false && "code" in result && "error" in result) {
    const failure = result as { code: string; error: string };
    return turnFailure(internalStatus(failure.code), failure.code, "turn.room", requestCorrelationId);
  }
  return c.json(result);
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

function getUserEffect(req: Request, env: Env, requestCorrelationId: string) {
  const stub = resolveTestGlobalAuth(env.TEST_AUTH_ALLOWED);
  return stub
    ? Effect.succeed(stub)
    : verifyAuthRequestEffect(req, env, requestCorrelationId);
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

app.get("/v2/sessions/:id/wss", async (c) => {
  const requestCorrelationId = c.get("rishiCorrelationId");
  if (c.req.header("upgrade") !== "websocket") {
    return wssFailure(c.env, 426, "WEBSOCKET_UPGRADE_REQUIRED", "websocket.upgrade", requestCorrelationId);
  }
  const creds = (await import("./wsCreds")).parseSubprotocols(c.req.header("sec-websocket-protocol") ?? null);
  if (!creds.valid) return wssFailure(c.env, creds.reason === "missing jwt" ? 401 : 400, creds.reason === "missing jwt" ? "AUTH_REQUIRED" : "MALFORMED_WEBSOCKET_REQUEST", creds.reason === "missing jwt" ? "websocket.authentication" : "websocket.protocol", requestCorrelationId);
  if (!creds.jwt) return wssFailure(c.env, 401, "AUTH_REQUIRED", "websocket.authentication", requestCorrelationId);
  if (!creds.admissionTicket) return wssFailure(c.env, 401, "ADMISSION_REQUIRED", "websocket.admission", requestCorrelationId);

  const sessionId = c.req.param("id");
  const stub = c.env.APPLE_SESSION_ROOM.get(c.env.APPLE_SESSION_ROOM.idFromName(sessionId));
  const headers = new Headers(c.req.raw.headers);
  headers.set("x-rishi-session-kind", "apple");
  headers.set("x-rishi-correlation-id", requestCorrelationId);
  const program = Effect.gen(function* () {
    const response = yield* Effect.tryPromise({
      try: () => stub.fetch(new Request(c.req.raw, { headers })),
      catch: (cause) => new RoomRpcFailure(suppliedErrorCode(cause), cause),
    });
    if (response.status === 101 || response.status < 400) return response;
    if (response.headers.has("x-rishi-correlation-id") && response.headers.has("x-rishi-error-code")) return response;

    const headerCode = response.headers.get("x-rishi-error-code");
    const bodyCode = headerCode
      ? undefined
      : yield* Effect.tryPromise({
        try: async () => (await response.clone().json() as { code?: unknown }).code,
        catch: () => undefined,
      }).pipe(Effect.catchAll(() => Effect.succeed(undefined)));
    const candidateCode = headerCode ?? bodyCode;
    const code = typeof candidateCode === "string" && SAFE_DIAGNOSTIC_CODES.has(candidateCode)
      ? candidateCode
      : response.status === 401 ? "AUTH_REQUIRED"
        : response.status === 403 ? "FORBIDDEN"
          : response.status === 404 ? "SESSION_NOT_FOUND"
            : response.status === 410 ? "SESSION_ENDED"
              : "INTERNAL_ERROR";
    return wssFailure(c.env, response.status, code, "websocket.room", requestCorrelationId);
  });
  const exit = await Effect.runPromiseExit(Effect.provide(program, makeSharingWorkerLayer(c.env)));
  if (Exit.isFailure(exit)) {
    await emitEffectFailure(c.env, requestCorrelationId, "websocket.connect", "websocket.room", "INTERNAL_ERROR", 500, exit.cause);
    return wssFailure(c.env, 500, "INTERNAL_ERROR", "websocket.room", requestCorrelationId);
  }
  return exit.value;
});

export default app;
export { SessionRoom } from "./SessionRoom";
export { AppleSessionRoom } from "./AppleSessionRoom";
