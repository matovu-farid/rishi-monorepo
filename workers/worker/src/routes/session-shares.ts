import { Hono } from "hono";
import { Cause, Effect, Exit, Layer, Option } from "effect";
import { and, eq } from "drizzle-orm";
import { books, sessionInviteRedemptions, sessionInvites } from "../db/schema";
import { requireAuth } from "../middleware";
import { SessionSharingService, SessionSharingServiceError } from "../session-sharing-service";
import { isSessionSharingFailure, SessionSharingDomainFailure, toSessionSharingServiceError } from "../session-sharing-errors";
import { makeSessionInviteEmailDeliveryLayer, sendSessionInviteEmails, SessionInviteEmailDelivery } from "../session-invite-email";
import {
  activeSessions,
  authContext,
  bookReady,
  createSession,
  makeSessionSharingUseCaseLayer,
  readSession,
  redeemSession,
  rejoinSession,
  SessionSharingArtifacts,
  SessionSharingPersistence,
  SessionSharingProfileLookup,
  SessionSharingRouteFailure,
  turnCredentials,
} from "../session-sharing-use-cases";
import type { SessionSharingFailure } from "../session-sharing-errors";
import {
  SessionSharingDiagnostics,
  SessionSharingTransport,
} from "../session-sharing-effect-services";

type SessionEnv = Env & {
  SHARING_WORKER: { fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> };
  SHARING_INTERNAL_SECRET: string;
  SHARING_WORKER_WS_URL?: string;
  BETTER_AUTH_SECRET: string;
  ENVIRONMENT?: string;
};
type SessionContext = { Bindings: SessionEnv; Variables: { userId: string } };
const routes = new Hono<SessionContext>();
// Session invitations deliberately use the dedicated join host. It has the
// Universal Link association and a focused fallback page, unlike the general
// product site.
const SESSION_SHARE_PUBLIC_ORIGIN = "https://join.rishi.fidexa.org";

type SharingErrorAction = "signIn" | "retry" | "manualRetry" | "dismiss" | "removeAndRetry";
const SAFE_SHARING_ERROR_CODES = new Set([
  "ACCOUNT_DELETED", "ACCOUNT_DELETION_IN_PROGRESS", "ADMISSION_TICKET_EXPIRED", "ADMISSION_TICKET_MISMATCH",
  "ADMISSION_TICKET_STALE", "ALREADY_INITIALIZED", "AUTH_REQUIRED", "BAD_REQUEST", "BOOK_HASH_MISMATCH",
  "BOOK_NOT_READY", "CONFLICT", "FORBIDDEN", "HTTP_ERROR", "INTERNAL_ERROR", "INVALID_COMMAND",
  "INVALID_RESPONSE", "NETWORK_ERROR", "NO_SUCH_PARTICIPANT", "RATE_LIMITED", "REMOVED_FROM_SESSION",
  "ROOM_FULL", "SERVICE_UNAVAILABLE", "SESSION_ENDED", "SESSION_LINK_INVALID", "SESSION_NOT_FOUND",
  "STALE_CONTROLLER_GENERATION", "TURN_UNAVAILABLE", "USERNAME_UNAVAILABLE",
]);

function correlationId(c: any): string {
  const existing = (c as any).get("sharingCorrelationId") as string | undefined;
  if (existing) return existing;
  const supplied = c.req.header("x-rishi-correlation-id");
  const value = supplied && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(supplied)
    ? supplied
    : crypto.randomUUID();
  (c as any).set("sharingCorrelationId", value);
  return value;
}

function isNonProduction(c: any): boolean {
  return c.env.ENVIRONMENT === "development" || c.env.ENVIRONMENT === "staging";
}

