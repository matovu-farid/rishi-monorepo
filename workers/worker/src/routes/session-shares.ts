import { Hono } from "hono";
import { and, eq, inArray } from "drizzle-orm";
import { createDb } from "../db/drizzle";
import { books, sessionInviteItems, sessionInviteRedemptions, sessionInvites, user as authUser } from "../db/schema";
import { requireAuth } from "../middleware";
import { createShareTokenFromSecret, hashShareToken } from "../shares/shareTokens";
import { signR2Url } from "../r2-presign";
import { SessionSharingService, SessionSharingServiceError } from "../session-sharing-service";
import { sendSessionInviteEmails } from "../session-invite-email";

type SessionEnv = Env & {
  SHARING_WORKER: { fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> };
  SHARING_INTERNAL_SECRET: string;
  SHARING_WORKER_WS_URL?: string;
};
type SessionContext = { Bindings: SessionEnv; Variables: { userId: string } };
const routes = new Hono<SessionContext>();
routes.use("*", requireAuth as never);

function service(c: any) {
  return new SessionSharingService(c.env.SHARING_WORKER, { internalTokenSecret: c.env.SHARING_INTERNAL_SECRET });
}

function sessionToken(c: any, ownerUserId: string, idempotencyKey: string): Promise<string> {
  return createShareTokenFromSecret(c.env.BETTER_AUTH_SECRET, ownerUserId, `reading-session:${idempotencyKey}`);
}

async function participantProfile(c: any, userId: string) {
  const row = await createDb(c.env.DB)
    .select({ displayName: authUser.name, avatarUrl: authUser.image })
    .from(authUser)
    .where(eq(authUser.id, userId))
    .get();
  return {
    displayName: row?.displayName?.trim() || "Reader",
    ...(row?.avatarUrl ? { avatarUrl: row.avatarUrl } : {}),
  };
}

function errorResponse(c: any, error: unknown) {
  if (error instanceof SessionSharingServiceError) {
    const status = error.code === "SESSION_ENDED" ? 410
      : error.code === "BOOK_HASH_MISMATCH" || error.code === "BAD_REQUEST" ? 422
      : error.status === 409 ? 409
      : error.status === 403 ? 403
      : error.status === 404 ? 404
      : 503;
    return c.json({ code: error.code, error: error.message }, status);
  }
  return c.json({ code: "SERVICE_UNAVAILABLE", error: "Rishi could not complete this action." }, 503);
}

async function bookPayload(c: any, book: typeof books.$inferSelect) {
  if (!book.fileR2Key || !book.fileHash || !book.fileSize || !["epub", "pdf"].includes(book.format)) return null;
  const downloadURL = await signR2Url(c.env, { key: book.fileR2Key, method: "GET", expiresSec: 600 });
  return { bookId: book.id, contentHash: book.fileHash, format: book.format as "epub" | "pdf", fileSize: Number(book.fileSize), downloadURL };
}

