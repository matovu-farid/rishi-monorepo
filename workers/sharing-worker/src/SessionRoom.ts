import { DurableObject } from "cloudflare:workers";
import { ClientMsg, parseSyncFrame } from "./schemas";
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
import { resolveTestGlobalAuth } from "./auth";
import { generateTurnIceServers } from "./turn";
import { appleFenceMatches, appleRoomFenceMatches, buildAppleRosterMessage } from "./appleTopology";

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
  /** Bounded per-room budget for SDP/ICE metadata relays. */
  sdpRelayCount?: number;
};

class AppleRoomError extends Error {
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

export class SessionRoom extends DurableObject<Env> {
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
  async createRoom(input: {
    sessionId: string;
    initialSharerUserId: string;
    bookContext: BookContextT;
    maxParticipants?: number;
  }): Promise<{ sessionId: string; roomEpoch: number; controllerGeneration: number }> {
    if (await this.ctx.storage.get(KEY) || await this.ctx.storage.get(APPLE_KEY)) {
      throw new AppleRoomError("ALREADY_INITIALIZED");
    }
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
      status: "waiting",
      maxParticipants: Math.max(1, Math.min(input.maxParticipants ?? CONFIG.MAX_PARTICIPANTS, CONFIG.MAX_PARTICIPANTS)),
      createdAt: Date.now(),
      lastEmptyAt: Date.now(),
      participants: {},
      seatReservations: {},
      removedUserIds: [],
      speakerFloor: null,
      consumedAdmissionTicketIds: {},
      sdpRelayCount: 0,
    };
    await this.ctx.storage.put(APPLE_KEY, state);
    await this.ctx.storage.setAlarm(Date.now() + CONFIG.APPLE_EMPTY_ROOM_MS);
    this.log("apple.session.created", { sessionId: state.sessionId });
    return { sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration };
  }

  async getRoomStatus() {
    const state = await this.appleState();
    if (!state) return null;
    return {
      sessionId: state.sessionId,
      status: state.status,
      roomEpoch: state.roomEpoch,
      controllerGeneration: state.controllerGeneration,
      controllerUserId: state.controllerUserId,
      participants: Object.values(state.participants).map(({ userId, profile, joinedAt, bookReady, connectionState }) => ({
        userId, profile, joinedAt, bookReady, connectionState,
      })),
      maxParticipants: state.maxParticipants,
      removedUserIds: [...state.removedUserIds],
    };
  }

  async getAppleRedeemInfo() {
    const state = await this.appleState();
    if (!state) return null;
    return { sessionId: state.sessionId, bookContext: state.bookContext, status: state.status, roomEpoch: state.roomEpoch };
  }

  async getTurnCredentials(input: { userId: string; ttlSeconds?: number }) {
    const state = await this.requireAppleState();
    if (state.status === "ended" || !state.participants[input.userId]) throw new AppleRoomError("FORBIDDEN");
    return { iceServers: await generateTurnIceServers(this.env, input.ttlSeconds) };
  }

  async markBookReadyAndIssueAdmissionTicket(input: {
    sessionId: string;
    inviteId: string;
    userId: string;
    contentHash: string;
    profile?: { displayName: string; avatarUrl?: string };
  }) {
    const state = await this.requireAppleState(input.sessionId);
    if (state.status === "ended") throw new AppleRoomError("SESSION_ENDED");
    if (state.bookContext.contentHash !== input.contentHash) throw new AppleRoomError("BOOK_HASH_MISMATCH");
    if (state.removedUserIds.includes(input.userId)) throw new AppleRoomError("REMOVED_FROM_SESSION");
    const existing = state.participants[input.userId];
    const now = Date.now();
    this.expireAppleReservations(state, now);
    const occupied = this.appleOccupiedSeats(state);
    if (!existing && occupied >= state.maxParticipants) throw new AppleRoomError("ROOM_FULL");
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
    state.lastEmptyAt = undefined;
    const ticketId = crypto.randomUUID();
    const ticket = await issueAdmissionTicket({
      sessionId: state.sessionId,
      inviteId: input.inviteId,
      userId: input.userId,
      ticketId,
      roomEpoch: state.roomEpoch,
      connectionGeneration: generation,
      ttlMs: CONFIG.ADMISSION_TICKET_TTL_MS,
    }, this.env.WORKER_HMAC_SECRET);
    participant.connectionState = "reconnecting";
    await this.saveAppleState(state);
    return { admissionTicket: ticket.token, claims: ticket.claims, roomEpoch: state.roomEpoch, status: state.status };
  }

