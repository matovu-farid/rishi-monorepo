import { Cause, Context, Effect, Layer, Option } from "effect";
import { and, eq, inArray } from "drizzle-orm";
import { books, sessionInviteItems, sessionInviteRedemptions, sessionInvites, user as authUser } from "./db/schema";
import { createDb } from "./db/drizzle";
import { createShareTokenFromSecret, hashShareToken } from "./shares/shareTokens";
import { signR2Url } from "./r2-presign";
import {
  SessionSharingDependencyFailure,
  SessionSharingDomainFailure,
  SessionSharingInvalidResponseFailure,
  type SessionSharingFailure,
} from "./session-sharing-errors";
import { SessionSharingDiagnostics, SessionSharingTransport } from "./session-sharing-effect-services";
import type { SessionSharingService } from "./session-sharing-service";

type Database = ReturnType<typeof createDb>;
type SessionEnv = Env & {
  SHARING_WORKER: { fetch(input: RequestInfo | URL, init?: RequestInit): Promise<Response> };
  SHARING_INTERNAL_SECRET: string;
  SHARING_WORKER_WS_URL?: string;
  BETTER_AUTH_SECRET: string;
};

export interface SessionSharingBookPayload {
  readonly bookId: string;
  readonly contentHash: string;
  readonly format: "epub" | "pdf";
  readonly fileSize: number;
  readonly downloadURL: string;
}

export interface SessionSharingProfile {
  readonly displayName: string;
  readonly avatarUrl?: string;
}

export class SessionSharingRouteFailure extends Error {
  readonly _tag = "SessionSharingRouteFailure";
  constructor(
    readonly code: string,
    readonly status: number,
    message: string,
    readonly stage: string,
    options?: { cause?: unknown },
  ) {
    super(message, options);
    this.name = "SessionSharingRouteFailure";
  }
}

export class SessionSharingPersistence extends Context.Tag("SessionSharingPersistence")<
  SessionSharingPersistence,
  {
    readonly query: <A>(
      operation: string,
      execute: (db: Database) => Promise<A>,
    ) => Effect.Effect<A, SessionSharingDependencyFailure>;
  }
>() {
  static query<A>(operation: string, execute: (db: Database) => Promise<A>): Effect.Effect<A, SessionSharingDependencyFailure, SessionSharingPersistence> {
    return Effect.flatMap(SessionSharingPersistence, (persistence) => persistence.query(operation, execute));
  }
}

export class SessionSharingProfileLookup extends Context.Tag("SessionSharingProfileLookup")<
  SessionSharingProfileLookup,
  {
    readonly get: (userId: string) => Effect.Effect<{
      id: string;
      displayName: string | null;
      avatarUrl: string | null;
    } | null, SessionSharingDependencyFailure>;
  }
>() {
  static get(userId: string) {
    return Effect.flatMap(SessionSharingProfileLookup, (profiles) => profiles.get(userId));
  }
}

export class SessionSharingArtifacts extends Context.Tag("SessionSharingArtifacts")<
  SessionSharingArtifacts,
  {
    readonly createToken: (ownerUserId: string, idempotencyKey: string) => Effect.Effect<string, SessionSharingDependencyFailure>;
    readonly hashToken: (token: string) => Effect.Effect<string, SessionSharingDependencyFailure>;
    readonly bookPayload: (book: typeof books.$inferSelect) => Effect.Effect<SessionSharingBookPayload | null, SessionSharingDependencyFailure>;
  }
>() {
  static createToken(ownerUserId: string, idempotencyKey: string) {
    return Effect.flatMap(SessionSharingArtifacts, (artifacts) => artifacts.createToken(ownerUserId, idempotencyKey));
  }

  static hashToken(token: string) {
    return Effect.flatMap(SessionSharingArtifacts, (artifacts) => artifacts.hashToken(token));
  }

  static bookPayload(book: typeof books.$inferSelect) {
    return Effect.flatMap(SessionSharingArtifacts, (artifacts) => artifacts.bookPayload(book));
  }
}