routes.post("/", async (c) => {
  const userId = c.get("userId");
  const body = await c.req.json().catch(() => ({})) as { bookId?: string; idempotencyKey?: string };
  if (!body.bookId || !body.idempotencyKey || body.idempotencyKey.length > 128) return c.json({ code: "BAD_REQUEST", error: "bookId and idempotencyKey are required" }, 400);
  const db = createDb(c.env.DB);
  const existing = await db.select().from(sessionInvites).where(and(eq(sessionInvites.ownerUserId, userId), eq(sessionInvites.idempotencyKey, body.idempotencyKey))).get();
  if (existing) {
    const item = await db.select().from(sessionInviteItems).where(eq(sessionInviteItems.inviteId, existing.id)).get();
    const book = await db.select().from(books).where(eq(books.id, existing.sourceBookId)).get();
    if (!item || !book) return c.json({ code: "SERVICE_UNAVAILABLE", error: "session record is incomplete" }, 503);
    const payload = await bookPayload(c, book);
    if (!payload) return c.json({ code: "BOOK_NOT_READY", error: "The book is not ready to share" }, 422);
    const room = await service(c).getRoomStatus({ sessionId: existing.sessionId }).catch(() => null);
    if (!room || room.status === "ended") {
      await db.update(sessionInvites).set({ status: "ended", endedAt: new Date() }).where(eq(sessionInvites.id, existing.id)).run();
      return c.json({ code: "SESSION_ENDED", error: "This reading session has ended; create a new link to start again" }, 410);
    }
    const token = await sessionToken(c, userId, existing.idempotencyKey);
    return c.json({ sessionId: existing.sessionId, book: payload, shareURL: `https://rishi.fidexa.org/sharing/session?token=${encodeURIComponent(token)}`, status: room.status });
  }
  const book = await db.select().from(books).where(and(eq(books.id, body.bookId), eq(books.userId, userId), eq(books.isDeleted, false))).get();
  if (!book) return c.json({ code: "SESSION_LINK_INVALID", error: "Book not found" }, 404);
  const payload = await bookPayload(c, book);
  if (!payload) return c.json({ code: "BOOK_NOT_READY", error: "The book is not ready to share" }, 422);
  const sessionId = crypto.randomUUID();
  const inviteId = crypto.randomUUID();
  const token = await sessionToken(c, userId, body.idempotencyKey);
  const tokenHash = await hashShareToken(token);
  try {
    await service(c).createRoom({ sessionId, initialSharerUserId: userId, bookContext: { bookId: payload.bookId, contentHash: payload.contentHash, format: payload.format }, maxParticipants: 5 });
    await db.insert(sessionInvites).values({ id: inviteId, ownerUserId: userId, idempotencyKey: body.idempotencyKey, sessionId, sourceBookId: book.id, contentHash: payload.contentHash, format: payload.format, tokenHash, status: "open", createdAt: new Date() }).run();
    await db.insert(sessionInviteItems).values({ id: crypto.randomUUID(), inviteId, fileR2Key: book.fileR2Key!, coverR2Key: book.coverR2Key, fileHash: payload.contentHash, fileSize: payload.fileSize, createdAt: new Date() }).run();
  } catch (error) {
    await service(c).endRoom({ sessionId, actingUserId: userId, expectedControllerGeneration: 1 }).catch(() => undefined);
    if (error instanceof SessionSharingServiceError) return errorResponse(c, error);
    return c.json({ code: "SERVICE_UNAVAILABLE", error: "Could not create reading session" }, 503);
  }
  return c.json({ sessionId, book: payload, shareURL: `https://rishi.fidexa.org/sharing/session?token=${encodeURIComponent(token)}`, status: "waiting" }, 201);
});