function operationFor(c: any): { operation: string; stage: string } {
  const path = String(c.req.path ?? "").replace(/\/[^/]+(?=\/|$)/g, (part: string) =>
    /^\/[0-9a-f-]{16,}$/i.test(part) ? "/:id" : part,
  );
  if (path.endsWith("/turn")) return { operation: "turn.credentials", stage: "sharing.turn" };
  if (path.endsWith("/book-ready") || path.endsWith("/rejoin")) return { operation: "session.admission", stage: "sharing.admission" };
  if (path.endsWith("/redeem")) return { operation: "session.redeem", stage: "sharing.redeem" };
  if (path.endsWith("/email")) return { operation: "session.invitation", stage: "sharing.invitation" };
  if (/\/sessions\/[^/]+$/.test(path) && c.req.method === "GET") return { operation: "session.status", stage: "sharing.status" };
  if (c.req.method === "POST" && path.endsWith("/sessions")) return { operation: "session.create", stage: "sharing.create" };
  return { operation: "session.request", stage: "sharing.route" };
}

function errorDetails(code: string): { retryable: boolean; action: SharingErrorAction; message: string } {
  switch (code) {
    case "AUTH_REQUIRED": return { retryable: false, action: "signIn", message: "Sign in to use this reading session." };
    case "ACCOUNT_DELETED": return { retryable: false, action: "dismiss", message: "This account is no longer available." };
    case "ACCOUNT_DELETION_IN_PROGRESS": return { retryable: false, action: "dismiss", message: "Account deletion is in progress. This action is unavailable." };
    case "SESSION_ENDED":
    case "SESSION_LINK_INVALID":
    case "REMOVED_FROM_SESSION":
    case "FORBIDDEN": return { retryable: false, action: "dismiss", message: "This reading session is no longer available." };
    case "BOOK_HASH_MISMATCH": return { retryable: true, action: "removeAndRetry", message: "The downloaded book could not be verified." };
    case "ROOM_FULL": return { retryable: true, action: "manualRetry", message: "This reading room is full." };
    case "RATE_LIMITED": return { retryable: true, action: "retry", message: "Too many requests. Please try again shortly." };
    case "USERNAME_UNAVAILABLE": return { retryable: true, action: "retry", message: "The account service is temporarily unavailable." };
    default: return { retryable: true, action: "retry", message: "Rishi could not complete this reading-session action." };
  }
}

function failureCodeFor(status: number, errorText?: string): string {
  if (status === 401) return "AUTH_REQUIRED";
  if (status === 403) return "FORBIDDEN";
  if (status === 404) return "SESSION_NOT_FOUND";
  if (status === 410) return errorText === "Account deleted" ? "ACCOUNT_DELETED" : "SESSION_ENDED";
  if (status === 423) return "ACCOUNT_DELETION_IN_PROGRESS";
  if (status === 429) return "RATE_LIMITED";
  if (status === 400 || status === 422) return "BAD_REQUEST";
  if (status === 409) return "CONFLICT";
  if (status === 502 || status === 503 || status === 504) return "SERVICE_UNAVAILABLE";
  return "INTERNAL_ERROR";
}

function sharingError(c: any, code: string, status: number, stage?: string, diagnostic?: string) {
  const safeCode = SAFE_SHARING_ERROR_CODES.has(code) ? code : "INTERNAL_ERROR";
  const details = errorDetails(safeCode);
  const requestCorrelationId = correlationId(c);
  const context = operationFor(c);
  const errorStage = stage ?? context.stage;
  console.warn(JSON.stringify({ event: "sharing.request.error", correlationId: requestCorrelationId, operation: context.operation, stage: errorStage, code: safeCode, status }));
  c.header("X-Rishi-Correlation-ID", requestCorrelationId);
  c.header("X-Rishi-Error-Code", safeCode);
  c.header("X-Rishi-Error-Stage", errorStage);
  const json = (c as any).get("sharingOriginalJson") as ((body: unknown, status?: number) => Response) | undefined;
  return (json ?? c.json.bind(c))({
    code: safeCode,
    error: details.message,
    retryable: details.retryable,
    action: details.action,
    correlationId: requestCorrelationId,
    ...(isNonProduction(c) ? { diagnostic: diagnostic ?? `${errorStage}:${safeCode}` } : {}),
  }, status);
}

