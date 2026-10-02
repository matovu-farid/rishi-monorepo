import { DurableObject } from "cloudflare:workers";
import { ClientMsg, MAX_LEGACY_RAW_FRAME_BYTES } from "./legacySchemas";
import { ControllerSnapshot, isSnapshotForBook } from "@rishi/sharing-protocol/sync";
import type { ControllerSnapshot as ControllerSnapshotT } from "@rishi/sharing-protocol/sync";
import type { SessionState, BookContextT } from "./types";
import { parseSubprotocols } from "./wsCreds";
import {
  issueAdmissionTicket,
  issueReconnectToken,
  verifyAdmissionTicket,
  verifyReconnectToken,
} from "./tokens";
import { CONFIG } from "./config";
import { RateBucket } from "./rateLimit";
import { AuthVerificationError, resolveTestGlobalAuth, verifyAuthAuthorizationEffect } from "./auth";
import { generateTurnIceServersEffect } from "./turn";
import { appleFenceMatches, appleRoomFenceMatches, buildAppleRosterMessage } from "./appleTopology";
import { Cause, Chunk, Effect, Exit, Layer, Option } from "effect";
import {
  AppleRoomDiagnostics,
  AppleRoomRuntime,
  AppleRoomStorage,
  AuthIdentityLookup,
  makeAppleRoomLayer,
  makeSharingWorkerLayer,
} from "./session-sharing-effect";
import { failureTag, SharingDependencyFailure, TurnUnavailableFailure } from "./session-sharing-errors";

// Re-exported so call-site tests can assert both modules share the same gate
// implementation (see test/globalTestAuthGate.test.ts, finding 253-003).
export { resolveTestGlobalAuth } from "./auth";

interface Env {
  WORKER_HMAC_SECRET: string;
  AUTH_BASE_URL: string;
  /**
   * When set to "1", enables the E2E test-bearer shortcut (`userId--DisplayName`
   * jwt format) for the WebSocket upgrade path. Mirrors the gateway-side gate
   * in `auth.ts:verifyAuth`. MUST be unset in production — otherwise any
   * client could connect as an arbitrary userId without a real auth check.
   */
  TEST_AUTH_ALLOWED?: string;
  TURN_KEY_ID?: string;
  TURN_API_TOKEN?: string;
  ENVIRONMENT?: string;
}

const KEY = "state";
const APPLE_KEY = "apple-state";

type AppleParticipant = {
  userId: string;
  profile: { displayName: string; avatarUrl?: string };
  joinedAt: number;
  inviteId: string;
  contentHash: string;
  bookReady: boolean;
  connectionGeneration: number;
  connectionState: "connected" | "reconnecting";
  reservedUntil?: number;
};

type PendingAdmissionLease = {
  ticketId: string;
  userId: string;
  inviteId: string;
  connectionGeneration: number;
  expiresAt: number;
};

type AuthoritativeSyncSnapshot = {
  sessionId: string;
  roomEpoch: number;
  controllerGeneration: number;
  connectionGeneration: number;
  controllerUserId: string;
  sequence: number;
  frame: ControllerSnapshotT;
};

type AppleObservation = {
  observationId: string;
  eventId: string;
  eventType: "membership" | "authority" | "sync" | "playback" | "terminal";
  roomEpoch: number;
  controllerGeneration: number;
  connectionGeneration: number;
  readerSequence?: number;
  frameDigest?: string;
  occurredAt: number;
};

type AppleStoredState = {
  sessionId: string;
  sessionKind: "apple";
  admissionPolicy: "invite-ticket";
  bookContext: BookContextT;
  initialSharerUserId: string;
  controllerUserId: string;
  controllerGeneration: number;
  roomEpoch: number;
  rosterGeneration: number;
  status: "waiting" | "active" | "ended";
  maxParticipants: number;
  createdAt: number;
  lastEmptyAt?: number;
  controllerReturnUntil?: number;
  controllerReturnUserId?: string;
  participants: Record<string, AppleParticipant>;
  seatReservations: Record<string, { reservedUntil: number; connectionGeneration: number }>;
  removedUserIds: string[];
  speakerFloor: { userId: string; requestId: string; grantedAt: number } | null;
  consumedAdmissionTicketIds: Record<string, number>;
  pendingAdmissionLeases: Record<string, PendingAdmissionLease>;
  latestSyncSnapshot?: AuthoritativeSyncSnapshot;
  startupExpiresAt: number;
  hasEverBeenOccupied: boolean;
  observations: AppleObservation[];
  /** Permanent account-deletion fences, distinct from restorable removals. */
  deletedAccountTombstones: Record<string, { deletionOperationId: string; deletedAt: number }>;
  accountRevocations: Record<string, { accountUserId: string; result: { ok: true; status: "ended" | "removed" | "not_found" } }>;
  /** Bounded per-room budget for SDP/ICE metadata relays. */
  sdpRelayCount?: number;
};

type ApplePurgeResult =
  | { ok: true }
  | { ok: false; code: "CONFLICT"; error: string };

class AppleRoomError extends Error {
  readonly _tag = "AppleRoomError";
  constructor(public readonly code: string, message = code) {
    super(message);
  }
}

type StoredState = SessionState & { hostProfileFallback: { displayName: string; avatarUrl?: string } };

interface AttachedMeta {
  userId: string;
  displayName: string;
  avatarUrl?: string;
}

type WssFailureCode =
  | "ACCOUNT_DELETED"
  | "ACCOUNT_DELETION_IN_PROGRESS"
  | "ADMISSION_TICKET_EXPIRED"
  | "ADMISSION_TICKET_MISMATCH"
  | "ADMISSION_TICKET_STALE"
  | "ADMISSION_REQUIRED"
  | "AUTH_REQUIRED"
  | "FORBIDDEN"
  | "INTERNAL_ERROR"
  | "INVALID_ADMISSION"
  | "MALFORMED_WEBSOCKET_REQUEST"
  | "SERVICE_UNAVAILABLE"
  | "SESSION_ENDED"
  | "SESSION_NOT_FOUND"
  | "WEBSOCKET_UPGRADE_REQUIRED";

/**
 * Resolve a WebSocket bearer to an `AttachedMeta` using the test-shortcut
 * `userId--DisplayName` format ONLY when `TEST_AUTH_ALLOWED === "1"`.
 * Returns `null` to indicate the caller should fall through to production
 * verification. Exposed for unit testing the gate without driving a full
 * miniflare WS upgrade.
 */
export function resolveTestBearer(
  bearer: string,
  testAuthAllowed: string | undefined,
): AttachedMeta | null {
  if (testAuthAllowed !== "1") return null;
  const m = bearer.match(/^([^\s-]+(?:-[^\s-]+)*)--(.+)$/);
  if (!m) return null;
  return {
    userId: m[1]!,
    displayName: m[2]!.replace(/_/g, " "),
  };
}

/**
 * `data.channel.relay` is a test-only path (E2E fake adapter). The worker
 * accepts it iff `TEST_AUTH_ALLOWED === "1"` so a production client
 * can't (a) bypass the per-peer RTCDataChannel sync path or (b) starve
 * legitimate `sync.frame` traffic that shares the per-user RateBucket.
 * Exposed for unit testing the gate.
 */
export function isDataChannelRelayAllowed(
  testAuthAllowed: string | undefined,
): boolean {
  return testAuthAllowed === "1";
}

export class AppleSessionRoom extends DurableObject<Env> {
  private lastRequestSharer = new Map<string, number>();
  private pendingSockets = new Map<string, { ws: WebSocket; hasBookFile: boolean }>();
  private frameBuckets = new Map<string, RateBucket>();
  private appleByteBuckets = new Map<string, RateBucket>();
  private supersededAppleSockets = new WeakSet<WebSocket>();
  /**
   * WebSocket Hibernation API destroys the JS object between messages, so the
   * in-memory `pendingSockets` map is empty on wake. The pending socket's
   * `hasBookFile` is encoded in the WS tag (see `acceptWebSocket(server, [JSON.stringify({ meta, isReconnect, hasBookFile, pending })])`),
   * and `state.pendingJoiners` is the durable source of truth for who's pending.
   * This flag is reset every fresh instance — when false, the next handler that
   * reads `pendingSockets` walks `getWebSockets()` and re-populates the map.
   */
  private _pendingHydrated = false;

  private log(event: string, fields: Record<string, unknown> = {}) {
    console.log(JSON.stringify({ event, ts: Date.now(), ...fields }));
  }

  private async runAppleEffect<A>(
    operation: string,
    program: Effect.Effect<A, unknown, AppleRoomStorage | AppleRoomRuntime | AppleRoomDiagnostics | AuthIdentityLookup | import("./session-sharing-effect").TurnCredentialProvider | import("./session-sharing-effect").SharingHttpClient | import("./session-sharing-effect").SharingDiagnostics>,
    correlationId?: string,
    stage: "internal.room-command" | "websocket.room" = "internal.room-command",
  ): Promise<A> {
    const startedAt = Date.now();
    const observed = program.pipe(Effect.tapErrorCause((cause) => Effect.gen(function* () {
      const diagnostics = yield* AppleRoomDiagnostics;
      const failure = Option.getOrUndefined(Cause.failureOption(cause));
      const tagged = failureTag(failure ?? Cause.squash(cause));
      const causeCodes = Chunk.toReadonlyArray(Cause.failures(cause)).map((causeFailure) =>
        causeFailure instanceof AppleRoomError
          ? causeFailure.code
          : causeFailure instanceof SharingDependencyFailure
            ? `DEPENDENCY_${causeFailure.dependency.toUpperCase()}`
            : failureTag(causeFailure),
      );
      yield* diagnostics.emit({
        event: "apple.room.command_failed",
        operation,
        stage: failure instanceof SharingDependencyFailure && failure.stage === "internal.room-storage" ? "internal.room-storage" : stage,
        outcome: "error",
        code: failure instanceof AppleRoomError ? failure.code : tagged,
        ...(causeCodes.length > 0 ? { causeCodes } : {}),
        ...(correlationId ? { correlationId } : {}),
        durationMs: Math.max(0, Date.now() - startedAt),
        causeKind: failure ? "typed_failure" : "defect_or_interruption",
      });
    })));
    const layer = Layer.mergeAll(
      makeAppleRoomLayer(this.ctx.storage, (diagnostic) => this.log(diagnostic.event, diagnostic)),
      makeSharingWorkerLayer({ AUTH_BASE_URL: this.env.AUTH_BASE_URL, TURN_KEY_ID: this.env.TURN_KEY_ID, TURN_API_TOKEN: this.env.TURN_API_TOKEN }),
    );
    const exit = await Effect.runPromiseExit(Effect.provide(observed, layer));
    if (Exit.isSuccess(exit)) return exit.value;
    const failure = Option.getOrUndefined(Cause.failureOption(exit.cause));
    if (failure instanceof AppleRoomError) throw failure;
    throw new Error("internal command failed");
  }

  private reportAppleHandledFailure(
    failure: unknown,
    operation: string,
    correlationId: string | undefined,
    fallbackStage: "auth.provider" | "internal.room-command" | "internal.room-storage" | "websocket.room",
  ): Effect.Effect<void, never, AppleRoomDiagnostics> {
    if (failure instanceof AppleRoomError) return Effect.void;

    const nestedFailure = failure instanceof AuthVerificationError ? failure.cause : failure;
    const dependencyFailure = nestedFailure instanceof SharingDependencyFailure
      ? nestedFailure
      : failure instanceof SharingDependencyFailure ? failure : undefined;
    const code = dependencyFailure
      ? `DEPENDENCY_${dependencyFailure.dependency.toUpperCase()}`
      : failure instanceof AuthVerificationError ? failure.code : failureTag(failure);
    const safeCode = /^[A-Z][A-Z0-9_]{0,63}$/.test(code) ? code : "UNEXPECTED_FAILURE";
    const causeCode = failureTag(dependencyFailure?.cause ?? nestedFailure);
    const safeCauseCode = /^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(causeCode) ? causeCode : "UnexpectedFailure";
    const stage = dependencyFailure?.stage === "internal.room-storage"
      ? "internal.room-storage"
      : dependencyFailure?.stage === "auth.provider" || failure instanceof AuthVerificationError
        ? "auth.provider"
        : dependencyFailure?.stage === "internal.room-command"
          ? "internal.room-command"
        : fallbackStage;

    return Effect.flatMap(AppleRoomDiagnostics, (diagnostics) => diagnostics.emit({
      event: "apple.room.command_failed",
      operation,
      stage,
      outcome: "error",
      code: safeCode,
      causeCodes: dependencyFailure ? [safeCode, safeCauseCode] : [safeCauseCode],
      ...(correlationId ? { correlationId } : {}),
      durationMs: 0,
      causeKind: "typed_failure",
    })).pipe(Effect.catchAll(() => Effect.void));
  }