routes.post("/redeem", async (c) => {
  const userId = c.get("userId");
  const body = await c.req.json().catch(() => ({})) as { token?: string };
  if (!body.token || body.token.length > 4096) return c.json({ code: "SESSION_LINK_INVALID", error: "Invalid session link" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(eq(sessionInvites.tokenHash, await hashShareToken(body.token))).get();
  if (!invite || invite.status !== "open") return c.json({ code: "SESSION_LINK_INVALID", error: "This session link is not valid" }, 404);
  const room = await service(c).getRoomStatus({ sessionId: invite.sessionId }).catch((error) => { throw error; });
  if (!room || room.status === "ended") { await db.update(sessionInvites).set({ status: "ended", endedAt: new Date() }).where(eq(sessionInvites.id, invite.id)).run(); return c.json({ code: "SESSION_ENDED", error: "This reading session has ended" }, 410); }
  const item = await db.select().from(sessionInviteItems).where(eq(sessionInviteItems.inviteId, invite.id)).get();
  if (!item) return c.json({ code: "SERVICE_UNAVAILABLE", error: "Book package is unavailable" }, 503);
  const book = await db.select().from(books).where(eq(books.id, invite.sourceBookId)).get();
  if (!book) return c.json({ code: "SESSION_LINK_INVALID", error: "Book is unavailable" }, 404);
  const payload = await bookPayload(c, book);
  if (!payload) return c.json({ code: "BOOK_NOT_READY", error: "The book is still being prepared" }, 422);
  const redemptionId = crypto.randomUUID();
  await db.insert(sessionInviteRedemptions).values({ id: redemptionId, inviteId: invite.id, userId, bookStatus: "pending", membershipStatus: "pending", createdAt: new Date(), updatedAt: new Date() }).onConflictDoNothing().run();
  const redemption = await db.select().from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).get();
  return c.json({ inviteId: invite.id, sessionId: invite.sessionId, book: payload, status: room.status, redemptionId: redemption?.id ?? redemptionId });
});

routes.get("/:id", async (c) => {
  const userId = c.get("userId");
  const sessionId = c.req.param("id");
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, sessionId), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  const redemption = await db.select().from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).get();
  if (invite.ownerUserId !== userId && !redemption) return c.json({ code: "FORBIDDEN", error: "You are not part of this reading session" }, 403);
  if (redemption?.membershipStatus === "removed") return c.json({ code: "REMOVED_FROM_SESSION", error: "You cannot access this reading session" }, 403);
  try {
    const room = await service(c).getRoomStatus({ sessionId });
    if (!room || room.status === "ended") return c.json({ code: "SESSION_ENDED", error: "This reading session has ended" }, 410);
    const book = await db.select().from(books).where(eq(books.id, invite.sourceBookId)).get();
    if (!book) return c.json({ code: "SESSION_LINK_INVALID", error: "Book is unavailable" }, 404);
    const payload = await bookPayload(c, book);
    if (!payload) return c.json({ code: "BOOK_NOT_READY", error: "The book is still being prepared" }, 422);
    return c.json({ ...room, book: payload });
  } catch (error) { return errorResponse(c, error); }
});

routes.get("/:id/turn", async (c) => {
  const sessionId = c.req.param("id");
  const authorization = c.req.header("authorization");
  if (!authorization) return c.json({ code: "AUTH_REQUIRED", error: "Sign in to use session audio" }, 401);
  const target = new URL(`https://sharing-worker.internal/v1/sessions/${encodeURIComponent(sessionId)}/turn`);
  try {
    const response = await c.env.SHARING_WORKER.fetch(new Request(target, { method: "GET", headers: { authorization } }));
    return new Response(response.body, { status: response.status, headers: { "content-type": response.headers.get("content-type") ?? "application/json" } });
  } catch {
    return c.json({ code: "TURN_UNAVAILABLE", error: "Voice relay credentials are temporarily unavailable." }, 503);
  }
});

routes.post("/:id/book-ready", async (c) => {
  const userId = c.get("userId");
  const sessionId = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { token?: string; contentHash?: string };
  if (!body.token || !body.contentHash) return c.json({ code: "BAD_REQUEST", error: "token and contentHash are required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, sessionId), eq(sessionInvites.tokenHash, await hashShareToken(body.token)), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "This session link is not valid" }, 404);
  if (invite.contentHash !== body.contentHash) return c.json({ code: "BOOK_HASH_MISMATCH", error: "The downloaded book could not be verified" }, 422);
  const redemption = await db.select().from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).get();
  if (!redemption) return c.json({ code: "BOOK_NOT_READY", error: "Redeem the session before admission" }, 422);
  try {
    const ticket = await service(c).issueAdmissionTicket({ sessionId, inviteId: invite.id, userId, contentHash: body.contentHash, profile: await participantProfile(c, userId) });
    await db.update(sessionInviteRedemptions).set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: ticket.claims.ticketId, updatedAt: new Date() }).where(eq(sessionInviteRedemptions.id, redemption.id)).run();
    const wsBase = c.env.SHARING_WORKER_WS_URL ?? "wss://sharing.fidexa.org";
    return c.json({ admissionTicket: ticket.admissionTicket, wsUrl: `${wsBase}/v1/sessions/${sessionId}/wss`, status: ticket.status, roomEpoch: ticket.roomEpoch, connectionGeneration: ticket.claims.connectionGeneration });
  } catch (error) { return errorResponse(c, error); }
});