// Every session-sharing failure uses the same client-safe envelope. The route
// bodies below remain terse while this boundary prevents internal messages,
// identifiers, and provider responses from escaping to the client.
routes.use("*", async (c, next) => {
  const requestCorrelationId = correlationId(c);
  c.header("X-Rishi-Correlation-ID", requestCorrelationId);
  const json = c.json.bind(c);
  (c as any).set("sharingOriginalJson", json);
  (c as any).json = (body: unknown, status?: number, headers?: HeadersInit) => {
    const value = body && typeof body === "object" && !Array.isArray(body)
      ? body as { code?: unknown; error?: unknown }
      : {};
    const responseStatus = status ?? 200;
    const errorText = typeof value.error === "string" ? value.error : undefined;
    const hasFailureShape = typeof value.code === "string" || (body !== null && typeof body === "object" && !Array.isArray(body) && "error" in body);
    if (responseStatus >= 400 || hasFailureShape) {
      const suppliedCode = typeof value.code === "string" && SAFE_SHARING_ERROR_CODES.has(value.code)
        ? value.code
        : failureCodeFor(responseStatus >= 400 ? responseStatus : 500, errorText);
      const stage = suppliedCode === "AUTH_REQUIRED" ? "sharing.authentication"
        : suppliedCode === "ACCOUNT_DELETED" || suppliedCode === "ACCOUNT_DELETION_IN_PROGRESS" ? "sharing.account-status"
          : undefined;
      return sharingError(c, suppliedCode, responseStatus >= 400 ? responseStatus : 500, stage);
    }
    const correlatedBody = body && typeof body === "object" && !Array.isArray(body)
      ? { ...body, correlationId: requestCorrelationId }
      : body;
    return json(correlatedBody, status as any, headers as any);
  };
  await next();
});
routes.use("*", requireAuth as never);

routes.onError((error, c) => {
  if (error instanceof SessionSharingServiceError) return errorResponse(c, error);
  const statusValue = typeof error === "object" && error !== null && "status" in error ? error.status : undefined;
  const status = typeof statusValue === "number" ? statusValue : 500;
  if (status === 401) return sharingError(c, "AUTH_REQUIRED", 401, "sharing.authentication", "authentication_rejected");
  return sharingError(c, "INTERNAL_ERROR", 500, operationFor(c).stage, "unexpected_route_failure");
});

// The sharing Worker must validate app access tokens through this API Worker:
// native Rishi access tokens are not Better Auth session tokens. Keep this
// endpoint scoped to the authenticated caller and expose only the identity
// fields needed to identify a participant in a reading room.
routes.get("/auth-context", async (c) => {
  return runSharingEffect(c, authContext(c.get("userId"), correlationId(c)));
});

function service(c: any) {
  return new SessionSharingService(c.env.SHARING_WORKER, {
    internalTokenSecret: c.env.SHARING_INTERNAL_SECRET,
    internalPathPrefix: "/v2/internal",
    correlationId: correlationId(c),
  });
}

type SessionSharingRouteRequirements =
  | SessionSharingPersistence
  | SessionSharingProfileLookup
  | SessionSharingArtifacts
  | SessionSharingTransport
  | SessionSharingDiagnostics
  | SessionInviteEmailDelivery;

function routeEffectLayer(c: any, sharingService: SessionSharingService) {
  return Layer.mergeAll(
    sharingService.layer,
    makeSessionSharingUseCaseLayer(c.env, correlationId(c)),
    makeSessionInviteEmailDeliveryLayer(c.env.RESEND_API_KEY),
  );
}