  async startRoom(input: { actingUserId: string; expectedControllerGeneration: number }) {
    const state = await this.requireAppleState();
    this.assertController(state, input.actingUserId, input.expectedControllerGeneration);
    if (state.status === "ended") throw new AppleRoomError("SESSION_ENDED");
    if (state.status === "active") return this.appleStatus(state);
    state.status = "active";
    state.roomEpoch += 1;
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.broadcastApple({ t: "session.state", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, status: state.status, controllerUserId: state.controllerUserId });
    this.broadcastAppleRoster(state);
    return this.appleStatus(state);
  }

  async leaveRoom(input: { actingUserId: string; deliberate?: boolean }) {
    const state = await this.requireAppleState();
    const p = state.participants[input.actingUserId];
    if (!p) return this.appleStatus(state);
    delete state.participants[input.actingUserId];
    delete state.seatReservations[input.actingUserId];
    const controllerChanged = state.controllerUserId === input.actingUserId;
    if (state.speakerFloor?.userId === input.actingUserId) {
      const floor = state.speakerFloor;
      state.speakerFloor = null;
      this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
    }
    if (controllerChanged) this.chooseAppleController(state, false);
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.closeAppleSockets(input.actingUserId, "left");
    if (controllerChanged) this.broadcastControllerChange(state);
    this.broadcastAppleRoster(state);
    await this.scheduleAppleAlarm(state);
    return this.appleStatus(state);
  }

  async transferController(input: { actingUserId: string; targetUserId: string; expectedControllerGeneration: number }) {
    const state = await this.requireAppleState();
    this.assertController(state, input.actingUserId, input.expectedControllerGeneration);
    const target = state.participants[input.targetUserId];
    if (!target || target.connectionState !== "connected") throw new AppleRoomError("NO_SUCH_PARTICIPANT");
    state.controllerUserId = input.targetUserId;
    state.controllerGeneration += 1;
    state.roomEpoch += 1;
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.broadcastApple({ t: "controller.transfer", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, toUserId: input.targetUserId });
    this.broadcastAppleRoster(state);
    return this.appleStatus(state);
  }

  async endRoom(input: { actingUserId: string; expectedControllerGeneration: number }) {
    const state = await this.requireAppleState();
    this.assertController(state, input.actingUserId, input.expectedControllerGeneration);
    return this.endAppleRoom(state, "controller_ended");
  }

  async removeAppleParticipant(input: { actingUserId: string; userId: string; expectedControllerGeneration: number }) {
    const state = await this.requireAppleState();
    this.assertController(state, input.actingUserId, input.expectedControllerGeneration);
    if (input.userId === input.actingUserId) throw new AppleRoomError("FORBIDDEN");
    if (!state.participants[input.userId]) throw new AppleRoomError("NO_SUCH_PARTICIPANT");
    delete state.participants[input.userId];
    delete state.seatReservations[input.userId];
    if (state.speakerFloor?.userId === input.userId) {
      const floor = state.speakerFloor;
      state.speakerFloor = null;
      this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
    }
    if (!state.removedUserIds.includes(input.userId)) state.removedUserIds.push(input.userId);
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.closeAppleSockets(input.userId, "removed");
    this.broadcastApple({ t: "participant.remove", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, userId: input.userId, reason: "removed" });
    this.broadcastAppleRoster(state);
    return this.appleStatus(state);
  }