export function makeSessionSharingUseCaseLayer(
  env: SessionEnv,
  correlationId: string,
): Layer.Layer<SessionSharingPersistence | SessionSharingProfileLookup | SessionSharingArtifacts> {
  const database = createDb(env.DB);
  const query = <A>(operation: string, execute: (db: Database) => Promise<A>) => Effect.tryPromise({
    try: () => execute(database),
    catch: (cause) => new SessionSharingDependencyFailure({
      code: "SERVICE_UNAVAILABLE",
      message: "Session sharing data is temporarily unavailable",
      stage: operation,
      correlationId,
      cause,
    }),
  });

  const persistence = Layer.succeed(SessionSharingPersistence, { query });
  const profile = Layer.succeed(SessionSharingProfileLookup, {
    get: (userId) => query("profile.lookup", (db) => db
      .select({ id: authUser.id, displayName: authUser.name, avatarUrl: authUser.image })
      .from(authUser)
      .where(eq(authUser.id, userId))
      .get()).pipe(Effect.map((row) => row ?? null)),
  });
  const artifacts = Layer.succeed(SessionSharingArtifacts, {
    createToken: (ownerUserId, idempotencyKey) => Effect.tryPromise({
      try: () => createShareTokenFromSecret(env.BETTER_AUTH_SECRET, ownerUserId, `reading-session:${idempotencyKey}`),
      catch: (cause) => new SessionSharingDependencyFailure({
        code: "SERVICE_UNAVAILABLE",
        message: "Unable to create a reading-session link",
        stage: "share_token.create",
        correlationId,
        cause,
      }),
    }),
    hashToken: (token) => Effect.tryPromise({
      try: () => hashShareToken(token),
      catch: (cause) => new SessionSharingDependencyFailure({
        code: "SERVICE_UNAVAILABLE",
        message: "Unable to verify a reading-session link",
        stage: "share_token.hash",
        correlationId,
        cause,
      }),
    }),
    bookPayload: (book) => {
      if (!book.fileR2Key || !book.fileHash || !book.fileSize || !["epub", "pdf"].includes(book.format)) {
        return Effect.succeed(null);
      }
      return Effect.tryPromise({
        try: async () => ({
          bookId: book.id,
          contentHash: book.fileHash!,
          format: book.format as "epub" | "pdf",
          fileSize: Number(book.fileSize),
          downloadURL: await signR2Url(env, { key: book.fileR2Key!, method: "GET", expiresSec: 600 }),
        }),
        catch: (cause) => new SessionSharingDependencyFailure({
          code: "SERVICE_UNAVAILABLE",
          message: "Unable to prepare the shared book",
          stage: "book.download_url",
          correlationId,
          cause,
        }),
      });
    },
  });
  return Layer.mergeAll(persistence, profile, artifacts);
}

const PUBLIC_ORIGIN = "https://join.rishi.fidexa.org";

function routeFailure(code: string, status: number, message: string, stage: string) {
  return Effect.fail(new SessionSharingRouteFailure(code, status, message, stage));
}

function hasRedeemResponseContract(value: unknown): value is {
  inviteId: string;
  sessionId: string;
  book: SessionSharingBookPayload;
  status: "waiting" | "active";
  redemptionId: string;
} {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const response = value as Record<string, unknown>;
  if (typeof response.inviteId !== "string" || !response.inviteId
      || typeof response.sessionId !== "string" || !response.sessionId
      || typeof response.redemptionId !== "string" || !response.redemptionId
      || (response.status !== "waiting" && response.status !== "active")) return false;
  if (typeof response.book !== "object" || response.book === null || Array.isArray(response.book)) return false;
  const book = response.book as Record<string, unknown>;
  if (typeof book.bookId !== "string" || !book.bookId
      || typeof book.contentHash !== "string" || !book.contentHash
      || (book.format !== "epub" && book.format !== "pdf")
      || typeof book.fileSize !== "number" || !Number.isSafeInteger(book.fileSize) || book.fileSize <= 0
      || typeof book.downloadURL !== "string") return false;
  try {
    const url = new URL(book.downloadURL);
    return url.protocol === "https:";
  } catch {
    return false;
  }
}

function diagnosed<A, E, R>(
  operation: string,
  stage: string,
  correlationId: string,
  effect: Effect.Effect<A, E, R>,
): Effect.Effect<A, E, R | SessionSharingDiagnostics> {
  return Effect.gen(function* () {
    const diagnostics = yield* SessionSharingDiagnostics;
    const startedAt = performance.now();
    yield* diagnostics.emit({ operation, stage, outcome: "started", correlationId });
    return yield* effect.pipe(
      Effect.tap(() => diagnostics.emit({ operation, stage, outcome: "succeeded", durationMs: Math.round(performance.now() - startedAt), correlationId })),
      Effect.tapErrorCause((cause) => diagnostics.emit({
        operation,
        stage,
        outcome: "failed",
        durationMs: Math.round(performance.now() - startedAt),
        code: causeCode(cause),
        causeSummary: causeSummary(cause),
        correlationId,
      })),
    );
  });
}