async function runSharingEffect<A, E extends SessionSharingFailure | SessionSharingRouteFailure>(
  c: any,
  program: Effect.Effect<A, E, SessionSharingRouteRequirements>,
  options: { status?: number | ((value: A) => number); body?: (value: A) => unknown } = {},
) {
  const sharingService = service(c);
  const exit = await Effect.runPromiseExit(Effect.provide(program, routeEffectLayer(c, sharingService)));
  if (Exit.isSuccess(exit)) {
    const status = typeof options.status === "function" ? options.status(exit.value) : options.status ?? 200;
    const body = options.body ? options.body(exit.value) : exit.value;
    return c.json(body, status);
  }

  const failure = Option.getOrNull(Cause.failureOption(exit.cause));
  if (failure instanceof SessionSharingRouteFailure) {
    return sharingError(c, failure.code, failure.status, failure.stage, `${failure.stage}:${failure.code}`);
  }
  if (isSessionSharingFailure(failure)) return errorResponse(c, toSessionSharingServiceError(failure));
  if (failure instanceof SessionSharingServiceError) return errorResponse(c, failure);
  return sharingError(c, "INTERNAL_ERROR", 500, operationFor(c).stage, "unexpected_effect_defect");
}

function readObjectBody(c: any): Effect.Effect<Record<string, unknown>> {
  return Effect.tryPromise({
    try: () => c.req.json() as Promise<unknown>,
    catch: () => undefined,
  }).pipe(
    Effect.map((value) => value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {}),
    Effect.orElseSucceed(() => ({})),
  );
}

function requireOpenInvite(sessionId: string, ownerUserId?: string) {
  return SessionSharingPersistence.query("session.control.find_invite", (db) => db.select().from(sessionInvites)
    .where(and(
      eq(sessionInvites.sessionId, sessionId),
      eq(sessionInvites.status, "open"),
      ...(ownerUserId ? [eq(sessionInvites.ownerUserId, ownerUserId)] : []),
    )).get()).pipe(
      Effect.flatMap((invite) => invite
        ? Effect.succeed(invite)
        : Effect.fail(new SessionSharingRouteFailure("SESSION_LINK_INVALID", 404, "Session not found", "session.control.invite_lookup"))),
    );
}

function requireActiveRoom(sharingService: SessionSharingService, sessionId: string) {
  return sharingService.getRoomStatusEffect({ sessionId }).pipe(
    Effect.catchIf(
      (failure): failure is SessionSharingDomainFailure & { readonly code: "SESSION_NOT_FOUND" } =>
        failure instanceof SessionSharingDomainFailure && failure.code === "SESSION_NOT_FOUND",
      () => Effect.fail(new SessionSharingRouteFailure("SESSION_ENDED", 410, "Session ended", "session.control.room_lookup")),
    ),
    Effect.flatMap((room) => room && room.status !== "ended"
      ? Effect.succeed(room)
      : Effect.fail(new SessionSharingRouteFailure("SESSION_ENDED", 410, "Session ended", "session.control.room_lookup"))),
  );
}

function errorResponse(c: any, error: unknown) {
  if (isSessionSharingFailure(error)) error = toSessionSharingServiceError(error);
  if (error instanceof SessionSharingServiceError) {
    const status = error.code === "SESSION_ENDED" ? 410
      : error.code === "BOOK_HASH_MISMATCH" || error.code === "BAD_REQUEST" ? 422
      : error.code === "INVALID_RESPONSE" && error.status === 502 ? 502
      : error.status === 409 ? 409
      : error.status === 403 ? 403
      : error.status === 404 ? 404
      : 503;
    return sharingError(c, error.code, status);
  }
  return sharingError(c, "INTERNAL_ERROR", 500, operationFor(c).stage, "unexpected_service_failure");
}

routes.post("/", async (c) => {
  const userId = c.get("userId");
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.bookId !== "string" || !body.bookId || typeof body.idempotencyKey !== "string" || !body.idempotencyKey || body.idempotencyKey.length > 128) {
      return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "bookId and idempotencyKey are required", "session.create.validate"));
    }
    const result = yield* createSession({ userId, bookId: body.bookId, idempotencyKey: body.idempotencyKey, service: service(c), correlationId: correlationId(c) });
    const { created, ...response } = result;
    return { response, created };
  });
  return runSharingEffect(c, program, { status: (result) => result.created ? 201 : 200, body: (result) => result.response });
});