  async restoreAppleParticipant(input: { actingUserId: string; userId: string; inviteId: string; contentHash: string; expectedControllerGeneration: number; profile?: { displayName: string; avatarUrl?: string } }) {
    const state = await this.requireAppleState();
    this.assertController(state, input.actingUserId, input.expectedControllerGeneration);
    if (!state.removedUserIds.includes(input.userId)) throw new AppleRoomError("NO_SUCH_PARTICIPANT");
    if (state.bookContext.contentHash !== input.contentHash) throw new AppleRoomError("BOOK_HASH_MISMATCH");
    this.expireAppleReservations(state, Date.now());
    if (this.appleOccupiedSeats(state) >= state.maxParticipants) throw new AppleRoomError("ROOM_FULL");
    state.removedUserIds = state.removedUserIds.filter((id) => id !== input.userId);
    try {
      const result = await this.markBookReadyAndIssueAdmissionTicket({ ...input, userId: input.userId, inviteId: input.inviteId, contentHash: input.contentHash, profile: input.profile });
      const latest = await this.requireAppleState();
      latest.rosterGeneration += 1;
      await this.saveAppleState(latest);
      this.broadcastAppleRoster(latest);
      return result;
    } catch (error) {
      state.removedUserIds.push(input.userId);
      await this.saveAppleState(state);
      throw error;
    }
  }