function causeFailure(cause: Cause.Cause<unknown>): unknown {
  return Option.getOrNull(Cause.failureOption(cause));
}

function causeCode(cause: Cause.Cause<unknown>): string {
  const failure = causeFailure(cause);
  return typeof failure === "object" && failure !== null && "code" in failure && typeof failure.code === "string"
    ? failure.code
    : "INTERNAL_ERROR";
}

function causeSummary(cause: Cause.Cause<unknown>): string {
  const failure = causeFailure(cause);
  if (typeof failure === "object" && failure !== null) {
    const tag = "_tag" in failure && typeof failure._tag === "string" ? failure._tag : "failure";
    const code = "code" in failure && typeof failure.code === "string" ? failure.code : "unknown";
    const stage = "stage" in failure && typeof failure.stage === "string" ? failure.stage : "unknown";
    return `${tag}:${code}:${stage}`;
  }
  return "untyped failure";
}

function isAlreadyInitialized(cause: Cause.Cause<unknown>): boolean {
  const failure = causeFailure(cause);
  return failure instanceof SessionSharingDomainFailure && failure.code === "ALREADY_INITIALIZED";
}

function getRoomOrConfirmedMissing(service: SessionSharingService, sessionId: string) {
  return service.getRoomStatusEffect({ sessionId }).pipe(
    Effect.catchAll((failure) => failure instanceof SessionSharingDomainFailure && failure.code === "SESSION_NOT_FOUND"
      ? Effect.succeed(null)
      : Effect.fail(failure)),
  );
}

export function sessionShareUrl(token: string): string {
  return `${PUBLIC_ORIGIN}/sharing/session?token=${encodeURIComponent(token)}`;
}

export function authContext(userId: string, correlationId: string) {
  const program = Effect.gen(function* () {
    const profile = yield* SessionSharingProfileLookup.get(userId);
    if (!profile) return yield* routeFailure("AUTH_REQUIRED", 401, "Sign in to use this reading session", "profile.lookup");
    return {
      user: {
        id: profile.id,
        displayName: profile.displayName,
        ...(profile.avatarUrl ? { avatarUrl: profile.avatarUrl } : {}),
      },
    };
  });
  return diagnosed("sharing.auth_context", "sharing.profile", correlationId, program);
}

export interface CreateSessionInput {
  readonly userId: string;
  readonly bookId: string;
  readonly idempotencyKey: string;
  readonly service: SessionSharingService;
  readonly correlationId: string;
}

function ensureCreatorRedemption(inviteId: string, userId: string) {
  return SessionSharingPersistence.query("session.redemption.create_owner", (db) => db.insert(sessionInviteRedemptions).values({
    id: crypto.randomUUID(),
    inviteId,
    userId,
    bookStatus: "pending",
    membershipStatus: "pending",
    createdAt: new Date(),
    updatedAt: new Date(),
  }).onConflictDoNothing().run()).pipe(Effect.asVoid);
}

function sessionEnded(inviteId: string) {
  return SessionSharingPersistence.query("session.invite.mark_ended", (db) => db.update(sessionInvites)
    .set({ status: "ended", endedAt: new Date() })
    .where(eq(sessionInvites.id, inviteId))
    .run());
}