  private appleStateEffect(): Effect.Effect<AppleStoredState | undefined, SharingDependencyFailure, AppleRoomStorage> {
    return Effect.gen(function* () {
      const storage = yield* AppleRoomStorage;
      const state = yield* storage.get<AppleStoredState>(APPLE_KEY);
      if (state) {
        if (!Number.isSafeInteger(state.rosterGeneration)) state.rosterGeneration = 0;
        state.pendingAdmissionLeases ??= {};
        state.observations ??= [];
        state.deletedAccountTombstones ??= {};
        state.accountRevocations ??= {};
        state.startupExpiresAt ??= state.createdAt + CONFIG.APPLE_INITIAL_CONNECT_MS;
        state.seatReservations ??= {};
        state.hasEverBeenOccupied ??= Object.values(state.participants).some((participant) =>
          participant.connectionState === "connected" || participant.reservedUntil !== undefined)
          || Object.keys(state.seatReservations).length > 0
          || Object.keys(state.consumedAdmissionTicketIds).length > 0
          || Boolean(state.latestSyncSnapshot);
      }
      return state;
    });
  }

  private requireAppleStateEffect(sessionId?: string): Effect.Effect<AppleStoredState, AppleRoomError | SharingDependencyFailure, AppleRoomStorage> {
    return this.appleStateEffect().pipe(Effect.flatMap((state) =>
      !state || (sessionId && state.sessionId !== sessionId)
        ? Effect.fail(new AppleRoomError("SESSION_NOT_FOUND"))
        : Effect.succeed(state),
    ));
  }

  private saveAppleStateEffect(state: AppleStoredState): Effect.Effect<void, SharingDependencyFailure, AppleRoomStorage> {
    return Effect.flatMap(AppleRoomStorage, (storage) => storage.put(APPLE_KEY, state));
  }

  private scheduleAppleAlarmEffect(state: AppleStoredState): Effect.Effect<void, SharingDependencyFailure, AppleRoomStorage | AppleRoomRuntime> {
    const self = this;
    return Effect.gen(function* () {
      const storage = yield* AppleRoomStorage;
      const runtime = yield* AppleRoomRuntime;
      yield* storage.setAlarm(self.nextAppleAlarm(state, runtime.now()));
    });
  }

  private nextAppleAlarm(state: AppleStoredState, now: number) {
    const deadlines = Object.values(state.seatReservations).map((reservation) => reservation.reservedUntil);
    deadlines.push(...Object.values(state.pendingAdmissionLeases).map((lease) => lease.expiresAt));
    if (!state.hasEverBeenOccupied) deadlines.push(state.startupExpiresAt);
    else if (state.lastEmptyAt) deadlines.push(state.lastEmptyAt + CONFIG.APPLE_EMPTY_ROOM_MS);
    if (state.status === "ended") deadlines.push(now + CONFIG.STORAGE_PURGE_AFTER_END_MS);
    return deadlines.length > 0 ? Math.min(...deadlines) : now + CONFIG.APPLE_EMPTY_ROOM_MS;
  }