// Rejoin from the account-scoped active-session list. This intentionally does
// not require the original URL: the redemption is the authenticated user's
// durable membership record, while the DO still enforces removal/capacity and
// issues a fresh single-use admission ticket.
routes.post("/:id/rejoin", async (c) => {
  const userId = c.get("userId");
  const sessionId = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { contentHash?: string };
  if (!body.contentHash) return c.json({ code: "BAD_REQUEST", error: "contentHash is required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, sessionId), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_ENDED", error: "This reading session has ended" }, 410);
  if (invite.contentHash !== body.contentHash) return c.json({ code: "BOOK_HASH_MISMATCH", error: "The downloaded book could not be verified" }, 422);
  const redemption = await db.select().from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).get();
  if (!redemption || redemption.membershipStatus === "removed") return c.json({ code: "REMOVED_FROM_SESSION", error: "You cannot rejoin this reading session" }, 403);
  try {
    const ticket = await service(c).issueAdmissionTicket({ sessionId, inviteId: invite.id, userId, contentHash: body.contentHash, profile: await participantProfile(c, userId) });
    await db.update(sessionInviteRedemptions).set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: ticket.claims.ticketId, updatedAt: new Date() }).where(eq(sessionInviteRedemptions.id, redemption.id)).run();
    const wsBase = c.env.SHARING_WORKER_WS_URL ?? "wss://sharing.fidexa.org";
    return c.json({ admissionTicket: ticket.admissionTicket, wsUrl: `${wsBase}/v1/sessions/${sessionId}/wss`, status: ticket.status, roomEpoch: ticket.roomEpoch, connectionGeneration: ticket.claims.connectionGeneration });
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/start", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  try {
    const room = await service(c).getRoomStatus({ sessionId: id });
    if (!room) return c.json({ code: "SESSION_ENDED", error: "Session ended" }, 410);
    const result = await service(c).startRoom({ sessionId: id, actingUserId: userId, expectedControllerGeneration: room.controllerGeneration });
    return c.json(result);
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/end", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  try {
    const room = await service(c).getRoomStatus({ sessionId: id });
    if (!room) return c.json({ code: "SESSION_ENDED", error: "Session ended" }, 410);
    const result = await service(c).endRoom({ sessionId: id, actingUserId: userId, expectedControllerGeneration: room.controllerGeneration });
    await db.update(sessionInvites).set({ status: "ended", endedAt: new Date() }).where(eq(sessionInvites.id, invite.id)).run();
    return c.json(result);
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/leave", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { deliberate?: boolean };
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  try {
    const result = await service(c).leaveRoom({ sessionId: id, actingUserId: userId, deliberate: body.deliberate });
    await db.update(sessionInviteRedemptions).set({ membershipStatus: "left", updatedAt: new Date() }).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, userId))).run();
    return c.json(result);
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/controller/transfer", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { targetUserId?: string };
  if (!body.targetUserId) return c.json({ code: "BAD_REQUEST", error: "targetUserId is required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  try {
    const room = await service(c).getRoomStatus({ sessionId: id });
    if (!room) return c.json({ code: "SESSION_ENDED", error: "Session ended" }, 410);
    const result = await service(c).transferController({ sessionId: id, actingUserId: userId, targetUserId: body.targetUserId, expectedControllerGeneration: room.controllerGeneration });
    return c.json(result);
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/participants/remove", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { participantUserId?: string };
  if (!body.participantUserId) return c.json({ code: "BAD_REQUEST", error: "participantUserId is required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  try {
    const room = await service(c).getRoomStatus({ sessionId: id });
    if (!room) return c.json({ code: "SESSION_ENDED", error: "Session ended" }, 410);
    const result = await service(c).removeParticipant({ sessionId: id, actingUserId: userId, userId: body.participantUserId, expectedControllerGeneration: room.controllerGeneration });
    await db.update(sessionInviteRedemptions).set({ membershipStatus: "removed", updatedAt: new Date() }).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, body.participantUserId))).run();
    return c.json(result);
  } catch (error) { return errorResponse(c, error); }
});