export function createSession(input: CreateSessionInput) {
  const program = Effect.gen(function* () {
    const existing = yield* SessionSharingPersistence.query("session.create.find_idempotent", (db) => db.select()
      .from(sessionInvites)
      .where(and(eq(sessionInvites.ownerUserId, input.userId), eq(sessionInvites.idempotencyKey, input.idempotencyKey)))
      .get());
    if (existing) {
      const item = yield* SessionSharingPersistence.query("session.create.find_item", (db) => db.select()
        .from(sessionInviteItems).where(eq(sessionInviteItems.inviteId, existing.id)).get());
      const book = yield* SessionSharingPersistence.query("session.create.find_book", (db) => db.select()
        .from(books).where(eq(books.id, existing.sourceBookId)).get());
      if (!item || !book) return yield* routeFailure("SERVICE_UNAVAILABLE", 503, "session record is incomplete", "session.create.existing_records");
      const payload = yield* SessionSharingArtifacts.bookPayload(book);
      if (!payload) return yield* routeFailure("BOOK_NOT_READY", 422, "The book is not ready to share", "session.create.existing_book");
      const room = yield* getRoomOrConfirmedMissing(input.service, existing.sessionId);
      if (!room || room.status === "ended") {
        yield* sessionEnded(existing.id);
        return yield* routeFailure("SESSION_ENDED", 410, "This reading session has ended; create a new link to start again", "session.create.existing_room");
      }
      const token = yield* SessionSharingArtifacts.createToken(input.userId, existing.idempotencyKey);
      yield* ensureCreatorRedemption(existing.id, input.userId);
      return { sessionId: existing.sessionId, book: payload, shareURL: sessionShareUrl(token), status: room.status, created: false as const };
    }

    const book = yield* SessionSharingPersistence.query("session.create.find_owned_book", (db) => db.select().from(books)
      .where(and(eq(books.id, input.bookId), eq(books.userId, input.userId), eq(books.isDeleted, false))).get());
    if (!book) return yield* routeFailure("SESSION_LINK_INVALID", 404, "Book not found", "session.create.book_lookup");
    const payload = yield* SessionSharingArtifacts.bookPayload(book);
    if (!payload) return yield* routeFailure("BOOK_NOT_READY", 422, "The book is not ready to share", "session.create.book_ready");
    const sessionId = crypto.randomUUID();
    const inviteId = crypto.randomUUID();
    const token = yield* SessionSharingArtifacts.createToken(input.userId, input.idempotencyKey);
    const tokenHash = yield* SessionSharingArtifacts.hashToken(token);
    const created = Effect.gen(function* () {
      yield* input.service.createRoomEffect({
        sessionId,
        initialSharerUserId: input.userId,
        bookContext: { bookId: payload.bookId, contentHash: payload.contentHash, format: payload.format },
        maxParticipants: 5,
      });
      yield* SessionSharingPersistence.query("session.create.insert_invite", (db) => db.insert(sessionInvites).values({
        id: inviteId,
        ownerUserId: input.userId,
        idempotencyKey: input.idempotencyKey,
        sessionId,
        sourceBookId: book.id,
        contentHash: payload.contentHash,
        format: payload.format,
        tokenHash,
        status: "open",
        createdAt: new Date(),
      }).run());
      yield* SessionSharingPersistence.query("session.create.insert_item", (db) => db.insert(sessionInviteItems).values({
        id: crypto.randomUUID(),
        inviteId,
        fileR2Key: book.fileR2Key!,
        coverR2Key: book.coverR2Key,
        fileHash: payload.contentHash,
        fileSize: payload.fileSize,
        createdAt: new Date(),
      }).run());
      yield* ensureCreatorRedemption(inviteId, input.userId);
    });

    return yield* created.pipe(Effect.map(() => ({ sessionId, book: payload, shareURL: sessionShareUrl(token), status: "active" as const, created: true as const })),
      Effect.catchAllCause((primaryCause) => {
        if (isAlreadyInitialized(primaryCause)) return Effect.failCause(primaryCause);
        const compensation = input.service.endRoomEffect({ sessionId, actingUserId: input.userId, expectedControllerGeneration: 1 });
        return compensation.pipe(
          Effect.catchAllCause((compensationCause) => Effect.gen(function* () {
            const diagnostics = yield* SessionSharingDiagnostics;
            yield* diagnostics.emit({
              operation: "session.create.compensation",
              stage: "sharing.create.compensation",
              outcome: "failed",
              code: "SERVICE_UNAVAILABLE",
              causeSummary: `primary=${causeSummary(primaryCause)}; compensation=${causeSummary(compensationCause)}`,
              correlationId: input.correlationId,
            });
            return yield* Effect.failCause(primaryCause);
          })),
          Effect.flatMap(() => Effect.failCause(primaryCause)),
        );
      }));
  });
  return diagnosed("session.create", "sharing.create", input.correlationId, program);
}

export interface RedeemSessionInput {
  readonly userId: string;
  readonly token: string;
  readonly service: SessionSharingService;
  readonly correlationId: string;
}