  private endAppleRoomEffect(state: AppleStoredState, reason: "controller_ended" | "room_expired"): Effect.Effect<ReturnType<AppleSessionRoom["appleStatus"]>, SharingDependencyFailure, AppleRoomStorage | AppleRoomRuntime> {
    const self = this;
    return Effect.gen(function* () {
      if (state.status === "ended") return self.appleStatus(state);
      const runtime = yield* AppleRoomRuntime;
      state.status = "ended";
      state.roomEpoch += 1;
      state.pendingAdmissionLeases = {};
      self.clearAppleSnapshot(state);
      state.rosterGeneration += 1;
      self.recordObservation(state, "terminal", 0, {}, runtime.now(), runtime.randomUUID);
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        self.broadcastApple({ t: "session.ended", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, reason });
        for (const ws of self.sockets()) ws.close(1000, "ended");
      });
      yield* Effect.flatMap(AppleRoomStorage, (storage) => storage.setAlarm(runtime.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS));
      return self.appleStatus(state);
    });
  }

  private resolveExpiredAppleControllerEffect(state: AppleStoredState, now: number) {
    const self = this;
    return Effect.gen(function* () {
      const replacement = self.oldestConnectedAppleParticipant(state);
      if (!replacement) {
        if (!state.hasEverBeenOccupied) return false;
        state.controllerGeneration += 1;
        state.lastEmptyAt = now;
        yield* self.endAppleRoomEffect(state, "room_expired");
        return true;
      }
      const runtime = yield* AppleRoomRuntime;
      state.controllerUserId = replacement.userId;
      state.controllerGeneration += 1;
      state.roomEpoch += 1;
      self.clearAppleSnapshot(state);
      self.recordObservation(state, "authority", replacement.connectionGeneration, {}, runtime.now(), runtime.randomUUID);
      yield* Effect.sync(() => self.broadcastControllerChange(state));
      return false;
    });
  }

  private expireAppleReservationsEffect(state: AppleStoredState, now: number) {
    const self = this;
    return Effect.gen(function* () {
      let removedMember = false;
      let controllerRemoved = false;
      for (const [userId, reservation] of Object.entries(state.seatReservations)) {
        if (reservation.reservedUntil > now) continue;
        delete state.seatReservations[userId];
        const participant = state.participants[userId];
        if (participant?.connectionState === "reconnecting" && participant.connectionGeneration === reservation.connectionGeneration) {
          delete state.participants[userId];
          self.removeAppleAdmissionLeases(state, userId);
          state.rosterGeneration += 1;
          removedMember = true;
          controllerRemoved ||= state.controllerUserId === userId;
          if (state.speakerFloor?.userId === userId) {
            const floor = state.speakerFloor;
            state.speakerFloor = null;
            yield* Effect.sync(() => self.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId }));
          }
        }
      }
      if (state.controllerReturnUntil && state.controllerReturnUntil <= now) {
        state.controllerReturnUntil = undefined;
        state.controllerReturnUserId = undefined;
      }
      if (controllerRemoved && (yield* self.resolveExpiredAppleControllerEffect(state, now))) return true;
      if (removedMember) yield* Effect.sync(() => self.broadcastAppleRoster(state));
      return false;
    });
  }

  private expireAdmissionLeasesEffect(state: AppleStoredState, now: number) {
    const self = this;
    return Effect.gen(function* () {
      let removedMember = false;
      let controllerRemoved = false;
      for (const [ticketId, lease] of Object.entries(state.pendingAdmissionLeases)) {
        if (lease.expiresAt > now) continue;
        const current = state.pendingAdmissionLeases[ticketId];
        const participant = state.participants[lease.userId];
        if (current?.ticketId === ticketId && current.connectionGeneration === lease.connectionGeneration) {
          delete state.pendingAdmissionLeases[ticketId];
          if (participant?.connectionState === "reconnecting" && participant.connectionGeneration === lease.connectionGeneration) {
            delete state.participants[lease.userId];
            self.removeAppleAdmissionLeases(state, lease.userId);
            removedMember = true;
            controllerRemoved ||= state.controllerUserId === lease.userId;
          }
        }
      }
      if (controllerRemoved && (yield* self.resolveExpiredAppleControllerEffect(state, now))) return true;
      if (removedMember && self.connectedCount(state) === 0) state.lastEmptyAt = now;
      if (removedMember) yield* Effect.sync(() => self.broadcastAppleRoster(state));
      return false;
    });
  }

  private async runAppleRoomEffect<A>(operation: string, program: Effect.Effect<A, unknown, AppleRoomStorage | AppleRoomRuntime | AppleRoomDiagnostics | AuthIdentityLookup | import("./session-sharing-effect").TurnCredentialProvider | import("./session-sharing-effect").SharingHttpClient | import("./session-sharing-effect").SharingDiagnostics>, correlationId?: string, stage: "internal.room-command" | "websocket.room" = "internal.room-command") {
    return this.runAppleEffect(operation, program, correlationId, stage);
  }

  private rejectWss(request: Request, status: number, code: WssFailureCode, stage: string, correlationId = this.correlationFor(request), upstreamStatus?: number, socketTagBytes?: number): Response {
    const requestCorrelationId = correlationId;
    this.log("sharing.wss.rejected", {
      correlationId: requestCorrelationId,
      operation: "websocket.connect",
      stage,
      code,
      status,
      ...(upstreamStatus !== undefined ? { upstreamStatus } : {}),
      ...(socketTagBytes !== undefined ? { socketTagBytes } : {}),
    });
    return Response.json({
      code,
      error: code === "AUTH_REQUIRED" ? "Sign in to use this reading session." : "Could not connect to the reading session.",
      correlationId: requestCorrelationId,
      ...(this.env.ENVIRONMENT === "development" || this.env.ENVIRONMENT === "staging" ? { diagnostic: `${stage}:${code}` } : {}),
    }, {
      status,
      headers: {
        "x-rishi-correlation-id": requestCorrelationId,
        "x-rishi-error-code": code,
        "x-rishi-error-stage": stage,
      },
    });
  }

  private correlationFor(request: Request): string {
    const suppliedCorrelationId = request.headers.get("x-rishi-correlation-id");
    return suppliedCorrelationId && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(suppliedCorrelationId)
      ? suppliedCorrelationId
      : crypto.randomUUID();
  }

  private rejectAuth(request: Request, error: unknown, correlationId?: string): Response {
    const code = error instanceof AuthVerificationError ? error.code : "INTERNAL_ERROR";
    const status = error instanceof AuthVerificationError ? error.status : 502;
    const upstreamStatus = error instanceof AuthVerificationError ? error.upstreamStatus : undefined;
    return this.rejectWss(request, status, code, "auth.provider", correlationId, upstreamStatus);
  }

  private bucketFor(userId: string): RateBucket {
    let b = this.frameBuckets.get(userId);
    if (!b) {
      b = new RateBucket({
        capacity: CONFIG.RATE_LIMITS.framesPerSocketPerSec * 2,
        refillPerSec: CONFIG.RATE_LIMITS.framesPerSocketPerSec,
      });
      this.frameBuckets.set(userId, b);
    }
    return b;
  }

  private appleByteBucketFor(userId: string): RateBucket {
    let bucket = this.appleByteBuckets.get(userId);
    if (!bucket) {
      bucket = new RateBucket({
        capacity: CONFIG.RATE_LIMITS.appleSignalingBytesPerUserPerSec * 2,
        refillPerSec: CONFIG.RATE_LIMITS.appleSignalingBytesPerUserPerSec,
      });
      this.appleByteBuckets.set(userId, bucket);
    }
    return bucket;
  }

  // ---------- Apple session RPC ----------
  /**
   * HMAC-authenticated internal commands enter through this single RPC
   * boundary. Expected domain failures must be data, not rejected DO RPCs:
   * Workerd treats a thrown RPC rejection as an uncaught worker exception,
   * which can corrupt the isolated-storage test frame even when the gateway
   * later converts it to an HTTP response.
   */
  async executeInternal(input: { action: string; payload: unknown; correlationId?: string }): Promise<unknown> {
    try {
      switch (input.action) {
        case "createRoom": return await this.createRoom(input.payload as Parameters<AppleSessionRoom["createRoom"]>[0], input.correlationId);
        case "getRoomStatus": return await this.getRoomStatus(input.correlationId);
        case "getAppleRedeemInfo": return await this.getAppleRedeemInfo(input.correlationId);
        case "markBookReadyAndIssueAdmissionTicket": return await this.markBookReadyAndIssueAdmissionTicket(input.payload as Parameters<AppleSessionRoom["markBookReadyAndIssueAdmissionTicket"]>[0], input.correlationId);
        case "startRoom": return await this.startRoom(input.payload as Parameters<AppleSessionRoom["startRoom"]>[0], input.correlationId);
        case "leaveRoom": return await this.leaveRoom(input.payload as Parameters<AppleSessionRoom["leaveRoom"]>[0], input.correlationId);
        case "transferController": return await this.transferController(input.payload as Parameters<AppleSessionRoom["transferController"]>[0], input.correlationId);
        case "removeAppleParticipant": return await this.removeAppleParticipant(input.payload as Parameters<AppleSessionRoom["removeAppleParticipant"]>[0], input.correlationId);
        case "restoreAppleParticipant": return await this.restoreAppleParticipant(input.payload as Parameters<AppleSessionRoom["restoreAppleParticipant"]>[0], input.correlationId);
        case "endRoom": return await this.endRoom(input.payload as Parameters<AppleSessionRoom["endRoom"]>[0], input.correlationId);
        case "revokeAccountReferences": return await this.revokeAccountReferences(input.payload as Parameters<AppleSessionRoom["revokeAccountReferences"]>[0], input.correlationId);
        case "getMemberObservations": return await this.getMemberObservations(input.payload as Parameters<AppleSessionRoom["getMemberObservations"]>[0], input.correlationId);
        case "purgeAppleRoom": return await this.purgeAppleRoom(input.correlationId);
        default: return { ok: false, code: "INVALID_COMMAND", error: "unsupported internal command" };
      }
    } catch (error) {
      if (error instanceof AppleRoomError) {
        return { ok: false, code: error.code, error: error.message };
      }
      this.log("apple.internal.command_failed", {
        operation: input.action,
        stage: "internal.room-command",
        code: "SERVICE_UNAVAILABLE",
        status: 500,
        correlationId: input.correlationId,
      });
      return { ok: false, code: "SERVICE_UNAVAILABLE", error: "internal command failed" };
    }
  }

  async createRoom(input: {
    sessionId: string;
    initialSharerUserId: string;
    bookContext: BookContextT;
    maxParticipants?: number;
  }, correlationId?: string): Promise<{ sessionId: string; roomEpoch: number; controllerGeneration: number }> {
    const self = this;
    return this.runAppleRoomEffect("createRoom", Effect.gen(function* () {
      const storage = yield* AppleRoomStorage;
      const runtime = yield* AppleRoomRuntime;
      if ((yield* storage.get(KEY)) || (yield* storage.get(APPLE_KEY))) yield* Effect.fail(new AppleRoomError("ALREADY_INITIALIZED"));
      const now = runtime.now();
      const state: AppleStoredState = {
        sessionId: input.sessionId,
        sessionKind: "apple",
        admissionPolicy: "invite-ticket",
        bookContext: input.bookContext,
        initialSharerUserId: input.initialSharerUserId,
        controllerUserId: input.initialSharerUserId,
        controllerGeneration: 1,
        roomEpoch: 1,
        rosterGeneration: 0,
        status: "active",
        maxParticipants: Math.max(1, Math.min(input.maxParticipants ?? CONFIG.MAX_PARTICIPANTS, CONFIG.MAX_PARTICIPANTS)),
        createdAt: now,
        lastEmptyAt: now,
        startupExpiresAt: now + CONFIG.APPLE_INITIAL_CONNECT_MS,
        hasEverBeenOccupied: false,
        participants: {},
        seatReservations: {},
        removedUserIds: [],
        speakerFloor: null,
        consumedAdmissionTicketIds: {},
        pendingAdmissionLeases: {},
        observations: [],
        deletedAccountTombstones: {},
        accountRevocations: {},
        sdpRelayCount: 0,
      };
      yield* storage.put(APPLE_KEY, state);
      yield* storage.setAlarm(state.startupExpiresAt);
      yield* Effect.sync(() => self.log("apple.session.created", { sessionId: state.sessionId }));
      return { sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration };
    }), correlationId);
  }

  async getRoomStatus(correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("getRoomStatus", Effect.gen(function* () {
      const state = yield* self.appleStateEffect();
      if (!state) return null;
      return {
        sessionId: state.sessionId,
        status: state.status,
        roomEpoch: state.roomEpoch,
        controllerGeneration: state.controllerGeneration,
        controllerUserId: state.controllerUserId,
        participants: Object.values(state.participants).map(({ userId, profile, joinedAt, bookReady, connectionState }) => ({ userId, profile, joinedAt, bookReady, connectionState })),
        maxParticipants: state.maxParticipants,
        removedUserIds: [...state.removedUserIds],
      };
    }), correlationId);
  }

  async getAppleRedeemInfo(correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("getAppleRedeemInfo", Effect.gen(function* () {
      const state = yield* self.appleStateEffect();
      if (!state) return null;
      return { sessionId: state.sessionId, bookContext: state.bookContext, status: state.status, roomEpoch: state.roomEpoch };
    }), correlationId);
  }

  async getTurnCredentials(input: { userId: string; ttlSeconds?: number; correlationId?: string }) {
    const self = this;
    const result = await this.runAppleRoomEffect("getTurnCredentials", Effect.gen(function* () {
      const state = yield* self.appleStateEffect();
      if (!state) return { ok: false as const, code: "SESSION_NOT_FOUND", error: "session not found" };
      if (state.status === "ended" || state.participants[input.userId]?.connectionState !== "connected") return { ok: false as const, code: "FORBIDDEN", error: "not a current session member" };
      return yield* generateTurnIceServersEffect(self.env, input.ttlSeconds, input.correlationId).pipe(
        Effect.map((iceServers) => ({ iceServers })),
        Effect.catchTag("TurnUnavailableFailure", (_error: TurnUnavailableFailure) =>
          Effect.succeed({ ok: false as const, code: "TURN_UNAVAILABLE", error: "TURN credentials unavailable" }),
        ),
      );
    }), input.correlationId);
    return result;
  }

  async markBookReadyAndIssueAdmissionTicket(input: {
    sessionId: string;
    inviteId: string;
    userId: string;
    contentHash: string;
    profile?: { displayName: string; avatarUrl?: string };
  }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("markBookReadyAndIssueAdmissionTicket", Effect.gen(function* () {
      const runtime = yield* AppleRoomRuntime;
      const state = yield* self.requireAppleStateEffect(input.sessionId);
      if (state.status === "ended") return yield* Effect.fail(new AppleRoomError("SESSION_ENDED"));
      if (state.bookContext.contentHash !== input.contentHash) return yield* Effect.fail(new AppleRoomError("BOOK_HASH_MISMATCH"));
      if (state.deletedAccountTombstones[input.userId]) return yield* Effect.fail(new AppleRoomError("ACCOUNT_DELETED"));
      if (state.removedUserIds.includes(input.userId)) return yield* Effect.fail(new AppleRoomError("REMOVED_FROM_SESSION"));
      const existing = state.participants[input.userId];
      const now = runtime.now();
      const expired = (yield* self.expireAppleReservationsEffect(state, now)) || (yield* self.expireAdmissionLeasesEffect(state, now));
      if (expired) return yield* Effect.fail(new AppleRoomError("SESSION_ENDED"));
      const occupied = self.appleOccupiedSeats(state);
      const alreadyConnected = existing?.connectionState === "connected";
      const alreadyReserved = (state.seatReservations[input.userId]?.reservedUntil ?? 0) > now;
      const alreadyLeased = Object.values(state.pendingAdmissionLeases).some((lease) => lease.userId === input.userId);
      if (!alreadyConnected && !alreadyReserved && !alreadyLeased && occupied >= state.maxParticipants) return yield* Effect.fail(new AppleRoomError("ROOM_FULL"));
      const generation = (existing?.connectionGeneration ?? state.seatReservations[input.userId]?.connectionGeneration ?? 0) + 1;
      const participant: AppleParticipant = existing ?? {
        userId: input.userId,
        profile: input.profile ?? { displayName: input.userId },
        joinedAt: now,
        inviteId: input.inviteId,
        contentHash: input.contentHash,
        bookReady: true,
        connectionGeneration: generation,
        connectionState: "connected",
      };
      participant.inviteId = input.inviteId;
      participant.contentHash = input.contentHash;
      participant.bookReady = true;
      participant.connectionGeneration = generation;
      participant.connectionState = "reconnecting";
      delete participant.reservedUntil;
      state.participants[input.userId] = participant;
      delete state.seatReservations[input.userId];
      if (state.controllerUserId === input.userId) self.clearAppleSnapshot(state);
      const ticketId = runtime.randomUUID();
      const ticket = yield* runtime.issueAdmissionTicket({
        sessionId: state.sessionId,
        inviteId: input.inviteId,
        userId: input.userId,
        ticketId,
        roomEpoch: state.roomEpoch,
        connectionGeneration: generation,
        ttlMs: CONFIG.ADMISSION_TICKET_TTL_MS,
      }, self.env.WORKER_HMAC_SECRET);
      for (const [id, lease] of Object.entries(state.pendingAdmissionLeases)) {
        if (lease.userId === input.userId) delete state.pendingAdmissionLeases[id];
      }
      state.pendingAdmissionLeases[ticketId] = {
        ticketId,
        userId: input.userId,
        inviteId: input.inviteId,
        connectionGeneration: generation,
        expiresAt: ticket.claims.exp,
      };
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => self.closeStaleAppleSockets(input.userId, generation, "reissued"));
      yield* self.scheduleAppleAlarmEffect(state);
      return { admissionTicket: ticket.token, claims: ticket.claims, roomEpoch: state.roomEpoch, status: state.status };
    }), correlationId);
  }

  async startRoom(input: { actingUserId: string; expectedControllerGeneration: number }, correlationId?: string) {
    return this.runAppleRoomEffect("startRoom", this.startRoomEffect(input), correlationId);
  }

  private startRoomEffect(input: { actingUserId: string; expectedControllerGeneration: number }) {
    const self = this;
    return Effect.gen(function* () {
      const state = yield* self.requireAppleStateEffect();
      self.assertController(state, input.actingUserId, input.expectedControllerGeneration);
      if (state.status === "ended") return yield* Effect.fail(new AppleRoomError("SESSION_ENDED"));
      if (state.status === "active") return self.appleStatus(state);
      state.status = "active";
      state.roomEpoch += 1;
      self.clearAppleSnapshot(state);
      state.rosterGeneration += 1;
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        self.broadcastApple({ t: "session.state", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, status: state.status, controllerUserId: state.controllerUserId });
        self.broadcastAppleRoster(state);
      });
      return self.appleStatus(state);
    });
  }

  async leaveRoom(input: { actingUserId: string; deliberate?: boolean }, correlationId?: string) {
    return this.runAppleRoomEffect("leaveRoom", this.leaveRoomEffect(input), correlationId);
  }

  private leaveRoomEffect(input: { actingUserId: string; deliberate?: boolean }) {
    const self = this;
    return Effect.gen(function* () {
      const state = yield* self.requireAppleStateEffect();
      if (!state.participants[input.actingUserId]) return self.appleStatus(state);
      delete state.participants[input.actingUserId];
      delete state.seatReservations[input.actingUserId];
      self.removeAppleAdmissionLeases(state, input.actingUserId);
      const controllerChanged = state.controllerUserId === input.actingUserId;
      const floor = state.speakerFloor?.userId === input.actingUserId ? state.speakerFloor : null;
      if (floor) state.speakerFloor = null;
      if (controllerChanged) self.chooseAppleController(state, false);
      state.rosterGeneration += 1;
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        if (floor) self.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
        self.closeAppleSockets(input.actingUserId, "left");
        if (controllerChanged) self.broadcastControllerChange(state);
        self.broadcastAppleRoster(state);
      });
      yield* self.scheduleAppleAlarmEffect(state);
      return self.appleStatus(state);
    });
  }

  async transferController(input: { actingUserId: string; targetUserId: string; expectedControllerGeneration: number }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("transferController", Effect.gen(function* () {
      const state = yield* self.requireAppleStateEffect();
      self.assertController(state, input.actingUserId, input.expectedControllerGeneration);
      const target = state.participants[input.targetUserId];
      if (!target || target.connectionState !== "connected") return yield* Effect.fail(new AppleRoomError("NO_SUCH_PARTICIPANT"));
      state.controllerUserId = input.targetUserId;
      state.controllerGeneration += 1;
      state.roomEpoch += 1;
      self.clearAppleSnapshot(state);
      state.rosterGeneration += 1;
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        self.broadcastApple({ t: "controller.transfer", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, toUserId: input.targetUserId });
        self.broadcastAppleRoster(state);
      });
      return self.appleStatus(state);
    }), correlationId);
  }

  async endRoom(input: { actingUserId: string; expectedControllerGeneration: number }, correlationId?: string) {
    return this.runAppleRoomEffect("endRoom", this.endRoomEffect(input), correlationId);
  }

  private endRoomEffect(input: { actingUserId: string; expectedControllerGeneration: number }) {
    const self = this;
    return Effect.gen(function* () {
      const state = yield* self.requireAppleStateEffect();
      self.assertController(state, input.actingUserId, input.expectedControllerGeneration);
      return yield* self.endAppleRoomEffect(state, "controller_ended");
    });
  }

  /**
   * Permanently remove an ended Apple room. This is reachable only through
   * the HMAC-authenticated v2 internal command surface; account deletion ends
   * the room first so an active room can never be purged accidentally.
   */
  async purgeAppleRoom(correlationId?: string): Promise<ApplePurgeResult> {
    const self = this;
    return this.runAppleRoomEffect("purgeAppleRoom", Effect.gen(function* () {
      const state = yield* self.appleStateEffect();
      if (!state) return { ok: true } as const;
      if (state.status !== "ended") return { ok: false, code: "CONFLICT", error: "room must be ended before purge" } as const;
      const storage = yield* AppleRoomStorage;
      yield* Effect.sync(() => { for (const socket of self.sockets()) socket.close(1000, "purged"); });
      yield* storage.delete(APPLE_KEY);
      yield* storage.deleteAlarm();
      yield* Effect.sync(() => self.log("apple.session.purged", { sessionId: state.sessionId }));
      return { ok: true } as const;
    }), correlationId);
  }

  async revokeAccountReferences(input: { accountUserId: string; deletionOperationId: string }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("revokeAccountReferences", Effect.gen(function* () {
      const runtime = yield* AppleRoomRuntime;
      const state = yield* self.requireAppleStateEffect();
      const previous = state.accountRevocations[input.deletionOperationId];
      if (previous) return previous.result;
      state.deletedAccountTombstones[input.accountUserId] = { deletionOperationId: input.deletionOperationId, deletedAt: runtime.now() };
      const participant = state.participants[input.accountUserId];
      const wasController = state.controllerUserId === input.accountUserId;
      delete state.participants[input.accountUserId];
      delete state.seatReservations[input.accountUserId];
      self.removeAppleAdmissionLeases(state, input.accountUserId);
      state.removedUserIds = state.removedUserIds.filter((userId) => userId !== input.accountUserId);
      if (state.speakerFloor?.userId === input.accountUserId) state.speakerFloor = null;
      if (state.controllerReturnUserId === input.accountUserId) {
        state.controllerReturnUserId = undefined;
        state.controllerReturnUntil = undefined;
      }
      if (state.latestSyncSnapshot?.controllerUserId === input.accountUserId) self.clearAppleSnapshot(state);

      let result: { ok: true; status: "ended" | "removed" | "not_found" };
      let controllerChanged = false;
      if (state.initialSharerUserId === input.accountUserId) {
        state.initialSharerUserId = "";
        state.controllerUserId = "";
        state.controllerReturnUserId = undefined;
        state.controllerReturnUntil = undefined;
        self.clearAppleSnapshot(state);
        result = { ok: true, status: "ended" };
        state.accountRevocations[input.deletionOperationId] = { accountUserId: input.accountUserId, result };
        yield* self.saveAppleStateEffect(state);
        yield* self.endAppleRoomEffect(state, "controller_ended");
        return result;
      }
      if (wasController) {
        const replacement = self.oldestConnectedAppleParticipant(state);
        if (!replacement) {
          result = { ok: true, status: "ended" };
          state.accountRevocations[input.deletionOperationId] = { accountUserId: input.accountUserId, result };
          yield* self.endAppleRoomEffect(state, "controller_ended");
          return result;
        }
        state.controllerUserId = replacement.userId;
        state.controllerGeneration += 1;
        state.roomEpoch += 1;
        self.clearAppleSnapshot(state);
        controllerChanged = true;
      }
      if (participant) {
        state.rosterGeneration += 1;
        self.recordObservation(state, "membership", 0, {}, runtime.now(), runtime.randomUUID);
        result = { ok: true, status: "removed" };
      } else {
        result = { ok: true, status: "not_found" };
      }
      state.accountRevocations[input.deletionOperationId] = { accountUserId: input.accountUserId, result };
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        self.closeAppleSockets(input.accountUserId, "account deleted");
        if (controllerChanged) self.broadcastControllerChange(state);
        if (participant || controllerChanged) self.broadcastAppleRoster(state);
      });
      if (participant || controllerChanged) yield* self.scheduleAppleAlarmEffect(state);
      return result;
    }), correlationId);
  }

  async getMemberObservations(input: { sessionId: string; requestingUserId: string; afterObservationId?: string }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("getMemberObservations", Effect.gen(function* () {
      const state = yield* self.appleStateEffect();
      if (!state || state.sessionId !== input.sessionId) return { ok: false as const, code: "SESSION_NOT_FOUND", error: "session not found" };
      const membership = input.requestingUserId === state.initialSharerUserId
        ? "owner"
        : state.participants[input.requestingUserId]?.connectionState === "connected" ? "participant" : null;
      if (!membership) return { ok: false as const, code: "FORBIDDEN", error: "not a current session member" };
      const after = input.afterObservationId;
      const start = after ? state.observations.findIndex((value) => value.observationId === after) + 1 : 0;
      if (after && start === 0) return { ok: false as const, code: "OBSERVATION_CURSOR_EXPIRED", error: "observation cursor expired" };
      return {
        sessionId: state.sessionId,
        membership,
        status: state.status,
        roomEpoch: state.roomEpoch,
        controllerGeneration: state.controllerGeneration,
        observations: state.observations.slice(start, start + 100),
      };
    }), correlationId);
  }

  async removeAppleParticipant(input: { actingUserId: string; userId: string; expectedControllerGeneration: number }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("removeAppleParticipant", Effect.gen(function* () {
      const state = yield* self.requireAppleStateEffect();
      self.assertController(state, input.actingUserId, input.expectedControllerGeneration);
      if (input.userId === input.actingUserId) return yield* Effect.fail(new AppleRoomError("FORBIDDEN"));
      if (!state.participants[input.userId]) return yield* Effect.fail(new AppleRoomError("NO_SUCH_PARTICIPANT"));
      delete state.participants[input.userId];
      delete state.seatReservations[input.userId];
      self.removeAppleAdmissionLeases(state, input.userId);
      const floor = state.speakerFloor?.userId === input.userId ? state.speakerFloor : null;
      if (floor) state.speakerFloor = null;
      if (!state.removedUserIds.includes(input.userId)) state.removedUserIds.push(input.userId);
      state.rosterGeneration += 1;
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        if (floor) self.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
        self.closeAppleSockets(input.userId, "removed");
        self.broadcastApple({ t: "participant.remove", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, userId: input.userId, reason: "removed" });
        self.broadcastAppleRoster(state);
      });
      yield* self.scheduleAppleAlarmEffect(state);
      return self.appleStatus(state);
    }), correlationId);
  }

  async restoreAppleParticipant(input: { actingUserId: string; userId: string; inviteId: string; contentHash: string; expectedControllerGeneration: number; profile?: { displayName: string; avatarUrl?: string } }, correlationId?: string) {
    const self = this;
    return this.runAppleRoomEffect("restoreAppleParticipant", Effect.gen(function* () {
      const runtime = yield* AppleRoomRuntime;
      const state = yield* self.requireAppleStateEffect();
      self.assertController(state, input.actingUserId, input.expectedControllerGeneration);
      if (state.deletedAccountTombstones[input.userId]) return yield* Effect.fail(new AppleRoomError("ACCOUNT_DELETED"));
      if (!state.removedUserIds.includes(input.userId)) return yield* Effect.fail(new AppleRoomError("NO_SUCH_PARTICIPANT"));
      if (state.bookContext.contentHash !== input.contentHash) return yield* Effect.fail(new AppleRoomError("BOOK_HASH_MISMATCH"));
      const expired = yield* self.expireAppleReservationsEffect(state, runtime.now());
      if (expired) return yield* Effect.fail(new AppleRoomError("SESSION_ENDED"));
      if (self.appleOccupiedSeats(state) >= state.maxParticipants) return yield* Effect.fail(new AppleRoomError("ROOM_FULL"));
      const beforeRestore = structuredClone(state);
      const attempt = Effect.gen(function* () {
        state.removedUserIds = state.removedUserIds.filter((id) => id !== input.userId);
        const generation = (state.participants[input.userId]?.connectionGeneration ?? state.seatReservations[input.userId]?.connectionGeneration ?? 0) + 1;
        const participant: AppleParticipant = state.participants[input.userId] ?? {
          userId: input.userId,
          profile: input.profile ?? { displayName: input.userId },
          joinedAt: runtime.now(),
          inviteId: input.inviteId,
          contentHash: input.contentHash,
          bookReady: true,
          connectionGeneration: generation,
          connectionState: "reconnecting",
        };
        participant.inviteId = input.inviteId;
        participant.contentHash = input.contentHash;
        participant.bookReady = true;
        participant.connectionGeneration = generation;
        participant.connectionState = "reconnecting";
        delete participant.reservedUntil;
        state.participants[input.userId] = participant;
        delete state.seatReservations[input.userId];
        if (state.controllerUserId === input.userId) self.clearAppleSnapshot(state);
        const ticketId = runtime.randomUUID();
        const ticket = yield* runtime.issueAdmissionTicket({
          sessionId: state.sessionId,
          inviteId: input.inviteId,
          userId: input.userId,
          ticketId,
          roomEpoch: state.roomEpoch,
          connectionGeneration: generation,
          ttlMs: CONFIG.ADMISSION_TICKET_TTL_MS,
        }, self.env.WORKER_HMAC_SECRET);
        for (const [id, lease] of Object.entries(state.pendingAdmissionLeases)) {
          if (lease.userId === input.userId) delete state.pendingAdmissionLeases[id];
        }
        state.pendingAdmissionLeases[ticketId] = { ticketId, userId: input.userId, inviteId: input.inviteId, connectionGeneration: generation, expiresAt: ticket.claims.exp };
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.closeStaleAppleSockets(input.userId, generation, "reissued"));
        yield* self.scheduleAppleAlarmEffect(state);
        state.rosterGeneration += 1;
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.broadcastAppleRoster(state));
        return { admissionTicket: ticket.token, claims: ticket.claims, roomEpoch: state.roomEpoch, status: state.status };
      });
      return yield* attempt.pipe(Effect.tapErrorCause(() => self.saveAppleStateEffect(beforeRestore)));
    }), correlationId);
  }

  private async appleState() {
    const state = await this.ctx.storage.get<AppleStoredState>(APPLE_KEY);
    if (state) {
      if (!Number.isSafeInteger(state.rosterGeneration)) state.rosterGeneration = 0;
      state.pendingAdmissionLeases ??= {};
      state.observations ??= [];
      state.deletedAccountTombstones ??= {};
      state.accountRevocations ??= {};
      state.startupExpiresAt ??= state.createdAt + CONFIG.APPLE_INITIAL_CONNECT_MS;
      state.seatReservations ??= {};
      // A provisional admission ticket creates a reconnecting participant
      // before any WebSocket is admitted. Only evidence of an actual socket
      // may put a legacy room on the post-occupancy empty-room timer.
      state.hasEverBeenOccupied ??= Object.values(state.participants).some((participant) =>
        participant.connectionState === "connected" || participant.reservedUntil !== undefined)
        || Object.keys(state.seatReservations).length > 0
        || Object.keys(state.consumedAdmissionTicketIds).length > 0
        || Boolean(state.latestSyncSnapshot);
    }
    return state;
  }
  private async saveAppleState(state: AppleStoredState) { await this.ctx.storage.put(APPLE_KEY, state); }
  private async requireAppleState(sessionId?: string) {
    const state = await this.appleState();
    if (!state || (sessionId && state.sessionId !== sessionId)) throw new AppleRoomError("SESSION_NOT_FOUND");
    return state;
  }
  private appleStatus(state: AppleStoredState) { return { sessionId: state.sessionId, status: state.status, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, controllerUserId: state.controllerUserId }; }
  private assertController(state: AppleStoredState, userId: string, generation: number) {
    if (state.controllerUserId !== userId) throw new AppleRoomError("FORBIDDEN");
    if (state.controllerGeneration !== generation) throw new AppleRoomError("STALE_CONTROLLER_GENERATION");
  }
  private async expireAppleReservations(state: AppleStoredState, now: number): Promise<boolean> {
    let removedMember = false;
    let controllerRemoved = false;
    for (const [userId, reservation] of Object.entries(state.seatReservations)) {
      if (reservation.reservedUntil > now) continue;
      delete state.seatReservations[userId];
      const participant = state.participants[userId];
      if (participant?.connectionState === "reconnecting" && participant.connectionGeneration === reservation.connectionGeneration) {
        delete state.participants[userId];
        this.removeAppleAdmissionLeases(state, userId);
        state.rosterGeneration += 1;
        removedMember = true;
        controllerRemoved ||= state.controllerUserId === userId;
        if (state.speakerFloor?.userId === userId) {
          const floor = state.speakerFloor;
          state.speakerFloor = null;
          this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
        }
      }
    }
    if (state.controllerReturnUntil && state.controllerReturnUntil <= now) {
      state.controllerReturnUntil = undefined;
      state.controllerReturnUserId = undefined;
    }
    if (controllerRemoved && await this.resolveExpiredAppleController(state, now)) return true;
    if (removedMember) this.broadcastAppleRoster(state);
    return false;
  }
  private async expireAdmissionLeases(state: AppleStoredState, now: number): Promise<boolean> {
    let removedMember = false;
    let controllerRemoved = false;
    for (const [ticketId, lease] of Object.entries(state.pendingAdmissionLeases)) {
      // A ticket id and generation both fence delayed alarms/reissues: stale
      // entries cannot remove a newer generation for the same participant.
      if (lease.expiresAt > now) continue;
      const current = state.pendingAdmissionLeases[ticketId];
      const participant = state.participants[lease.userId];
      if (current?.ticketId === ticketId && current.connectionGeneration === lease.connectionGeneration) {
        delete state.pendingAdmissionLeases[ticketId];
        if (participant?.connectionState === "reconnecting" && participant.connectionGeneration === lease.connectionGeneration) {
          delete state.participants[lease.userId];
          this.removeAppleAdmissionLeases(state, lease.userId);
          removedMember = true;
          controllerRemoved ||= state.controllerUserId === lease.userId;
        }
      }
    }
    if (controllerRemoved && await this.resolveExpiredAppleController(state, now)) return true;
    if (removedMember && this.connectedCount(state) === 0) state.lastEmptyAt = now;
    if (removedMember) this.broadcastAppleRoster(state);
    return false;
  }
  private appleOccupiedSeats(state: AppleStoredState): number {
    const occupied = new Set(
      Object.values(state.participants)
        .filter((participant) => participant.connectionState === "connected")
        .map((participant) => participant.userId),
    );
    for (const userId of Object.keys(state.seatReservations)) occupied.add(userId);
    for (const lease of Object.values(state.pendingAdmissionLeases)) occupied.add(lease.userId);
    return occupied.size;
  }
  private removeAppleAdmissionLeases(state: AppleStoredState, userId: string) {
    for (const [ticketId, lease] of Object.entries(state.pendingAdmissionLeases)) {
      if (lease.userId === userId) delete state.pendingAdmissionLeases[ticketId];
    }
  }
  private async resolveExpiredAppleController(state: AppleStoredState, now: number): Promise<boolean> {
    const replacement = this.oldestConnectedAppleParticipant(state);
    if (!replacement) {
      // The creator may still be preparing the local book after creation.
      // Expiring a provisional ticket must not end a never-occupied room
      // before its separate initial-connection deadline.
      if (!state.hasEverBeenOccupied) return false;
      // Fence a stale controller socket before the terminal room epoch is
      // persisted and broadcast by endAppleRoom.
      state.controllerGeneration += 1;
      state.lastEmptyAt = now;
      await this.endAppleRoom(state, "room_expired");
      return true;
    }
    state.controllerUserId = replacement.userId;
    state.controllerGeneration += 1;
    state.roomEpoch += 1;
    this.clearAppleSnapshot(state);
    this.recordObservation(state, "authority", replacement.connectionGeneration);
    this.broadcastControllerChange(state);
    return false;
  }
  private connectedCount(state: AppleStoredState): number {
    return this.sockets().filter((socket) => {
      const meta = this.metaFor(socket);
      const participant = meta && state.participants[meta.userId];
      const current = participant?.connectionState === "connected"
        && participant.connectionGeneration === this.appleSocketGeneration(socket);
      if (!current && meta && this.appleSocketGeneration(socket) >= 0) {
        this.supersededAppleSockets.add(socket);
        socket.close(4000, "stale connection");
      }
      return current && !this.supersededAppleSockets.has(socket);
    }).length;
  }
  private chooseAppleController(state: AppleStoredState, unexpected: boolean) {
    if (unexpected) {
      state.controllerReturnUserId = state.initialSharerUserId;
      state.controllerReturnUntil = Date.now() + CONFIG.APPLE_CONTROLLER_RECLAIM_MS;
    }
    const next = this.oldestConnectedAppleParticipant(state);
    if (!next) { state.lastEmptyAt = Date.now(); return; }
    state.controllerUserId = next.userId;
    state.controllerGeneration += 1;
    state.roomEpoch += 1;
    this.clearAppleSnapshot(state);
  }
  private oldestConnectedAppleParticipant(state: AppleStoredState): AppleParticipant | undefined {
    return Object.values(state.participants)
      .filter((participant) => participant.connectionState === "connected")
      .sort((a, b) => a.joinedAt - b.joinedAt || a.userId.localeCompare(b.userId))[0];
  }
  private broadcastApple(message: Record<string, unknown>) { for (const ws of this.sockets()) this.sendTo(ws, message); }
  private broadcastAppleRoster(state: AppleStoredState) { this.broadcastApple(buildAppleRosterMessage(state)); }
  private broadcastControllerChange(state: AppleStoredState) {
    this.broadcastApple({ t: "controller.transfer", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, toUserId: state.controllerUserId });
  }
  private closeAppleSockets(userId: string, reason: string) { for (const ws of this.sockets()) if (this.metaFor(ws)?.userId === userId) ws.close(1000, reason); }
  private closeStaleAppleSockets(userId: string, connectionGeneration: number, reason: string) {
    for (const socket of this.sockets()) {
      if (this.metaFor(socket)?.userId !== userId || this.appleSocketGeneration(socket) === connectionGeneration) continue;
      this.supersededAppleSockets.add(socket);
      socket.close(4000, reason);
    }
  }
  private async endAppleRoom(state: AppleStoredState, reason: "controller_ended" | "room_expired") {
    if (state.status === "ended") return this.appleStatus(state);
    state.status = "ended";
    state.roomEpoch += 1;
    state.pendingAdmissionLeases = {};
    this.clearAppleSnapshot(state);
    state.rosterGeneration += 1;
    this.recordObservation(state, "terminal", 0);
    await this.saveAppleState(state);
    this.broadcastApple({ t: "session.ended", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, reason });
    for (const ws of this.sockets()) ws.close(1000, "ended");
    await this.ctx.storage.setAlarm(Date.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS);
    return this.appleStatus(state);
  }

  private clearAppleSnapshot(state: AppleStoredState) {
    delete state.latestSyncSnapshot;
  }

  private recordObservation(
    state: AppleStoredState,
    eventType: AppleObservation["eventType"],
    connectionGeneration: number,
    fields: Pick<AppleObservation, "readerSequence" | "frameDigest"> = {},
    occurredAt = Date.now(),
    randomUUID: () => string = () => crypto.randomUUID(),
  ) {
    state.observations.push({
      observationId: randomUUID(),
      eventId: randomUUID(),
      eventType,
      roomEpoch: state.roomEpoch,
      controllerGeneration: state.controllerGeneration,
      connectionGeneration,
      ...fields,
      occurredAt,
    });
    if (state.observations.length > 100) state.observations.splice(0, state.observations.length - 100);
  }

  // ---------- HTTP RPC ----------
  async createSession(input: {
    sessionId: string;
    hostUserId: string;
    hostProfile: { displayName: string; avatarUrl?: string };
    bookContext: BookContextT;
    requiresApproval: boolean;
  }): Promise<void> {
    if (await this.ctx.storage.get(KEY)) throw new Error("already initialized");
    const state: StoredState = {
      sessionId: input.sessionId,
      hostUserId: input.hostUserId,
      sharerUserId: input.hostUserId,
      bookContext: input.bookContext,
      requiresApproval: input.requiresApproval,
      status: "live",
      createdAt: Date.now(),
      participants: {},
      pendingJoiners: {},
      joinTokens: {},
      hostProfileFallback: input.hostProfile,
    };
    await this.ctx.storage.put(KEY, state);
    this.log("session.created", { sessionId: input.sessionId, host: input.hostUserId });
  }

  async getState(): Promise<StoredState | null> {
    return (await this.ctx.storage.get<StoredState>(KEY)) ?? null;
  }

  async getInfoForRedeem() {
    const s = await this.ctx.storage.get<StoredState>(KEY);
    if (!s) return null;
    return {
      sessionId: s.sessionId,
      bookContext: s.bookContext,
      requiresApproval: s.requiresApproval,
      hostProfile: s.participants[s.hostUserId]?.profile ?? s.hostProfileFallback,
      status: s.status,
    };
  }

  // ---------- WS upgrade ----------
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("upgrade") !== "websocket") return this.rejectWss(request, 426, "WEBSOCKET_UPGRADE_REQUIRED", "websocket.upgrade");
    const creds = parseSubprotocols(request.headers.get("sec-websocket-protocol"));
    if (!creds.valid) {
      return creds.reason === "missing jwt"
        ? this.rejectWss(request, 401, "AUTH_REQUIRED", "websocket.authentication")
        : this.rejectWss(request, 400, "MALFORMED_WEBSOCKET_REQUEST", "websocket.protocol");
    }

    const appleRequest = request.headers.get("x-rishi-session-kind") === "apple";
    const correlationId = this.correlationFor(request);
    if (appleRequest) {
      return this.runAppleRoomEffect("websocket.admission", this.fetchAppleEffect(request, creds, correlationId), correlationId, "websocket.room");
    }
    const appleState = await this.runAppleRoomEffect("websocket.room_lookup", this.appleStateEffect(), correlationId, "websocket.room");
    if (appleState) return this.runAppleRoomEffect("websocket.admission", this.fetchAppleEffect(request, creds, correlationId), correlationId, "websocket.room");

    let meta: AttachedMeta;
    // Test shortcut: jwt of the form "userId--DisplayName" (with "_" for spaces
    // in the display name) — attach without remote auth. The double-dash and
    // underscore-for-space encoding keeps the bearer valid as an RFC 6455
    // WebSocket subprotocol token (no ":" or spaces allowed).
    //
    // SECURITY: this shortcut is gated on `TEST_AUTH_ALLOWED === "1"` so that
    // a public-internet client cannot bypass the real auth check by simply
    // crafting a `jwt.<base64url("alice--Alice")>` subprotocol. Mirrors the
    // gateway-side gate in `auth.ts:verifyAuth`. Production must leave this
    // env var unset (it is not declared in wrangler.jsonc's production env).
    const testMeta = resolveTestBearer(creds.jwt, this.env.TEST_AUTH_ALLOWED);
    if (testMeta) {
      meta = testMeta;
    } else {
      const testAuth = resolveTestGlobalAuth(this.env.TEST_AUTH_ALLOWED);
      if (testAuth) {
        meta = { userId: testAuth.userId, displayName: testAuth.displayName, avatarUrl: testAuth.avatarUrl };
      } else {
        // Production path: verify with Better Auth.
        try {
          const { verifyAuthToken } = await import("./auth");
          const u = await verifyAuthToken(creds.jwt, this.env);
          meta = { userId: u.userId, displayName: u.displayName, avatarUrl: u.avatarUrl };
        } catch (error) {
          return this.rejectAuth(request, error);
        }
      }
    }

    let isReconnect = false;
    if (creds.reconnectToken) {
      try {
        const v = await verifyReconnectToken(creds.reconnectToken, this.env.WORKER_HMAC_SECRET);
        if (v.userId === meta.userId) isReconnect = true;
      } catch { /* invalid token → treat as fresh */ }
    }

    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernation API: tag encodes per-socket metadata so it survives hibernation.
    // Keep tag well under 256-char cap: avoid storing the raw JWT.
    this.ctx.acceptWebSocket(server, [JSON.stringify({ meta, isReconnect })]);
    // RFC 6455 §4.2.2: if the client offers a `Sec-WebSocket-Protocol` header,
    // the server MUST echo back exactly one selected protocol in the 101
    // response — Chromium aborts the handshake otherwise ("Sent non-empty
    // 'Sec-WebSocket-Protocol' header but no response was received"). We
    // always pick `rishi.sharing.v1` (the protocol-version token); the other
    // offered tokens (`jwt.…`, `reconnect.…`) are bearer-carrying values and
    // are not selectable protocols.
    return new Response(null, {
      status: 101,
      webSocket: client,
      headers: { "sec-websocket-protocol": "rishi.sharing.v1" },
    });
  }

  private fetchAppleEffect(request: Request, creds: Extract<ReturnType<typeof parseSubprotocols>, { valid: true }>, correlationId: string) {
    const self = this;
    return Effect.gen(function* () {
      if (!(yield* self.appleStateEffect())) return self.rejectWss(request, 404, "SESSION_NOT_FOUND", "websocket.room", correlationId);
      if (!creds.admissionTicket) return self.rejectWss(request, 401, "ADMISSION_REQUIRED", "websocket.admission", correlationId);
      let meta: AttachedMeta;
      const testMeta = resolveTestBearer(creds.jwt, self.env.TEST_AUTH_ALLOWED);
      if (testMeta) meta = testMeta;
      else {
        const testAuth = resolveTestGlobalAuth(self.env.TEST_AUTH_ALLOWED);
        if (testAuth) meta = { userId: testAuth.userId, displayName: testAuth.displayName, avatarUrl: testAuth.avatarUrl };
        else {
          const authorization = `Bearer ${creds.jwt}`;
          const authResult = yield* verifyAuthAuthorizationEffect(authorization, correlationId).pipe(Effect.either);
          if (authResult._tag === "Left") {
            if (authResult.left.code !== "AUTH_REQUIRED") {
              yield* self.reportAppleHandledFailure(authResult.left, "websocket.admission.auth", correlationId, "auth.provider");
            }
            return self.rejectAuth(request, authResult.left, correlationId);
          }
          meta = { userId: authResult.right.userId, displayName: authResult.right.displayName, avatarUrl: authResult.right.avatarUrl };
        }
      }

      const runtime = yield* AppleRoomRuntime;
      const ticketResult = yield* runtime.verifyAdmissionTicket(creds.admissionTicket, self.env.WORKER_HMAC_SECRET).pipe(Effect.either);
      if (ticketResult._tag === "Left") {
        const expired = ticketResult.left.message === "admission ticket expired";
        return self.rejectWss(request, 401, expired ? "ADMISSION_TICKET_EXPIRED" : "INVALID_ADMISSION", "websocket.admission.signature", correlationId);
      }
      const ticket = ticketResult.right;
      // Durable Object socket tags have a strict 256-byte limit. The full
      // identity profile (especially OAuth avatar URLs) is already persisted
      // on the participant during book-ready; hibernation only needs the user
      // ID plus the Apple-session fencing metadata to route subsequent events.
      const socketTag = JSON.stringify({
        meta: { userId: meta.userId },
        apple: true,
        connectionGeneration: ticket.connectionGeneration,
        correlationId,
      });
      const socketTagBytes = new TextEncoder().encode(socketTag).byteLength;
      if (socketTagBytes > 256) {
        return self.rejectWss(request, 500, "INTERNAL_ERROR", "websocket.socket_tag", correlationId, undefined, socketTagBytes);
      }
      const storage = yield* AppleRoomStorage;
      const consumed = yield* storage.transaction(async (txn) => {
        const stored = await txn.get<AppleStoredState>(APPLE_KEY);
        if (!stored) throw new AppleRoomError("SESSION_NOT_FOUND");
        stored.pendingAdmissionLeases ??= {};
        stored.consumedAdmissionTicketIds ??= {};
        stored.deletedAccountTombstones ??= {};
        if (stored.status === "ended") throw new AppleRoomError("SESSION_ENDED");
        if (stored.deletedAccountTombstones[meta.userId]) throw new AppleRoomError("ACCOUNT_DELETED");
        if (ticket.sessionId !== stored.sessionId || ticket.userId !== meta.userId || ticket.roomEpoch !== stored.roomEpoch) throw new AppleRoomError("ADMISSION_TICKET_MISMATCH");
        const participant = stored.participants[meta.userId];
        const lease = stored.pendingAdmissionLeases[ticket.ticketId];
        if (!participant || !participant.bookReady || participant.inviteId !== ticket.inviteId
          || participant.connectionGeneration !== ticket.connectionGeneration) throw new AppleRoomError("ADMISSION_TICKET_STALE");
        if (!lease || lease.ticketId !== ticket.ticketId || lease.userId !== meta.userId
          || lease.inviteId !== ticket.inviteId || lease.connectionGeneration !== ticket.connectionGeneration
          || lease.expiresAt <= runtime.now() || stored.consumedAdmissionTicketIds[ticket.ticketId]) throw new AppleRoomError("ADMISSION_TICKET_STALE");
        stored.consumedAdmissionTicketIds[ticket.ticketId] = ticket.exp;
        delete stored.pendingAdmissionLeases[ticket.ticketId];
        participant.connectionState = "connected";
        stored.hasEverBeenOccupied = true;
        stored.lastEmptyAt = undefined;
        delete participant.reservedUntil;
        delete stored.seatReservations[meta.userId];
        if (meta.userId === stored.controllerReturnUserId && stored.controllerReturnUntil && stored.controllerReturnUntil > runtime.now()) {
          stored.controllerUserId = meta.userId;
          stored.controllerGeneration += 1;
          stored.roomEpoch += 1;
          self.clearAppleSnapshot(stored);
          stored.controllerReturnUntil = undefined;
          stored.controllerReturnUserId = undefined;
        }
        stored.rosterGeneration += 1;
        self.recordObservation(stored, "membership", ticket.connectionGeneration, {}, runtime.now(), runtime.randomUUID);
        await txn.put(APPLE_KEY, stored);
        return stored;
      }).pipe(Effect.either);
      if (consumed._tag === "Left") {
        const error = consumed.left;
        if (!(error instanceof AppleRoomError)) {
          yield* self.reportAppleHandledFailure(error, "websocket.admission.consume", correlationId, "internal.room-storage");
          return self.rejectWss(request, 500, "INTERNAL_ERROR", "websocket.admission.consume", correlationId);
        }
        if (error.code === "SESSION_NOT_FOUND") return self.rejectWss(request, 404, "SESSION_NOT_FOUND", "websocket.room", correlationId);
        if (error.code === "SESSION_ENDED") return self.rejectWss(request, 410, "SESSION_ENDED", "websocket.room", correlationId);
        if (error.code === "ACCOUNT_DELETED") return self.rejectWss(request, 403, "ACCOUNT_DELETED", "websocket.admission.policy", correlationId);
        if (error.code === "ADMISSION_TICKET_MISMATCH") return self.rejectWss(request, 401, "ADMISSION_TICKET_MISMATCH", "websocket.admission.consume", correlationId);
        return self.rejectWss(request, 401, "ADMISSION_TICKET_STALE", "websocket.admission.consume", correlationId);
      }
      const state = consumed.right;
      for (const oldSocket of self.sockets()) {
        if (self.metaFor(oldSocket)?.userId === meta.userId) {
          self.supersededAppleSockets.add(oldSocket);
          oldSocket.close(4000, "replaced");
        }
      }
      const { 0: client, 1: server } = new WebSocketPair();
      self.ctx.acceptWebSocket(server, [socketTag]);
      self.sendTo(server, { t: "session.state", status: state.status, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: ticket.connectionGeneration, controllerUserId: state.controllerUserId });
      self.sendTo(server, buildAppleRosterMessage(state));
      const snapshot = state.latestSyncSnapshot;
      if (snapshot
        && snapshot.sessionId === state.sessionId
        && snapshot.roomEpoch === state.roomEpoch
        && snapshot.controllerGeneration === state.controllerGeneration
        && snapshot.controllerUserId === state.controllerUserId
        && state.participants[snapshot.controllerUserId]?.connectionState === "connected"
        && state.participants[snapshot.controllerUserId]?.connectionGeneration === snapshot.connectionGeneration) {
        self.sendTo(server, { t: "sync.frame", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: snapshot.connectionGeneration, from: snapshot.controllerUserId, frame: snapshot.frame });
      } else {
        self.sendTo(server, { t: "sync.absent", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: ticket.connectionGeneration });
      }
      self.broadcastAppleRoster(state);
      yield* self.scheduleAppleAlarmEffect(state);
      return new Response(null, { status: 101, webSocket: client, headers: { "sec-websocket-protocol": "rishi.sharing.v1", "x-rishi-correlation-id": correlationId } });
    });
  }

  // ---------- Hibernation handlers ----------
  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    const appleState = await this.runAppleRoomEffect("websocket.route", this.appleStateEffect(), this.appleCorrelationFor(ws), "websocket.room");
    if (appleState || this.isAppleSocket(ws)) {
      if (!appleState) {
        this.sendError(ws, "session_not_found", "session is over");
        return;
      }
      await this.runAppleRoomEffect("websocket.message", this.handleAppleMessageEffect(ws, raw), this.appleCorrelationFor(ws), "websocket.room");
      return;
    }
    const rawBytes = typeof raw === "string" ? new TextEncoder().encode(raw).byteLength : raw.byteLength;
    if (rawBytes > MAX_LEGACY_RAW_FRAME_BYTES) { ws.close(1009, "frame too large"); return; }
    const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
    let parsed;
    try { parsed = ClientMsg.safeParse(JSON.parse(text)); }
    catch { this.sendError(ws, "bad_json", "could not parse"); return; }
    if (!parsed.success) { this.sendError(ws, "bad_msg", parsed.error.message); return; }
    const msg = parsed.data;
    const meta = this.metaFor(ws);
    if (!meta) { this.sendError(ws, "no_meta", "ws not initialized"); return; }

    if (!this.bucketFor(meta.userId).tryConsume()) {
      this.sendError(ws, "rate_limited", "too many messages");
      return;
    }

    switch (msg.t) {
      case "hello": await this.handleHello(ws, meta, msg.hasBookFile); break;
      case "ping":  this.sendTo(ws, { t: "pong" }); break;
      case "leave": await this.removeParticipant(meta.userId, "left"); ws.close(1000, "left"); break;
      case "sdp.offer":
      case "sdp.answer":
      case "ice": {
        const target = this.findSocketByUserId(msg.to);
        if (!target) { this.sendError(ws, "no_such_peer", `peer ${msg.to} not connected`); break; }
        if (msg.t !== "ice") {
          const state = await this.loadState();
          if (state) {
            state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
            if (state.sdpRelayCount > CONFIG.RATE_LIMITS.sdpRelaysPerSession) {
              this.sendError(ws, "rate_limited", "sdp relay budget exhausted"); break;
            }
            await this.saveState(state);
          }
        }
        this.sendTo(target, msg.t === "ice"
          ? { t: "ice", from: meta.userId, candidate: msg.candidate }
          : { t: msg.t, from: meta.userId, sdp: msg.sdp });
        break;
      }
      case "pass.sharer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "only host can pass"); break; }
        const target = state.participants[msg.to];
        if (!target) { this.sendError(ws, "no_such_peer", `${msg.to} not in session`); break; }
        if (!target.hasBookFile) { this.sendError(ws, "target_lacks_book", "target has no book file"); break; }
        // The participant record can outlive an active WS during the
        // reconnect grace window (connectionState='reconnecting'). Passing
        // the sharer role to a peer that is currently offline would mute
        // the session entirely — sync frames go to /dev/null. Surface a
        // clear error so the host UI can prompt for a different target.
        const targetWs = this.findSocketByUserId(msg.to);
        if (!targetWs || target.connectionState === "reconnecting") {
          this.sendError(ws, "target_offline", `${msg.to} is not currently connected`);
          break;
        }
        state.sharerUserId = msg.to;
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "role.transferred", newSharerId: msg.to });
        this.log("role.transferred", { sessionId: state.sessionId, from: meta.userId, to: msg.to });
        break;
      }
      case "request.sharer": {
        const last = this.lastRequestSharer.get(meta.userId) ?? 0;
        if (Date.now() - last < CONFIG.RATE_LIMITS.requestSharerCooldownMs) {
          this.sendError(ws, "rate_limited", "wait before requesting again"); break;
        }
        this.lastRequestSharer.set(meta.userId, Date.now());
        const state = await this.loadState();
        if (!state) break;
        const hostWs = this.findSocketByUserId(state.hostUserId);
        if (hostWs) this.sendTo(hostWs, { t: "peer.updated", userId: meta.userId, patch: { requestingSharer: true } });
        break;
      }
      case "has.book": {
        const state = await this.loadState();
        const self = state?.participants[meta.userId];
        if (!state || !self) break;
        self.hasBookFile = msg.value;
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: meta.userId, patch: { hasBookFile: msg.value } });
        break;
      }
      case "mic.state": {
        const state = await this.loadState();
        const self = state?.participants[meta.userId];
        if (!state || !self) break;
        // Host-mute stays sticky; self changes can't override host mute.
        if (self.micState !== "host-muted") {
          self.micState = msg.value;
          await this.saveState(state);
          for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: meta.userId, patch: { micState: msg.value } });
        }
        break;
      }
      case "mute.peer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        const target = state.participants[msg.userId];
        if (!target) { this.sendError(ws, "no_such_peer", msg.userId); break; }
        target.micState = msg.muted ? "host-muted" : "unmuted";
        await this.saveState(state);
        for (const s of this.sockets()) this.sendTo(s, { t: "peer.updated", userId: msg.userId, patch: { micState: target.micState } });
        break;
      }
      case "kick.peer": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        if (msg.userId === meta.userId) { this.sendError(ws, "forbidden", "cannot kick self"); break; }
        const target = this.findSocketByUserId(msg.userId);
        if (target) {
          this.sendTo(target, { t: "kicked", reason: "removed by host" });
          target.close(1000, "kicked");
        }
        await this.removeParticipant(msg.userId, "kicked");
        break;
      }
      case "approve.join": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        await this.rehydratePendingFromHibernation();
        const pending = this.pendingSockets.get(msg.userId);
        delete state.pendingJoiners[msg.userId];
        await this.saveState(state);
        if (!pending) break;
        this.pendingSockets.delete(msg.userId);
        this.sendTo(pending.ws, { t: "approval.result", approved: true });
        const pendingMeta = this.metaFor(pending.ws);
        if (pendingMeta) await this.admitParticipant(pending.ws, pendingMeta, pending.hasBookFile, state);
        break;
      }
      case "reject.join": {
        const state = await this.loadState();
        if (!state) break;
        if (meta.userId !== state.hostUserId) { this.sendError(ws, "forbidden", "host only"); break; }
        await this.rehydratePendingFromHibernation();
        delete state.pendingJoiners[msg.userId];
        await this.saveState(state);
        const pending = this.pendingSockets.get(msg.userId);
        if (pending) {
          this.pendingSockets.delete(msg.userId);
          this.sendTo(pending.ws, { t: "approval.result", approved: false, reason: "rejected by host" });
          pending.ws.close(1000, "rejected");
        }
        break;
      }
      case "sync.frame": {
        // Server-side fallback for the per-peer `sync` data channel. The worker
        // relays an opaque `frame` payload (a SyncMsg, validated by the client)
        // to every other participant. The per-socket RateBucket above already
        // throttled the frame to `framesPerSocketPerSec`.
        const state = await this.loadState();
        if (!state) break;
        // Only the current sharer may broadcast position-style frames. This
        // mirrors the production p2p path where only the sharer's `sync`
        // channel is the source of truth.
        if (meta.userId !== state.sharerUserId) break;
        const relay = { t: "sync.frame", from: meta.userId, frame: msg.frame } as const;
        for (const other of this.sockets()) {
          if (other === ws) continue;
          this.sendTo(other, relay);
        }
        break;
      }
      case "data.channel.relay": {
        // TEST-ONLY: the production data path for sync/files chunks is the
        // per-peer RTCDataChannel; this WS relay lets the E2E fake adapter
        // shuttle payloads across Electron processes.
        //
        // SECURITY/PROD-HYGIENE: gate on the same `TEST_AUTH_ALLOWED` flag
        // as the test-bearer shortcut so misbehaving production clients
        // cannot use this path to (a) bypass RTCDataChannel chunk-sync
        // entirely or (b) saturate the per-user RateBucket that legitimate
        // `sync.frame` traffic shares. The flag is unset in production
        // wrangler.jsonc.
        if (!isDataChannelRelayAllowed(this.env.TEST_AUTH_ALLOWED)) {
          this.sendError(ws, "forbidden", "data.channel.relay is test-only");
          break;
        }
        const target = this.findSocketByUserId(msg.to);
        if (!target) {
          this.sendError(ws, "no_such_peer", `peer ${msg.to} not connected`);
          break;
        }
        this.sendTo(target, {
          t: "data.channel.relay",
          from: meta.userId,
          channel: msg.channel,
          payload: msg.payload,
        });
        break;
      }
      // Other handlers added in later tasks.
      default: this.sendError(ws, "unknown", `no handler for ${(msg as any).t}`);
    }
  }

  async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const apple = await this.runAppleRoomEffect("websocket.close.route", this.appleStateEffect(), this.appleCorrelationFor(ws), "websocket.room");
    if (apple || this.isAppleSocket(ws)) {
      if (!apple) return;
      await this.runAppleRoomEffect("websocket.close", this.handleAppleCloseEffect(ws, code), this.appleCorrelationFor(ws), "websocket.room");
      return;
    }
    const meta = this.metaFor(ws);
    if (!meta) return;
    const state = await this.loadState();
    const self = state?.participants[meta.userId];
    if (!state || !self) return;
    // Explicit `leave` (code 1000 from our own close call) already removed the participant.
    if (code === 1000 && !state.participants[meta.userId]) return;
    if (meta.userId === state.hostUserId) {
      state.status = "host-suspended";
      state.hostSuspendedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
      await this.saveState(state);
      for (const s of this.sockets()) if (s !== ws) this.sendTo(s, {
        t: "host.suspended", until: state.hostSuspendedUntil,
      });
      await this.scheduleNextAlarm();
      return;
    }
    const reservedUntil = Date.now() + CONFIG.VIEWER_SLOT_GRACE_MS;
    self.connectionState = "reconnecting";
    self.reservedUntil = reservedUntil;
    await this.saveState(state);
    for (const s of this.sockets()) this.sendTo(s, {
      t: "peer.updated", userId: meta.userId, patch: { connectionState: "reconnecting" },
    });
    await this.scheduleNextAlarm();
  }

  async alarm(): Promise<void> {
    const apple = await this.runAppleRoomEffect("apple.room.alarm.lookup", this.appleStateEffect(), undefined, "websocket.room");
    if (apple) {
      await this.runAppleRoomEffect("apple.room.alarm", this.appleAlarmEffect(apple), undefined, "websocket.room");
      return;
    }
    const state = await this.loadState();
    if (!state) return;
    // Post-end purge: drop the session state once status is ended.
    if (state.status === "ended") {
      await this.ctx.storage.delete(KEY);
      await this.ctx.storage.deleteAlarm();
      return;
    }
    const now = Date.now();
    // Host-grace expiry: end the session.
    if (state.status === "host-suspended" && state.hostSuspendedUntil && state.hostSuspendedUntil <= now) {
      state.status = "ended";
      await this.saveState(state);
      for (const s of this.sockets()) {
        this.sendTo(s, { t: "session.ended", reason: "host_grace_expired" });
        s.close(1000, "ended");
      }
      this.log("session.ended", { sessionId: state.sessionId, reason: "host_grace_expired" });
      await this.ctx.storage.setAlarm(Date.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS);
      return;
    }
    // Approval timeouts — also need a rehydrated pendingSockets map to
    // notify joiners whose DO was hibernated mid-wait.
    if (Object.keys(state.pendingJoiners).length > 0) {
      await this.rehydratePendingFromHibernation();
    }
    for (const [userId, v] of Object.entries(state.pendingJoiners)) {
      if (v.requestedAt + CONFIG.APPROVAL_TIMEOUT_MS <= now) {
        delete state.pendingJoiners[userId];
        const pending = this.pendingSockets.get(userId);
        if (pending) {
          this.pendingSockets.delete(userId);
          this.sendTo(pending.ws, { t: "approval.result", approved: false, reason: "approval timeout" });
          pending.ws.close(1000, "timeout");
        }
      }
    }
    // Reconnect-slot reservation expiry: evict viewers whose reserved window passed.
    let sharerChanged = false;
    for (const [userId, p] of Object.entries(state.participants)) {
      if (p.reservedUntil && p.reservedUntil <= now) {
        delete state.participants[userId];
        if (state.sharerUserId === userId && userId !== state.hostUserId) {
          state.sharerUserId = state.hostUserId;
          sharerChanged = true;
        }
        const left = { t: "peer.left", userId, reason: "dropped" } as const;
        for (const ws of this.sockets()) {
          const m = this.metaFor(ws);
          if (m?.userId !== userId) this.sendTo(ws, left);
        }
      }
    }
    if (sharerChanged) {
      for (const ws of this.sockets()) this.sendTo(ws, { t: "role.transferred", newSharerId: state.sharerUserId });
    }
    // Future alarm branches (host grace) added in later tasks.
    await this.saveState(state);
    await this.scheduleNextAlarm();
  }

  private appleAlarmEffect(apple: AppleStoredState) {
    const self = this;
    return Effect.gen(function* () {
      const runtime = yield* AppleRoomRuntime;
      const now = runtime.now();
      if ((yield* self.expireAppleReservationsEffect(apple, now)) || (yield* self.expireAdmissionLeasesEffect(apple, now))) return;
      for (const [ticketId, exp] of Object.entries(apple.consumedAdmissionTicketIds)) if (exp <= now) delete apple.consumedAdmissionTicketIds[ticketId];
      if (apple.status !== "ended" && !apple.hasEverBeenOccupied && now >= apple.startupExpiresAt) {
        yield* self.endAppleRoomEffect(apple, "room_expired");
        return;
      }
      if (apple.status !== "ended" && apple.hasEverBeenOccupied && self.connectedCount(apple) === 0 && apple.lastEmptyAt && now - apple.lastEmptyAt >= CONFIG.APPLE_EMPTY_ROOM_MS) {
        yield* self.endAppleRoomEffect(apple, "room_expired");
        return;
      }
      if (apple.status === "ended") {
        const storage = yield* AppleRoomStorage;
        yield* storage.delete(APPLE_KEY);
        yield* storage.deleteAlarm();
        return;
      }
      yield* Effect.sync(() => self.broadcastAppleRoster(apple));
      yield* self.saveAppleStateEffect(apple);
      yield* self.scheduleAppleAlarmEffect(apple);
    });
  }

  private handleAppleMessageEffect(ws: WebSocket, raw: string | ArrayBuffer) {
    const self = this;
    return Effect.gen(function* () {
      const bytes = typeof raw === "string" ? new TextEncoder().encode(raw) : new Uint8Array(raw);
      if (bytes.byteLength > 64 * 1024) { yield* Effect.sync(() => ws.close(1009, "frame too large")); return; }
      let msg: any;
      try { msg = JSON.parse(new TextDecoder().decode(bytes)); } catch { yield* Effect.sync(() => self.sendError(ws, "bad_json", "could not parse")); return; }
      if (!msg || msg.v !== 1 || typeof msg.t !== "string") { yield* Effect.sync(() => self.sendError(ws, "bad_msg", "unsupported Apple signaling version")); return; }
      const meta = self.metaFor(ws);
      const socketGeneration = self.appleSocketGeneration(ws);
      if (!meta) return;
      if (!self.appleByteBucketFor(meta.userId).tryConsume(bytes.byteLength)) { yield* Effect.sync(() => self.sendError(ws, "rate_limited", "signaling bandwidth exceeded")); return; }
      if (!self.bucketFor(meta.userId).tryConsume()) { yield* Effect.sync(() => self.sendError(ws, "rate_limited", "too many messages")); return; }
      const state = yield* self.appleStateEffect();
      if (!state) return;
      if (state.status === "ended") { yield* Effect.sync(() => self.sendError(ws, "session_ended", "session is over")); return; }
      const participant = state.participants[meta.userId];
      if (!participant || participant.connectionState !== "connected") { yield* Effect.sync(() => self.sendError(ws, "not_admitted", "not admitted")); return; }
      if (socketGeneration !== participant.connectionGeneration) { yield* Effect.sync(() => self.sendError(ws, "stale_connection_generation", "connection is no longer current")); return; }
      const runtime = yield* AppleRoomRuntime;
      const failMessage = (code: string, message: string) => Effect.sync(() => self.sendError(ws, code, message));

      if (msg.t === "session.start" || msg.t === "session.end") {
        const expectedGeneration = Number(msg.controllerGeneration);
        if (!appleFenceMatches(state, participant.connectionGeneration, msg) || state.controllerUserId !== meta.userId) return yield* failMessage("stale_controller_generation", "controller state is stale");
        const control = msg.t === "session.start"
          ? self.startRoomEffect({ actingUserId: meta.userId, expectedControllerGeneration: expectedGeneration })
          : self.endRoomEffect({ actingUserId: meta.userId, expectedControllerGeneration: expectedGeneration });
        const result = yield* control.pipe(Effect.either);
        if (result._tag === "Left") {
          if (!(result.left instanceof AppleRoomError)) yield* self.reportAppleHandledFailure(result.left, `websocket.${msg.t}`, self.appleCorrelationFor(ws), "websocket.room");
          yield* failMessage(result.left instanceof AppleRoomError ? result.left.code.toLowerCase() : "service_unavailable", result.left instanceof Error ? result.left.message : "session control failed");
        }
        return;
      }
      if (msg.t === "leave") {
        if (!appleFenceMatches(state, participant.connectionGeneration, msg)) return yield* failMessage("stale_controller_generation", "controller state is stale");
        yield* self.leaveRoomEffect({ actingUserId: meta.userId, deliberate: true });
        return;
      }
      if (msg.t === "speaker.request") {
        if (!appleFenceMatches(state, participant.connectionGeneration, msg)) return yield* failMessage("stale_controller_generation", "controller state is stale");
        if (state.status !== "active") return yield* failMessage("not_active", "speaker floor is available when reading");
        if (state.speakerFloor?.userId === meta.userId && runtime.now() - state.speakerFloor.grantedAt < CONFIG.RATE_LIMITS.speakerRequestCooldownMs) return;
        if (state.speakerFloor && state.speakerFloor.userId !== meta.userId) return yield* failMessage("speaker_busy", "another participant has the floor");
        const requestId = typeof msg.requestId === "string" && msg.requestId.length <= 128 ? msg.requestId : null;
        if (!requestId) return yield* failMessage("bad_msg", "requestId required");
        state.speakerFloor = { userId: meta.userId, requestId, grantedAt: runtime.now() };
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.broadcastApple({ t: "speaker.granted", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, requestId, speakerUserId: meta.userId }));
        return;
      }
      if (msg.t === "speaker.release") {
        if (!appleFenceMatches(state, participant.connectionGeneration, msg)) return yield* failMessage("stale_controller_generation", "controller state is stale");
        if (state.speakerFloor?.userId !== meta.userId) return;
        state.speakerFloor = null;
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, speakerUserId: meta.userId }));
        return;
      }
      if (msg.t === "sync.frame") {
        if (meta.userId !== state.controllerUserId) return yield* failMessage("forbidden", "only the controller can publish shared progress");
        if (!appleRoomFenceMatches(state, msg.frame)) return yield* failMessage("stale_controller_generation", "controller state is stale");
        const parsedSnapshot = ControllerSnapshot.safeParse(msg.frame);
        if (!parsedSnapshot.success) return yield* failMessage("bad_msg", "invalid controller snapshot");
        const frame = parsedSnapshot.data;
        if (!isSnapshotForBook(frame, state.bookContext.bookId, state.bookContext.contentHash)) return yield* failMessage("bad_msg", "snapshot book does not match room");
        const controllerSequence = frame.sequence;
        const current = state.latestSyncSnapshot;
        if (current && (state.roomEpoch !== current.roomEpoch || state.controllerGeneration !== current.controllerGeneration || controllerSequence <= current.sequence)) return;
        state.latestSyncSnapshot = { sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, controllerUserId: meta.userId, sequence: controllerSequence, frame };
        self.recordObservation(state, "sync", participant.connectionGeneration, { readerSequence: controllerSequence }, runtime.now(), runtime.randomUUID);
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.broadcastApple({ t: "sync.frame", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, from: meta.userId, frame }));
        return;
      }
      if (msg.t === "sdp.offer" || msg.t === "sdp.answer") {
        if (!self.isBoundedUserId(msg.to) || !self.isBoundedString(msg.sdp, 20_000)) return yield* failMessage("bad_msg", "invalid SDP relay");
        const targetParticipant = state.participants[msg.to];
        const target = targetParticipant?.connectionState === "connected" ? self.findAppleSocketByUserId(msg.to, targetParticipant.connectionGeneration) : null;
        if (!target || !targetParticipant || targetParticipant.connectionState !== "connected") return yield* failMessage("no_such_peer", `peer ${msg.to} not connected`);
        state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
        if (state.sdpRelayCount > CONFIG.RATE_LIMITS.appleSdpRelaysPerSession) return yield* failMessage("rate_limited", "signaling relay budget exhausted");
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.sendTo(target, { t: msg.t, v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, from: meta.userId, sdp: msg.sdp }));
        return;
      }
      if (msg.t === "ice") {
        const candidate = msg.candidate;
        if (!self.isBoundedUserId(msg.to) || !candidate || typeof candidate !== "object"
          || !self.isBoundedString(candidate.candidate, 4 * 1024)
          || (candidate.sdpMid !== undefined && candidate.sdpMid !== null && !self.isBoundedString(candidate.sdpMid, 4 * 1024))
          || (candidate.sdpMLineIndex !== undefined && candidate.sdpMLineIndex !== null && (!Number.isInteger(candidate.sdpMLineIndex) || candidate.sdpMLineIndex < 0 || candidate.sdpMLineIndex > 65535))) return yield* failMessage("bad_msg", "invalid ICE candidate");
        const targetParticipant = state.participants[msg.to];
        const target = targetParticipant?.connectionState === "connected" ? self.findAppleSocketByUserId(msg.to, targetParticipant.connectionGeneration) : null;
        if (!target || !targetParticipant || targetParticipant.connectionState !== "connected") return yield* failMessage("no_such_peer", `peer ${msg.to} not connected`);
        state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
        if (state.sdpRelayCount > CONFIG.RATE_LIMITS.appleSdpRelaysPerSession) return yield* failMessage("rate_limited", "signaling relay budget exhausted");
        yield* self.saveAppleStateEffect(state);
        yield* Effect.sync(() => self.sendTo(target, { t: "ice", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, from: meta.userId, candidate: { candidate: candidate.candidate, sdpMid: candidate.sdpMid ?? null, sdpMLineIndex: candidate.sdpMLineIndex ?? null } }));
        return;
      }
      yield* failMessage("unknown", `no handler for ${String(msg.t ?? "message")}`);
    });
  }

  private isBoundedString(value: unknown, maxBytes: number): value is string {
    return typeof value === "string" && new TextEncoder().encode(value).byteLength <= maxBytes;
  }

  private isBoundedUserId(value: unknown): value is string {
    return this.isBoundedString(value, 64) && value.length > 0;
  }

  private appleSocketGeneration(ws: WebSocket): number {
    const tag = this.ctx.getTags(ws)[0];
    try {
      const parsed = JSON.parse(tag ?? "{}");
      return Number.isSafeInteger(parsed.connectionGeneration) ? parsed.connectionGeneration : -1;
    } catch {
      return -1;
    }
  }

  private appleCorrelationFor(ws: WebSocket): string {
    const tag = this.ctx.getTags(ws)[0];
    try {
      const correlationId = JSON.parse(tag ?? "{}").correlationId;
      if (typeof correlationId === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(correlationId)) return correlationId;
    } catch { /* Ignore malformed hibernated tags. */ }
    return crypto.randomUUID();
  }

  private isAppleSocket(ws: WebSocket): boolean {
    const tag = this.ctx.getTags(ws)[0];
    try { return JSON.parse(tag ?? "{}").apple === true; } catch { return false; }
  }

  private handleAppleCloseEffect(ws: WebSocket, code: number) {
    const self = this;
    return Effect.gen(function* () {
      if (self.supersededAppleSockets.has(ws)) return;
      const meta = self.metaFor(ws);
      const state = yield* self.appleStateEffect();
      if (!meta || !state) return;
      const tagGeneration = self.appleSocketGeneration(ws);
      const participant = state.participants[meta.userId];
      if (!participant || participant.connectionGeneration !== tagGeneration) return;
      const runtime = yield* AppleRoomRuntime;
      const releasedFloor = state.speakerFloor?.userId === meta.userId ? state.speakerFloor : null;
      if (releasedFloor) state.speakerFloor = null;
      let controllerChanged = false;
      if (code === 1000) {
        delete state.participants[meta.userId];
        delete state.seatReservations[meta.userId];
        self.removeAppleAdmissionLeases(state, meta.userId);
        controllerChanged = state.controllerUserId === meta.userId;
        if (controllerChanged) self.chooseAppleController(state, false);
      } else {
        participant.connectionState = "reconnecting";
        participant.reservedUntil = runtime.now() + CONFIG.APPLE_CONTROLLER_RECLAIM_MS;
        state.seatReservations[meta.userId] = { reservedUntil: participant.reservedUntil, connectionGeneration: participant.connectionGeneration };
        if (state.controllerUserId === meta.userId) {
          self.chooseAppleController(state, true);
          controllerChanged = true;
        }
      }
      state.rosterGeneration += 1;
      if (!Object.values(state.participants).some((value) => value.connectionState === "connected")) state.lastEmptyAt = runtime.now();
      yield* self.saveAppleStateEffect(state);
      yield* Effect.sync(() => {
        if (releasedFloor) self.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: releasedFloor.userId });
        if (controllerChanged) self.broadcastControllerChange(state);
        self.broadcastAppleRoster(state);
      });
      yield* self.scheduleAppleAlarmEffect(state);
    });
  }

  // ---------- Hello ----------
  private async handleHello(ws: WebSocket, meta: AttachedMeta, hasBookFile: boolean) {
    const state = await this.loadState();
    if (!state) { this.sendError(ws, "no_session", "session not found"); ws.close(1011, "no session"); return; }
    if (state.status === "ended") { this.sendError(ws, "session_ended", "session is over"); ws.close(1000, "ended"); return; }

    // Reconnect path: existing participant + reconnect-flag → resume in their reserved slot.
    const existing = state.participants[meta.userId];
    const tagJson = this.ctx.getTags(ws)[0];
    const isReconnect = tagJson ? !!JSON.parse(tagJson).isReconnect : false;
    if (existing && isReconnect) {
      existing.connectionState = "connected";
      existing.hasBookFile = hasBookFile;
      delete existing.reservedUntil;
      // Host reconnect resumes the session (sharer role stays where it was).
      if (meta.userId === state.hostUserId && state.status === "host-suspended") {
        state.status = "live";
        state.hostSuspendedUntil = undefined;
        for (const s of this.sockets()) if (s !== ws) this.sendTo(s, { t: "host.resumed" });
      }
      await this.saveState(state);
      const newReservedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
      const newRt = await issueReconnectToken(
        { sessionId: state.sessionId, userId: meta.userId, reservedUntil: newReservedUntil },
        this.env.WORKER_HMAC_SECRET,
      );
      const role: "host" | "viewer" = meta.userId === state.hostUserId ? "host" : "viewer";
      this.sendTo(ws, {
        t: "welcome", you: meta.userId, role,
        sharerId: state.sharerUserId, reconnectToken: newRt, reservedUntil: newReservedUntil,
      });
      for (const s of this.sockets()) if (s !== ws) this.sendTo(s, {
        t: "peer.updated", userId: meta.userId, patch: { connectionState: "connected", hasBookFile },
      });
      await this.broadcastRoster(state);
      return;
    }

    if (Object.keys(state.participants).length >= CONFIG.MAX_PARTICIPANTS && !state.participants[meta.userId]) {
      this.sendError(ws, "cap_reached", "session is full"); ws.close(1000, "full"); return;
    }
    if (state.status === "host-suspended" && meta.userId !== state.hostUserId) {
      this.sendError(ws, "host_suspended", "host disconnected"); ws.close(1000, "host suspended"); return;
    }

    // Approval gate: non-host joiners that aren't already participants get queued.
    if (state.requiresApproval && meta.userId !== state.hostUserId && !state.participants[meta.userId]) {
      const pending = {
        profile: { displayName: meta.displayName, avatarUrl: meta.avatarUrl },
        requestedAt: Date.now(),
        // Persist hasBookFile so we can rehydrate `pendingSockets` after
        // WebSocket hibernation. The in-memory map is destroyed on wake; the
        // storage record + getWebSockets() are the durable inputs.
        hasBookFile,
      };
      state.pendingJoiners[meta.userId] = pending;
      await this.saveState(state);
      this.pendingSockets.set(meta.userId, { ws, hasBookFile });
      this._pendingHydrated = true;
      const hostWs = this.findSocketByUserId(state.hostUserId);
      if (hostWs) this.sendTo(hostWs, {
        t: "join.requested",
        userId: meta.userId,
        profile: pending.profile,
      });
      this.log("peer.queued", { sessionId: state.sessionId, userId: meta.userId });
      await this.scheduleNextAlarm();
      return;
    }

    await this.admitParticipant(ws, meta, hasBookFile, state);
  }

  private async admitParticipant(ws: WebSocket, meta: AttachedMeta, hasBookFile: boolean, state: StoredState) {
    const reservedUntil = Date.now() + CONFIG.HOST_GRACE_MS;
    const profile = { displayName: meta.displayName, avatarUrl: meta.avatarUrl };
    state.participants[meta.userId] = {
      userId: meta.userId,
      profile,
      joinedAt: Date.now(),
      hasBookFile,
      micState: "unmuted",
      connectionState: "connected",
    };
    await this.saveState(state);

    const reconnectToken = await issueReconnectToken(
      { sessionId: state.sessionId, userId: meta.userId, reservedUntil },
      this.env.WORKER_HMAC_SECRET,
    );
    const role: "host" | "viewer" = meta.userId === state.hostUserId ? "host" : "viewer";
    this.sendTo(ws, {
      t: "welcome",
      you: meta.userId,
      role,
      sharerId: state.sharerUserId,
      reconnectToken,
      reservedUntil,
    });

    // Broadcast peer.joined to others (skip self).
    for (const otherWs of this.sockets()) {
      if (otherWs === ws) continue;
      this.sendTo(otherWs, {
        t: "peer.joined",
        userId: meta.userId,
        profile,
        hasBookFile,
      });
    }

    await this.broadcastRoster(state);
    this.log("peer.admitted", { sessionId: state.sessionId, userId: meta.userId, role });
  }

  /**
   * Rehydrate `pendingSockets` from `getWebSockets()` + persisted
   * `pendingJoiners`. Idempotent within a single DO lifetime — the
   * `_pendingHydrated` flag is reset by the runtime each time a fresh
   * instance is created (so the in-memory map starts empty and rehydration
   * runs exactly once per wake).
   *
   * Without this, after a hibernation cycle:
   *   - `state.pendingJoiners[userId]` is still set (storage persists)
   *   - `this.pendingSockets.get(userId)` returns undefined (in-memory map reset)
   *   - `approve.join`/`reject.join` silently drops the joiner without sending
   *     the approval.result message they're blocked on.
   */
  private async rehydratePendingFromHibernation(): Promise<void> {
    if (this._pendingHydrated) return;
    this._pendingHydrated = true;
    const state = await this.loadState();
    if (!state) return;
    if (Object.keys(state.pendingJoiners).length === 0) return;
    for (const ws of this.ctx.getWebSockets()) {
      const meta = this.metaFor(ws);
      if (!meta) continue;
      const pending = state.pendingJoiners[meta.userId];
      if (!pending) continue;
      // hasBookFile was persisted at the time of `peer.queued`; default to
      // false for legacy records that predate this field.
      this.pendingSockets.set(meta.userId, { ws, hasBookFile: pending.hasBookFile ?? false });
    }
  }

  // ---------- Helpers ----------
  private metaFor(ws: WebSocket): AttachedMeta | null {
    const tags = this.ctx.getTags(ws);
    if (!tags[0]) return null;
    try { return JSON.parse(tags[0]).meta as AttachedMeta; } catch { return null; }
  }
  private sockets(): WebSocket[] { return this.ctx.getWebSockets(); }
  private sendTo(ws: WebSocket, msg: Record<string, unknown>) {
    // A close requested during a membership mutation can be observed before
    // `getWebSockets()` drops that socket. Broadcasts are best-effort for that
    // already-terminal connection; persistence has happened before this point.
    try { ws.send(JSON.stringify({ v: 1, ...msg })); } catch { /* socket closed */ }
  }
  private sendError(ws: WebSocket, code: string, message: string) {
    this.sendTo(ws, { t: "error", code, message });
  }
  private findSocketByUserId(userId: string): WebSocket | null {
    for (const ws of this.sockets()) {
      const m = this.metaFor(ws);
      if (m?.userId === userId) return ws;
    }
    return null;
  }
  private findAppleSocketByUserId(userId: string, connectionGeneration: number): WebSocket | null {
    for (const ws of this.sockets()) {
      const m = this.metaFor(ws);
      if (m?.userId === userId && this.appleSocketGeneration(ws) === connectionGeneration) return ws;
    }
    return null;
  }
  private async loadState() {
    return (await this.ctx.storage.get<StoredState>(KEY)) ?? null;
  }
  private async saveState(s: StoredState) { await this.ctx.storage.put(KEY, s); }
  private async broadcastRoster(state: StoredState) {
    const msg = {
      t: "roster",
      participants: Object.values(state.participants),
      pendingJoiners: Object.entries(state.pendingJoiners).map(([userId, v]) => ({ userId, ...v })),
      requiresApproval: state.requiresApproval,
      bookContext: state.bookContext,
      status: state.status,
      hostSuspendedUntil: state.hostSuspendedUntil,
    };
    for (const ws of this.sockets()) this.sendTo(ws, msg);
  }
  private async removeParticipant(userId: string, reason: "left" | "kicked" | "dropped") {
    const state = await this.loadState();
    if (!state) return;
    if (!state.participants[userId]) return;
    delete state.participants[userId];
    let sharerChanged = false;
    if (state.sharerUserId === userId && userId !== state.hostUserId) {
      state.sharerUserId = state.hostUserId;
      sharerChanged = true;
    }
    await this.saveState(state);
    const left = { t: "peer.left", userId, reason };
    for (const ws of this.sockets()) {
      const m = this.metaFor(ws);
      if (m?.userId !== userId) this.sendTo(ws, left);
    }
    if (sharerChanged) {
      for (const ws of this.sockets()) this.sendTo(ws, { t: "role.transferred", newSharerId: state.sharerUserId });
    }
  }

  private async scheduleNextAlarm() {
    const state = await this.loadState();
    if (!state) return;
    const candidates: number[] = [];
    const now = Date.now();
    for (const v of Object.values(state.pendingJoiners)) candidates.push(v.requestedAt + CONFIG.APPROVAL_TIMEOUT_MS);
    for (const p of Object.values(state.participants)) {
      if (p.reservedUntil) candidates.push(p.reservedUntil);
    }
    if (state.hostSuspendedUntil) candidates.push(state.hostSuspendedUntil);
    if (candidates.length === 0) { await this.ctx.storage.deleteAlarm(); return; }
    const next = Math.max(now + 100, Math.min(...candidates));
    await this.ctx.storage.setAlarm(next);
  }
}