routes.post("/redeem", async (c) => {
  const userId = c.get("userId");
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.token !== "string" || !body.token || body.token.length > 4096) return yield* Effect.fail(new SessionSharingRouteFailure("SESSION_LINK_INVALID", 400, "Invalid session link", "session.redeem.validate"));
    return yield* redeemSession({ userId, token: body.token, service: service(c), correlationId: correlationId(c) });
  });
  return runSharingEffect(c, program);
});

routes.get("/active", async (c) => {
  return runSharingEffect(c, activeSessions(c.get("userId"), correlationId(c), service(c)));
});

routes.get("/:id", async (c) => {
  const sharingService = service(c);
  return runSharingEffect(c, readSession({
    userId: c.get("userId"),
    sessionId: c.req.param("id"),
    service: sharingService,
    correlationId: correlationId(c),
  }));
});

routes.get("/:id/turn", async (c) => {
  const authorization = c.req.header("authorization");
  if (!authorization) return sharingError(c, "AUTH_REQUIRED", 401, "sharing.authentication", "authorization_missing");
  return runSharingEffect(c, turnCredentials({
    sessionId: c.req.param("id"),
    authorization,
    correlationId: correlationId(c),
  }));
});

routes.post("/:id/book-ready", async (c) => {
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.token !== "string" || !body.token || typeof body.contentHash !== "string" || !body.contentHash) {
      return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "token and contentHash are required", "session.admission.validate"));
    }
    return yield* bookReady({
      userId: c.get("userId"),
      sessionId: c.req.param("id"),
      token: body.token,
      contentHash: body.contentHash,
      service: service(c),
      wsUrl: c.env.SHARING_WORKER_WS_URL,
      correlationId: correlationId(c),
    });
  });
  return runSharingEffect(c, program);
});

// Rejoin from the account-scoped active-session list. This intentionally does
// not require the original URL: the redemption is the authenticated user's
// durable membership record, while the DO still enforces removal/capacity and
// issues a fresh single-use admission ticket.
routes.post("/:id/rejoin", async (c) => {
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.contentHash !== "string" || !body.contentHash) return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "contentHash is required", "session.rejoin.validate"));
    return yield* rejoinSession({
      userId: c.get("userId"),
      sessionId: c.req.param("id"),
      contentHash: body.contentHash,
      service: service(c),
      wsUrl: c.env.SHARING_WORKER_WS_URL,
      correlationId: correlationId(c),
    });
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/start", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    yield* requireOpenInvite(id);
    const room = yield* requireActiveRoom(sharingService, id);
    return yield* sharingService.startRoomEffect({ sessionId: id, actingUserId: userId, expectedControllerGeneration: room.controllerGeneration });
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/end", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    const invite = yield* requireOpenInvite(id);
    const room = yield* requireActiveRoom(sharingService, id);
    const result = yield* sharingService.endRoomEffect({ sessionId: id, actingUserId: userId, expectedControllerGeneration: room.controllerGeneration });
    yield* SessionSharingPersistence.query("session.control.mark_ended", (db) => db.update(sessionInvites)
      .set({ status: "ended", endedAt: new Date() }).where(eq(sessionInvites.id, invite.id)).run());
    return result;
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/leave", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    const invite = yield* requireOpenInvite(id);
    const result = yield* sharingService.leaveRoomEffect({
      sessionId: id,
      actingUserId: userId,
      deliberate: typeof body.deliberate === "boolean" ? body.deliberate : undefined,
    });
    yield* SessionSharingPersistence.query("session.control.mark_left", (db) => db.update(sessionInviteRedemptions)
      .set({ membershipStatus: "left", updatedAt: new Date() })
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).run());
    return result;
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/controller/transfer", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.targetUserId !== "string" || !body.targetUserId) return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "targetUserId is required", "session.control.transfer.validate"));
    yield* requireOpenInvite(id);
    const room = yield* requireActiveRoom(sharingService, id);
    return yield* sharingService.transferControllerEffect({ sessionId: id, actingUserId: userId, targetUserId: body.targetUserId, expectedControllerGeneration: room.controllerGeneration });
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/participants/remove", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.participantUserId !== "string" || !body.participantUserId) return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "participantUserId is required", "session.control.remove.validate"));
    const invite = yield* requireOpenInvite(id);
    const room = yield* requireActiveRoom(sharingService, id);
    const result = yield* sharingService.removeParticipantEffect({ sessionId: id, actingUserId: userId, userId: body.participantUserId, expectedControllerGeneration: room.controllerGeneration });
    yield* SessionSharingPersistence.query("session.control.mark_removed", (db) => db.update(sessionInviteRedemptions)
      .set({ membershipStatus: "removed", updatedAt: new Date() })
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, body.participantUserId as string))).run());
    return result;
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/participants/restore", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const sharingService = service(c);
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (typeof body.participantUserId !== "string" || !body.participantUserId || typeof body.contentHash !== "string" || !body.contentHash) {
      return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "participantUserId and contentHash are required", "session.control.restore.validate"));
    }
    const invite = yield* requireOpenInvite(id);
    if (invite.contentHash !== body.contentHash) return yield* Effect.fail(new SessionSharingRouteFailure("BOOK_HASH_MISMATCH", 422, "The downloaded book could not be verified", "session.control.restore.book_hash"));
    const room = yield* requireActiveRoom(sharingService, id);
    const profile = yield* SessionSharingProfileLookup.get(body.participantUserId);
    const result = yield* sharingService.restoreParticipantEffect({
      sessionId: id,
      actingUserId: userId,
      userId: body.participantUserId,
      inviteId: invite.id,
      contentHash: body.contentHash,
      expectedControllerGeneration: room.controllerGeneration,
      profile: { displayName: profile?.displayName?.trim() || "Reader", ...(profile?.avatarUrl ? { avatarUrl: profile.avatarUrl } : {}) },
    });
    yield* SessionSharingPersistence.query("session.control.mark_restored", (db) => db.update(sessionInviteRedemptions)
      .set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: result.claims.ticketId, updatedAt: new Date() })
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, body.participantUserId as string))).run());
    return { admissionTicket: result.admissionTicket, status: result.status, roomEpoch: result.roomEpoch };
  });
  return runSharingEffect(c, program);
});