export function redeemSession(input: RedeemSessionInput) {
  const program = Effect.gen(function* () {
    const tokenHash = yield* SessionSharingArtifacts.hashToken(input.token);
    const invite = yield* SessionSharingPersistence.query("session.redeem.find_invite", (db) => db.select()
      .from(sessionInvites).where(eq(sessionInvites.tokenHash, tokenHash)).get());
    if (!invite || invite.status !== "open") return yield* routeFailure("SESSION_LINK_INVALID", 404, "This session link is not valid", "session.redeem.invite_lookup");
    const room = yield* getRoomOrConfirmedMissing(input.service, invite.sessionId);
    if (!room || room.status === "ended") {
      yield* sessionEnded(invite.id);
      return yield* routeFailure("SESSION_ENDED", 410, "This reading session has ended", "session.redeem.room_lookup");
    }
    const item = yield* SessionSharingPersistence.query("session.redeem.find_item", (db) => db.select()
      .from(sessionInviteItems).where(eq(sessionInviteItems.inviteId, invite.id)).get());
    if (!item) return yield* routeFailure("SERVICE_UNAVAILABLE", 503, "Book package is unavailable", "session.redeem.item_lookup");
    const book = yield* SessionSharingPersistence.query("session.redeem.find_book", (db) => db.select()
      .from(books).where(eq(books.id, invite.sourceBookId)).get());
    if (!book) return yield* routeFailure("SESSION_LINK_INVALID", 404, "Book is unavailable", "session.redeem.book_lookup");
    const payload = yield* SessionSharingArtifacts.bookPayload(book);
    if (!payload) return yield* routeFailure("BOOK_NOT_READY", 422, "The book is still being prepared", "session.redeem.book_ready");
    const redemptionId = crypto.randomUUID();
    const response = { inviteId: invite.id, sessionId: invite.sessionId, book: payload, status: room.status, redemptionId };
    if (!hasRedeemResponseContract(response)) {
      return yield* routeFailure("INVALID_RESPONSE", 500, "The reading session could not prepare a valid response", "session.redeem.response_contract");
    }
    yield* SessionSharingPersistence.query("session.redeem.insert_redemption", (db) => db.insert(sessionInviteRedemptions).values({
      id: redemptionId,
      inviteId: invite.id,
      userId: input.userId,
      bookStatus: "pending",
      membershipStatus: "pending",
      createdAt: new Date(),
      updatedAt: new Date(),
    }).onConflictDoNothing().run());
    const redemption = yield* SessionSharingPersistence.query("session.redeem.find_redemption", (db) => db.select()
      .from(sessionInviteRedemptions)
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, input.userId)))
      .get());
    return { ...response, redemptionId: redemption?.id ?? response.redemptionId };
  });
  return diagnosed("session.redeem", "sharing.redeem", input.correlationId, program);
}

export function activeSessions(userId: string, correlationId: string, service: SessionSharingService) {
  const program = Effect.gen(function* () {
    const rows = yield* SessionSharingPersistence.query("session.active.find_sessions", (db) => db.select({
      redemption: sessionInviteRedemptions,
      invite: sessionInvites,
      book: books,
    })
      .from(sessionInviteRedemptions)
      .innerJoin(sessionInvites, and(
        eq(sessionInvites.id, sessionInviteRedemptions.inviteId),
        eq(sessionInvites.status, "open"),
      ))
      .innerJoin(books, eq(books.id, sessionInvites.sourceBookId))
      .where(and(
        eq(sessionInviteRedemptions.userId, userId),
        inArray(sessionInviteRedemptions.membershipStatus, ["pending", "admitted", "left"]),
      ))
      .all());
    const sessions = yield* Effect.forEach(rows, (row) => Effect.gen(function* () {
      const { redemption, invite, book } = row;
      const room = yield* getRoomOrConfirmedMissing(service, invite.sessionId);
      if (!room || room.status === "ended") return null;
      const payload = yield* SessionSharingArtifacts.bookPayload(book);
      if (!payload) return null;
      return {
        sessionId: invite.sessionId,
        book: payload,
        status: room.status,
        controllerUserId: room.controllerUserId,
        joinedAt: redemption.createdAt,
      };
    }), { concurrency: 4 });
    return { sessions: sessions.filter((session) => session !== null) };
  });
  return diagnosed("session.active", "sharing.active", correlationId, program);
}