routes.post("/:id/participants/restore", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { participantUserId?: string; contentHash?: string; profile?: { displayName: string; avatarUrl?: string } };
  if (!body.participantUserId || !body.contentHash) return c.json({ code: "BAD_REQUEST", error: "participantUserId and contentHash are required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  if (invite.contentHash !== body.contentHash) return c.json({ code: "BOOK_HASH_MISMATCH", error: "The downloaded book could not be verified" }, 422);
  try {
    const room = await service(c).getRoomStatus({ sessionId: id });
    if (!room) return c.json({ code: "SESSION_ENDED", error: "Session ended" }, 410);
    const result = await service(c).restoreParticipant({ sessionId: id, actingUserId: userId, userId: body.participantUserId, inviteId: invite.id, contentHash: body.contentHash, expectedControllerGeneration: room.controllerGeneration, profile: await participantProfile(c, body.participantUserId) });
    await db.update(sessionInviteRedemptions).set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: result.claims.ticketId, updatedAt: new Date() }).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, body.participantUserId))).run();
    return c.json({ admissionTicket: result.admissionTicket, status: result.status, roomEpoch: result.roomEpoch });
  } catch (error) { return errorResponse(c, error); }
});

routes.get("/active", async (c) => {
  const userId = c.get("userId");
  const db = createDb(c.env.DB);
  const redemptions = await db.select().from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.userId, userId), inArray(sessionInviteRedemptions.membershipStatus, ["pending", "admitted", "left"]))).all();
  const sessions = [];
  for (const redemption of redemptions) {
    const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.id, redemption.inviteId), eq(sessionInvites.status, "open"))).get();
    if (!invite) continue;
    const room = await service(c).getRoomStatus({ sessionId: invite.sessionId }).catch(() => null);
    if (!room || room.status === "ended") continue;
    const book = await db.select().from(books).where(eq(books.id, invite.sourceBookId)).get();
    if (!book) continue;
    const payload = await bookPayload(c, book);
    if (payload) sessions.push({ sessionId: invite.sessionId, book: payload, status: room.status, controllerUserId: room.controllerUserId, joinedAt: redemption.createdAt });
  }
  return c.json({ sessions });
});

routes.post("/:id/email", async (c) => {
  const userId = c.get("userId");
  const id = c.req.param("id");
  const body = await c.req.json().catch(() => ({})) as { recipients?: string[]; idempotencyKey?: string };
  if (!Array.isArray(body.recipients) || !body.idempotencyKey) return c.json({ code: "BAD_REQUEST", error: "recipients and idempotencyKey are required" }, 400);
  const db = createDb(c.env.DB);
  const invite = await db.select().from(sessionInvites).where(and(eq(sessionInvites.sessionId, id), eq(sessionInvites.ownerUserId, userId), eq(sessionInvites.status, "open"))).get();
  if (!invite) return c.json({ code: "SESSION_LINK_INVALID", error: "Session not found" }, 404);
  const token = await sessionToken(c, userId, invite.idempotencyKey);
  const result = await sendSessionInviteEmails({ db, sessionId: id, inviteId: invite.id, shareUrl: `https://rishi.fidexa.org/sharing/session?token=${token}`, recipients: body.recipients, resendApiKey: c.env.RESEND_API_KEY });
  return c.json({ shareURL: `https://rishi.fidexa.org/sharing/session?token=${token}`, ...result });
});

export { routes as sessionSharesRoutes };