routes.post("/:id/email", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const program = Effect.gen(function* () {
    const body = yield* readObjectBody(c);
    if (!Array.isArray(body.recipients) || !body.recipients.every((email) => typeof email === "string") || typeof body.idempotencyKey !== "string" || !body.idempotencyKey) {
      return yield* Effect.fail(new SessionSharingRouteFailure("BAD_REQUEST", 400, "recipients and idempotencyKey are required", "session.invitation.validate"));
    }
    const invite = yield* SessionSharingPersistence.query("session.invitation.find_invite", (db) => db.select().from(sessionInvites)
      .where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.ownerUserId, userId), eq(sessionInvites.status, "open"))).get());
    if (!invite) return yield* Effect.fail(new SessionSharingRouteFailure("SESSION_LINK_INVALID", 404, "Session not found", "session.invitation.invite_lookup"));
    const book = yield* SessionSharingPersistence.query("session.invitation.find_book", (db) => db.select({ title: books.title }).from(books).where(eq(books.id, invite.sourceBookId)).get());
    const token = yield* SessionSharingArtifacts.createToken(userId, invite.idempotencyKey);
    const shareURL = `${SESSION_SHARE_PUBLIC_ORIGIN}/sharing/session?token=${encodeURIComponent(token)}`;
    const result = yield* sendSessionInviteEmails({ sessionId: id, inviteId: invite.id, shareUrl: shareURL, bookTitle: book?.title, recipients: body.recipients as string[] });
    const retryable = result.failed > 0;
    return {
      shareURL,
      ...result,
      retryable,
      action: retryable ? "retry" : "dismiss",
      correlationId: correlationId(c),
    };
  });
  return runSharingEffect(c, program);
});

export { routes as sessionSharesRoutes };