export interface ReadSessionInput {
  readonly userId: string;
  readonly sessionId: string;
  readonly service: SessionSharingService;
  readonly correlationId: string;
}

export function readSession(input: ReadSessionInput) {
  const program = Effect.gen(function* () {
    const invite = yield* SessionSharingPersistence.query("session.read.find_invite", (db) => db.select()
      .from(sessionInvites).where(and(eq(sessionInvites.sessionId, input.sessionId), eq(sessionInvites.status, "open"))).get());
    if (!invite) return yield* routeFailure("SESSION_LINK_INVALID", 404, "Session not found", "session.read.invite_lookup");
    const redemption = yield* SessionSharingPersistence.query("session.read.find_redemption", (db) => db.select()
      .from(sessionInviteRedemptions).where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, input.userId))).get());
    if (invite.ownerUserId !== input.userId && !redemption) return yield* routeFailure("FORBIDDEN", 403, "You are not part of this reading session", "session.read.authorization");
    if (redemption?.membershipStatus === "removed") return yield* routeFailure("REMOVED_FROM_SESSION", 403, "You cannot access this reading session", "session.read.removed");
    const room = yield* input.service.getRoomStatusEffect({ sessionId: input.sessionId });
    if (!room || room.status === "ended") return yield* routeFailure("SESSION_ENDED", 410, "This reading session has ended", "session.read.room_lookup");
    const book = yield* SessionSharingPersistence.query("session.read.find_book", (db) => db.select()
      .from(books).where(eq(books.id, invite.sourceBookId)).get());
    if (!book) return yield* routeFailure("SESSION_LINK_INVALID", 404, "Book is unavailable", "session.read.book_lookup");
    const payload = yield* SessionSharingArtifacts.bookPayload(book);
    if (!payload) return yield* routeFailure("BOOK_NOT_READY", 422, "The book is not ready to share", "session.read.book_ready");
    return { ...room, book: payload };
  });
  return diagnosed("session.status", "sharing.status", input.correlationId, program);
}

export function bookReady(input: { userId: string; sessionId: string; token: string; contentHash: string; service: SessionSharingService; wsUrl?: string; correlationId: string }) {
  const program = Effect.gen(function* () {
    const tokenHash = yield* SessionSharingArtifacts.hashToken(input.token);
    const invite = yield* SessionSharingPersistence.query("session.admission.find_invite", (db) => db.select().from(sessionInvites)
      .where(and(eq(sessionInvites.sessionId, input.sessionId), eq(sessionInvites.tokenHash, tokenHash), eq(sessionInvites.status, "open"))).get());
    if (!invite) return yield* routeFailure("SESSION_LINK_INVALID", 404, "This session link is not valid", "session.admission.invite_lookup");
    if (invite.contentHash !== input.contentHash) return yield* routeFailure("BOOK_HASH_MISMATCH", 422, "The downloaded book could not be verified", "session.admission.book_hash");
    const redemption = yield* SessionSharingPersistence.query("session.admission.find_redemption", (db) => db.select().from(sessionInviteRedemptions)
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, input.userId))).get());
    if (!redemption) return yield* routeFailure("BOOK_NOT_READY", 422, "Redeem the session before admission", "session.admission.redemption_lookup");
    const profile = yield* SessionSharingProfileLookup.get(input.userId);
    const ticket = yield* input.service.issueAdmissionTicketEffect({
      sessionId: input.sessionId,
      inviteId: invite.id,
      userId: input.userId,
      contentHash: input.contentHash,
      profile: { displayName: profile?.displayName?.trim() || "Reader", ...(profile?.avatarUrl ? { avatarUrl: profile.avatarUrl } : {}) },
    });
    yield* SessionSharingPersistence.query("session.admission.save_ticket", (db) => db.update(sessionInviteRedemptions)
      .set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: ticket.claims.ticketId, updatedAt: new Date() })
      .where(eq(sessionInviteRedemptions.id, redemption.id)).run());
    const wsBase = input.wsUrl ?? "wss://sharing.fidexa.org";
    return { admissionTicket: ticket.admissionTicket, wsUrl: `${wsBase}/v2/sessions/${input.sessionId}/wss`, status: ticket.status, roomEpoch: ticket.roomEpoch, connectionGeneration: ticket.claims.connectionGeneration };
  });
  return diagnosed("session.book_ready", "sharing.admission", input.correlationId, program);
}