  private async appleState() {
    const state = await this.ctx.storage.get<AppleStoredState>(APPLE_KEY);
    if (state && !Number.isSafeInteger(state.rosterGeneration)) state.rosterGeneration = 0;
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
  private expireAppleReservations(state: AppleStoredState, now: number) {
    for (const [userId, reservation] of Object.entries(state.seatReservations)) {
      if (reservation.reservedUntil > now) continue;
      delete state.seatReservations[userId];
      const participant = state.participants[userId];
      if (participant?.connectionState === "reconnecting" && participant.connectionGeneration === reservation.connectionGeneration) {
        delete state.participants[userId];
        state.rosterGeneration += 1;
        const controllerChanged = state.controllerUserId === userId;
        if (state.speakerFloor?.userId === userId) {
          const floor = state.speakerFloor;
          state.speakerFloor = null;
          this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
        }
        if (controllerChanged) this.chooseAppleController(state, false);
        if (controllerChanged) this.broadcastControllerChange(state);
        this.broadcastAppleRoster(state);
      }
    }
    if (state.controllerReturnUntil && state.controllerReturnUntil <= now) {
      state.controllerReturnUntil = undefined;
      state.controllerReturnUserId = undefined;
    }
  }
  private appleOccupiedSeats(state: AppleStoredState): number {
    return new Set([...Object.keys(state.participants), ...Object.keys(state.seatReservations)]).size;
  }
  private chooseAppleController(state: AppleStoredState, unexpected: boolean) {
    if (unexpected) {
      state.controllerReturnUserId = state.initialSharerUserId;
      state.controllerReturnUntil = Date.now() + CONFIG.APPLE_CONTROLLER_RECLAIM_MS;
    }
    const next = Object.values(state.participants)
      .filter((participant) => participant.connectionState === "connected")
      .sort((a, b) => a.joinedAt - b.joinedAt)[0];
    if (!next) { state.lastEmptyAt = Date.now(); return; }
    state.controllerUserId = next.userId;
    state.controllerGeneration += 1;
    state.roomEpoch += 1;
  }
  private broadcastApple(message: Record<string, unknown>) { for (const ws of this.sockets()) this.sendTo(ws, message); }
  private broadcastAppleRoster(state: AppleStoredState) { this.broadcastApple(buildAppleRosterMessage(state)); }
  private broadcastControllerChange(state: AppleStoredState) {
    this.broadcastApple({ t: "controller.transfer", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, toUserId: state.controllerUserId });
  }
  private closeAppleSockets(userId: string, reason: string) { for (const ws of this.sockets()) if (this.metaFor(ws)?.userId === userId) ws.close(1000, reason); }
  private async endAppleRoom(state: AppleStoredState, reason: "controller_ended" | "room_expired") {
    state.status = "ended";
    state.roomEpoch += 1;
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.broadcastApple({ t: "session.ended", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, reason });
    for (const ws of this.sockets()) ws.close(1000, "ended");
    await this.ctx.storage.setAlarm(Date.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS);
    return this.appleStatus(state);
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
    if (request.headers.get("upgrade") !== "websocket") return new Response("Expected websocket", { status: 426 });
    const creds = parseSubprotocols(request.headers.get("sec-websocket-protocol"));
    if (!creds.valid) return new Response(creds.reason, { status: 400 });

    if (await this.appleState()) return this.fetchApple(request, creds);

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
        } catch (e) {
          return new Response((e as Error).message, { status: 401 });
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

  private async fetchApple(request: Request, creds: Extract<ReturnType<typeof parseSubprotocols>, { valid: true }>): Promise<Response> {
    if (!creds.admissionTicket) return new Response("admission ticket required", { status: 401 });
    let meta: AttachedMeta;
    const testMeta = resolveTestBearer(creds.jwt, this.env.TEST_AUTH_ALLOWED);
    if (testMeta) meta = testMeta;
    else {
      const testAuth = resolveTestGlobalAuth(this.env.TEST_AUTH_ALLOWED);
      if (testAuth) meta = { userId: testAuth.userId, displayName: testAuth.displayName, avatarUrl: testAuth.avatarUrl };
      else {
        try {
          const { verifyAuthToken } = await import("./auth");
          const u = await verifyAuthToken(creds.jwt, this.env);
          meta = { userId: u.userId, displayName: u.displayName, avatarUrl: u.avatarUrl };
        } catch (e) { return new Response((e as Error).message, { status: 401 }); }
      }
    }
    const state = await this.requireAppleState();
    if (state.status === "ended") return new Response("session ended", { status: 410 });
    let ticket;
    try { ticket = await verifyAdmissionTicket(`admission.${creds.admissionTicket}`, this.env.WORKER_HMAC_SECRET); }
    catch { return new Response("invalid admission ticket", { status: 401 }); }
    if (ticket.sessionId !== state.sessionId || ticket.userId !== meta.userId || ticket.roomEpoch !== state.roomEpoch) return new Response("admission ticket binding mismatch", { status: 401 });
    const p = state.participants[meta.userId];
    if (!p || !p.bookReady || p.inviteId !== ticket.inviteId || p.connectionGeneration !== ticket.connectionGeneration) return new Response("admission ticket is stale", { status: 401 });
    if (state.consumedAdmissionTicketIds[ticket.ticketId]) return new Response("admission ticket already used", { status: 401 });
    // A second device replaces the first connection for this user. The old
    // socket's close callback is harmless because its generation is stale.
    for (const oldSocket of this.sockets()) {
      if (this.metaFor(oldSocket)?.userId === meta.userId) {
        this.supersededAppleSockets.add(oldSocket);
        oldSocket.close(4000, "replaced");
      }
    }
    state.consumedAdmissionTicketIds[ticket.ticketId] = ticket.exp;
    p.connectionState = "connected";
    delete p.reservedUntil;
    delete state.seatReservations[meta.userId];
    if (meta.userId === state.controllerReturnUserId && state.controllerReturnUntil && state.controllerReturnUntil > Date.now()) {
      state.controllerUserId = meta.userId;
      state.controllerGeneration += 1;
      state.roomEpoch += 1;
      state.controllerReturnUntil = undefined;
      state.controllerReturnUserId = undefined;
    }
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server, [JSON.stringify({ meta, apple: true, connectionGeneration: ticket.connectionGeneration })]);
    this.sendTo(server, { t: "session.state", status: state.status, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: ticket.connectionGeneration, controllerUserId: state.controllerUserId });
    this.broadcastAppleRoster(state);
    return new Response(null, { status: 101, webSocket: client, headers: { "sec-websocket-protocol": "rishi.sharing.v1" } });
  }

  // ---------- Hibernation handlers ----------
  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer): Promise<void> {
    if (await this.appleState()) {
      await this.handleAppleMessage(ws, raw);
      return;
    }
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
    if (await this.appleState()) {
      await this.handleAppleClose(ws, code);
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
    const apple = await this.appleState();
    if (apple) {
      const now = Date.now();
      this.expireAppleReservations(apple, now);
      for (const [ticketId, exp] of Object.entries(apple.consumedAdmissionTicketIds)) if (exp <= now) delete apple.consumedAdmissionTicketIds[ticketId];
      if (apple.status !== "ended" && Object.keys(apple.participants).length === 0 && apple.lastEmptyAt && apple.lastEmptyAt + CONFIG.APPLE_EMPTY_ROOM_MS <= now) {
        await this.endAppleRoom(apple, "room_expired");
        return;
      }
      if (apple.status === "ended") {
        await this.ctx.storage.delete(APPLE_KEY);
        await this.ctx.storage.deleteAlarm();
        return;
      }
      this.broadcastAppleRoster(apple);
      await this.saveAppleState(apple);
      await this.scheduleAppleAlarm(apple);
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

  private async handleAppleMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const bytes = typeof raw === "string" ? new TextEncoder().encode(raw) : new Uint8Array(raw);
    if (bytes.byteLength > 64 * 1024) { ws.close(1009, "frame too large"); return; }
    let msg: any;
    try { msg = JSON.parse(new TextDecoder().decode(bytes)); } catch { this.sendError(ws, "bad_json", "could not parse"); return; }
    if (!msg || msg.v !== 1 || typeof msg.t !== "string") {
      this.sendError(ws, "bad_msg", "unsupported Apple signaling version");
      return;
    }
    const meta = this.metaFor(ws);
    const state = await this.appleState();
    if (!meta || !state) return;
    const participant = state.participants[meta.userId];
    if (!participant || participant.connectionState !== "connected") { this.sendError(ws, "not_admitted", "not admitted"); return; }
    const socketGeneration = this.appleSocketGeneration(ws);
    if (socketGeneration !== participant.connectionGeneration) {
      this.sendError(ws, "stale_connection_generation", "connection is no longer current");
      return;
    }
    if (!this.appleByteBucketFor(meta.userId).tryConsume(bytes.byteLength)) { this.sendError(ws, "rate_limited", "signaling bandwidth exceeded"); return; }
    const bucket = this.bucketFor(meta.userId);
    if (!bucket.tryConsume()) { this.sendError(ws, "rate_limited", "too many messages"); return; }
    if (msg.t === "session.start" || msg.t === "session.end") {
      const expectedGeneration = Number(msg.controllerGeneration);
      if (!appleFenceMatches(state, participant.connectionGeneration, msg)
        || state.controllerUserId !== meta.userId) {
        this.sendError(ws, "stale_controller_generation", "controller state is stale");
        return;
      }
      try {
        if (msg.t === "session.start") {
          await this.startRoom({ actingUserId: meta.userId, expectedControllerGeneration: expectedGeneration });
        } else {
          await this.endRoom({ actingUserId: meta.userId, expectedControllerGeneration: expectedGeneration });
        }
      } catch (error) {
        const code = error instanceof AppleRoomError ? error.code.toLowerCase() : "service_unavailable";
        this.sendError(ws, code, error instanceof Error ? error.message : "session control failed");
      }
      return;
    }
    if (msg.t === "leave") {
      if (!appleFenceMatches(state, participant.connectionGeneration, msg)) { this.sendError(ws, "stale_controller_generation", "controller state is stale"); return; }
      await this.leaveRoom({ actingUserId: meta.userId, deliberate: true });
      return;
    }
    if (msg.t === "speaker.request") {
      if (!appleFenceMatches(state, participant.connectionGeneration, msg)) { this.sendError(ws, "stale_controller_generation", "controller state is stale"); return; }
      if (state.status !== "active") { this.sendError(ws, "not_active", "speaker floor is available when reading"); return; }
      if (state.speakerFloor?.userId === meta.userId && Date.now() - state.speakerFloor.grantedAt < CONFIG.RATE_LIMITS.speakerRequestCooldownMs) return;
      if (state.speakerFloor && state.speakerFloor.userId !== meta.userId) { this.sendError(ws, "speaker_busy", "another participant has the floor"); return; }
      const requestId = typeof msg.requestId === "string" && msg.requestId.length <= 128 ? msg.requestId : null;
      if (!requestId) { this.sendError(ws, "bad_msg", "requestId required"); return; }
      state.speakerFloor = { userId: meta.userId, requestId, grantedAt: Date.now() };
      await this.saveAppleState(state);
      this.broadcastApple({ t: "speaker.granted", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, requestId, speakerUserId: meta.userId });
      return;
    }
    if (msg.t === "speaker.release") {
      if (!appleFenceMatches(state, participant.connectionGeneration, msg)) { this.sendError(ws, "stale_controller_generation", "controller state is stale"); return; }
      if (state.speakerFloor?.userId !== meta.userId) return;
      state.speakerFloor = null;
      await this.saveAppleState(state);
      this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, speakerUserId: meta.userId });
      return;
    }
    if (msg.t === "sync.frame") {
      if (meta.userId !== state.controllerUserId) { this.sendError(ws, "forbidden", "only the controller can publish shared progress"); return; }
      if (!appleRoomFenceMatches(state, msg.frame)) { this.sendError(ws, "stale_controller_generation", "controller state is stale"); return; }
      try { parseSyncFrame(msg.frame); }
      catch { this.sendError(ws, "bad_msg", "invalid sync frame"); return; }
      this.broadcastApple({ t: "sync.frame", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: participant.connectionGeneration, from: meta.userId, frame: msg.frame });
      return;
    }
    if (msg.t === "sdp.offer" || msg.t === "sdp.answer") {
      if (!this.isBoundedUserId(msg.to) || !this.isBoundedString(msg.sdp, 20_000)) {
        this.sendError(ws, "bad_msg", "invalid SDP relay");
        return;
      }
      const targetParticipant = state.participants[msg.to];
      const target = targetParticipant?.connectionState === "connected"
        ? this.findAppleSocketByUserId(msg.to, targetParticipant.connectionGeneration)
        : null;
      if (!target || !targetParticipant || targetParticipant.connectionState !== "connected") {
        this.sendError(ws, "no_such_peer", `peer ${msg.to} not connected`);
        return;
      }
      state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
      if (state.sdpRelayCount > CONFIG.RATE_LIMITS.appleSdpRelaysPerSession) {
        this.sendError(ws, "rate_limited", "signaling relay budget exhausted");
        return;
      }
      await this.saveAppleState(state);
      this.sendTo(target, {
        t: msg.t,
        v: 1,
        sessionId: state.sessionId,
        roomEpoch: state.roomEpoch,
        controllerGeneration: state.controllerGeneration,
        connectionGeneration: participant.connectionGeneration,
        from: meta.userId,
        sdp: msg.sdp,
      });
      return;
    }
    if (msg.t === "ice") {
      const candidate = msg.candidate;
      if (!this.isBoundedUserId(msg.to) || !candidate || typeof candidate !== "object"
        || !this.isBoundedString(candidate.candidate, 4 * 1024)
        || (candidate.sdpMid !== undefined && candidate.sdpMid !== null && !this.isBoundedString(candidate.sdpMid, 4 * 1024))
        || (candidate.sdpMLineIndex !== undefined && candidate.sdpMLineIndex !== null
          && (!Number.isInteger(candidate.sdpMLineIndex) || candidate.sdpMLineIndex < 0 || candidate.sdpMLineIndex > 65535))) {
        this.sendError(ws, "bad_msg", "invalid ICE candidate");
        return;
      }
      const targetParticipant = state.participants[msg.to];
      const target = targetParticipant?.connectionState === "connected"
        ? this.findAppleSocketByUserId(msg.to, targetParticipant.connectionGeneration)
        : null;
      if (!target || !targetParticipant || targetParticipant.connectionState !== "connected") {
        this.sendError(ws, "no_such_peer", `peer ${msg.to} not connected`);
        return;
      }
      state.sdpRelayCount = (state.sdpRelayCount ?? 0) + 1;
      if (state.sdpRelayCount > CONFIG.RATE_LIMITS.appleSdpRelaysPerSession) {
        this.sendError(ws, "rate_limited", "signaling relay budget exhausted");
        return;
      }
      await this.saveAppleState(state);
      this.sendTo(target, {
        t: "ice",
        v: 1,
        sessionId: state.sessionId,
        roomEpoch: state.roomEpoch,
        controllerGeneration: state.controllerGeneration,
        connectionGeneration: participant.connectionGeneration,
        from: meta.userId,
        candidate: {
          candidate: candidate.candidate,
          sdpMid: candidate.sdpMid ?? null,
          sdpMLineIndex: candidate.sdpMLineIndex ?? null,
        },
      });
      return;
    }
    this.sendError(ws, "unknown", `no handler for ${String(msg.t ?? "message")}`);
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

  private async handleAppleClose(ws: WebSocket, code: number) {
    if (this.supersededAppleSockets.has(ws)) return;
    const meta = this.metaFor(ws);
    const state = await this.appleState();
    if (!meta || !state) return;
    const tagGeneration = this.appleSocketGeneration(ws);
    const participant = state.participants[meta.userId];
    if (!participant || participant.connectionGeneration !== tagGeneration) return;
    if (code === 1000) {
      delete state.participants[meta.userId];
      delete state.seatReservations[meta.userId];
      const controllerChanged = state.controllerUserId === meta.userId;
      if (state.speakerFloor?.userId === meta.userId) {
        const floor = state.speakerFloor;
        state.speakerFloor = null;
        this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
      }
      if (controllerChanged) this.chooseAppleController(state, false);
      if (controllerChanged) this.broadcastControllerChange(state);
    } else {
      participant.connectionState = "reconnecting";
      if (state.speakerFloor?.userId === meta.userId) {
        const floor = state.speakerFloor;
        state.speakerFloor = null;
        this.broadcastApple({ t: "speaker.released", v: 1, sessionId: state.sessionId, roomEpoch: state.roomEpoch, controllerGeneration: state.controllerGeneration, connectionGeneration: 0, speakerUserId: floor.userId });
      }
      participant.reservedUntil = Date.now() + CONFIG.APPLE_CONTROLLER_RECLAIM_MS;
      state.seatReservations[meta.userId] = { reservedUntil: participant.reservedUntil, connectionGeneration: participant.connectionGeneration };
      if (state.controllerUserId === meta.userId) {
        this.chooseAppleController(state, true);
        this.broadcastControllerChange(state);
      }
    }
    state.rosterGeneration += 1;
    await this.saveAppleState(state);
    this.broadcastAppleRoster(state);
    await this.scheduleAppleAlarm(state);
  }

  private async scheduleAppleAlarm(state: AppleStoredState) {
    const values = Object.values(state.seatReservations).map((r) => r.reservedUntil);
    if (state.lastEmptyAt) values.push(state.lastEmptyAt + CONFIG.APPLE_EMPTY_ROOM_MS);
    if (state.status === "ended") values.push(Date.now() + CONFIG.STORAGE_PURGE_AFTER_END_MS);
    if (values.length > 0) await this.ctx.storage.setAlarm(Math.min(...values));
    else await this.ctx.storage.setAlarm(Date.now() + CONFIG.APPLE_EMPTY_ROOM_MS);
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
    ws.send(JSON.stringify({ v: 1, ...msg }));
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