export function rejoinSession(input: { userId: string; sessionId: string; contentHash: string; service: SessionSharingService; wsUrl?: string; correlationId: string }) {
  const program = Effect.gen(function* () {
    const invite = yield* SessionSharingPersistence.query("session.rejoin.find_invite", (db) => db.select().from(sessionInvites)
      .where(and(eq(sessionInvites.sessionId, input.sessionId), eq(sessionInvites.status, "open"))).get());
    if (!invite) return yield* routeFailure("SESSION_ENDED", 410, "This reading session has ended", "session.rejoin.invite_lookup");
    if (invite.contentHash !== input.contentHash) return yield* routeFailure("BOOK_HASH_MISMATCH", 422, "The downloaded book could not be verified", "session.rejoin.book_hash");
    const redemption = yield* SessionSharingPersistence.query("session.rejoin.find_redemption", (db) => db.select().from(sessionInviteRedemptions)
      .where(and(eq(sessionInviteRedemptions.inviteId, invite.id), eq(sessionInviteRedemptions.userId, input.userId))).get());
    if (!redemption || redemption.membershipStatus === "removed") return yield* routeFailure("REMOVED_FROM_SESSION", 403, "You cannot rejoin this reading session", "session.rejoin.authorization");
    const profile = yield* SessionSharingProfileLookup.get(input.userId);
    const ticket = yield* input.service.issueAdmissionTicketEffect({
      sessionId: input.sessionId,
      inviteId: invite.id,
      userId: input.userId,
      contentHash: input.contentHash,
      profile: { displayName: profile?.displayName?.trim() || "Reader", ...(profile?.avatarUrl ? { avatarUrl: profile.avatarUrl } : {}) },
    });
    yield* SessionSharingPersistence.query("session.rejoin.save_ticket", (db) => db.update(sessionInviteRedemptions)
      .set({ bookStatus: "ready", membershipStatus: "admitted", lastAdmissionTicketId: ticket.claims.ticketId, updatedAt: new Date() })
      .where(eq(sessionInviteRedemptions.id, redemption.id)).run());
    return { admissionTicket: ticket.admissionTicket, wsUrl: `${input.wsUrl ?? "wss://sharing.fidexa.org"}/v2/sessions/${input.sessionId}/wss`, status: ticket.status, roomEpoch: ticket.roomEpoch, connectionGeneration: ticket.claims.connectionGeneration };
  });
  return diagnosed("session.rejoin", "sharing.admission", input.correlationId, program);
}

export function turnCredentials(input: { sessionId: string; authorization: string; correlationId: string }) {
  const program = Effect.gen(function* () {
    const transport = yield* SessionSharingTransport;
    const target = new URL(`https://sharing-worker.internal/v2/sessions/${encodeURIComponent(input.sessionId)}/turn`);
    const response = yield* transport.fetch(new Request(target, { method: "GET", headers: { authorization: input.authorization, "x-rishi-correlation-id": input.correlationId } }));
    if (!response.ok) {
      const body = yield* Effect.tryPromise({ try: () => response.clone().json() as Promise<unknown>, catch: () => null })
        .pipe(Effect.orElseSucceed(() => null));
      const code = body && typeof body === "object" && "code" in body && typeof body.code === "string" && /^[A-Z][A-Z0-9_]{1,63}$/.test(body.code)
        ? body.code
        : response.status === 401 ? "AUTH_REQUIRED" : response.status === 403 ? "FORBIDDEN" : response.status === 404 ? "SESSION_ENDED" : "TURN_UNAVAILABLE";
      return yield* routeFailure(code, response.status, "Unable to retrieve reading audio credentials", "sharing.turn");
    }
    const payload = yield* Effect.tryPromise({ try: () => response.json() as Promise<unknown>, catch: (cause) => new SessionSharingInvalidResponseFailure({ code: "INVALID_RESPONSE", message: "Invalid reading audio response", status: 502, correlationId: input.correlationId, cause }) });
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) return yield* routeFailure("INVALID_RESPONSE", 502, "Invalid reading audio response", "sharing.turn");
    return payload;
  });
  const mapped = program.pipe(Effect.catchTag("SessionSharingTransportFailure", () =>
    routeFailure("TURN_UNAVAILABLE", 503, "Unable to retrieve reading audio credentials", "sharing.turn"),
  ));
  return diagnosed("turn.credentials", "sharing.turn", input.correlationId, mapped);
}
