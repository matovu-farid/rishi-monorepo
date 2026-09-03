import { z } from "zod";
import { MAX_SYNC_FRAME_BYTES, SyncFrame, parseSyncFrame } from "./sync";

export { MAX_SYNC_FRAME_BYTES } from "./sync";

export const MAX_RAW_FRAME_BYTES = 64 * 1024;
export const MAX_ICE_STRING_BYTES = 4 * 1024;

const Version = z.literal(1);
const UserId = z.string().min(1).max(64);
const Identifier = z.string().min(1).max(128);
const Generation = z.number().int().nonnegative().max(Number.MAX_SAFE_INTEGER);
const Epoch = Generation;
const Timestamp = z.number().finite().nonnegative();

// Lowercase SHA-256 hex. Keep the literal pattern in sync with the IPC-side
// `hex64` check; wire-level content hashes must never be paths or free text.
export const sha256HexSchema = z
  .string()
  .regex(/^[0-9a-f]{64}$/, "contentHash must be lowercase sha256 hex (64 chars)");

const Profile = z.object({
  displayName: z.string().min(1).max(100),
  avatarUrl: z.string().url().max(2048).optional(),
}).strict();

function byteBoundedString(maxBytes: number, label: string) {
  return z.string().max(maxBytes).refine(
    (value) => new TextEncoder().encode(value).byteLength <= maxBytes,
    `${label} must be at most ${maxBytes} bytes`,
  );
}

const boundedIceString = byteBoundedString(MAX_ICE_STRING_BYTES, "ICE strings");

/** The only ICE shape allowed on the signaling wire. */
export const IceCandidate = z.object({
  candidate: boundedIceString,
  sdpMid: boundedIceString.nullable().optional(),
  sdpMLineIndex: z.number().int().nonnegative().max(65535).nullable().optional(),
}).strict();
export type IceCandidate = z.infer<typeof IceCandidate>;

/** Known peer updates; arbitrary patch dictionaries are deliberately rejected. */
export const PeerPatch = z.union([
  z.object({ hasBookFile: z.boolean() }).strict(),
  z.object({ micState: z.enum(["unmuted", "self-muted", "host-muted"]) }).strict(),
  z.object({ connectionState: z.enum(["connected", "reconnecting"]) }).strict(),
  z.object({ requestingSharer: z.boolean() }).strict(),
  z.object({ profile: Profile }).strict(),
  z.object({ connectionState: z.enum(["connected", "reconnecting"]), hasBookFile: z.boolean() }).strict(),
]);
export type PeerPatch = z.infer<typeof PeerPatch>;

const SessionBase = {
  v: Version,
  sessionId: Identifier,
  roomEpoch: Epoch,
  controllerGeneration: Generation,
  connectionGeneration: Generation,
} as const;

const sessionMessage = <T extends z.ZodRawShape>(shape: T) =>
  z.object({ ...SessionBase, ...shape }).strict();

const SessionStart = sessionMessage({
  t: z.literal("session.start"),
  bookId: Identifier,
  contentHash: sha256HexSchema,
  format: z.enum(["epub", "pdf"]),
  status: z.enum(["waiting", "active"]),
});
const SessionState = sessionMessage({
  t: z.literal("session.state"),
  status: z.enum(["waiting", "active", "ended"]),
  controllerUserId: UserId,
});
const ControllerTransfer = sessionMessage({
  t: z.literal("controller.transfer"),
  toUserId: UserId,
});
const ControllerLeft = sessionMessage({
  t: z.literal("controller.left"),
  controllerUserId: UserId,
});
const ParticipantRemove = sessionMessage({
  t: z.literal("participant.remove"),
  userId: UserId,
  reason: z.enum(["removed", "kicked"]),
});
const ParticipantRestore = sessionMessage({
  t: z.literal("participant.restore"),
  userId: UserId,
});
const SpeakerRequest = sessionMessage({
  t: z.literal("speaker.request"),
  requestId: Identifier,
});
const SpeakerGranted = sessionMessage({
  t: z.literal("speaker.granted"),
  requestId: Identifier,
  speakerUserId: UserId,
});
const SpeakerReleased = sessionMessage({
  t: z.literal("speaker.released"),
  speakerUserId: UserId,
});
const ParticipantForceMute = sessionMessage({
  t: z.literal("participant.forceMute"),
  userId: UserId,
  muted: z.boolean(),
});
const TurnRefresh = sessionMessage({
  t: z.literal("turn.refresh"),
  expiresAt: Timestamp,
});
const SessionEnded = sessionMessage({
  t: z.literal("session.ended"),
  reason: z.enum([
    "controller_ended",
    "room_expired",
    "host_left",
    "host_ended",
    "host_grace_expired",
  ]),
});

/** Versioned session-control messages for the multi-reader room authority. */
export const SessionMsg = z.discriminatedUnion("t", [
  SessionStart,
  SessionState,
  ControllerTransfer,
  ControllerLeft,
  ParticipantRemove,
  ParticipantRestore,
  SpeakerRequest,
  SpeakerGranted,
  SpeakerReleased,
  ParticipantForceMute,
  TurnRefresh,
  SessionEnded,
]);
export type SessionMsg = z.infer<typeof SessionMsg>;
export const SessionControlMsg = SessionMsg;
export type SessionControlMsg = SessionMsg;

export const AdmissionTicketClaims = z.object({
  kind: z.literal("admission"),
  sessionId: Identifier,
  inviteId: Identifier,
  userId: UserId,
  ticketId: Identifier,
  roomEpoch: Epoch,
  connectionGeneration: Generation,
  exp: Timestamp,
}).strict();
export type AdmissionTicketClaims = z.infer<typeof AdmissionTicketClaims>;

function bytesOf(raw: string | Uint8Array | ArrayBuffer): Uint8Array {
  if (typeof raw === "string") return new TextEncoder().encode(raw);
  if (raw instanceof Uint8Array) return raw;
  return new Uint8Array(raw);
}

/** Check the byte limit before attempting JSON.parse on an inbound WS frame. */
export function parseRawFrame(raw: string | Uint8Array | ArrayBuffer): unknown {
  const bytes = bytesOf(raw);
  if (bytes.byteLength > MAX_RAW_FRAME_BYTES) {
    throw new RangeError("raw frame exceeds the 64 KiB maximum");
  }
  return JSON.parse(new TextDecoder().decode(bytes));
}

export function parseClientFrame(raw: string | Uint8Array | ArrayBuffer): ClientMsg {
  const parsed = parseRawFrame(raw);
  validateNestedSyncFrame(parsed);
  return ClientMsg.parse(parsed);
}

export function parseServerFrame(raw: string | Uint8Array | ArrayBuffer): ServerMsg {
  const parsed = parseRawFrame(raw);
  validateNestedSyncFrame(parsed);
  return ServerMsg.parse(parsed);
}

function validateNestedSyncFrame(value: unknown): void {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return;
  const message = value as { t?: unknown; frame?: unknown };
  if (message.t === "sync.frame") parseSyncFrame(message.frame);
}

// ---------- Client → DO (legacy route retained during rollout) ----------
const LegacyBase = z.object({ v: Version }).strict();

export const ClientMsg = z.discriminatedUnion("t", [
  LegacyBase.extend({ t: z.literal("hello"), hasBookFile: z.boolean() }),
  LegacyBase.extend({ t: z.literal("sdp.offer"), to: UserId, sdp: z.string().max(20_000) }),
  LegacyBase.extend({ t: z.literal("sdp.answer"), to: UserId, sdp: z.string().max(20_000) }),
  LegacyBase.extend({ t: z.literal("ice"), to: UserId, candidate: IceCandidate }),
  LegacyBase.extend({ t: z.literal("request.sharer") }),
  LegacyBase.extend({ t: z.literal("pass.sharer"), to: UserId }),
  LegacyBase.extend({ t: z.literal("mute.peer"), userId: UserId, muted: z.boolean() }),
  LegacyBase.extend({ t: z.literal("kick.peer"), userId: UserId }),
  LegacyBase.extend({ t: z.literal("approve.join"), userId: UserId }),
  LegacyBase.extend({ t: z.literal("reject.join"), userId: UserId }),
  LegacyBase.extend({ t: z.literal("has.book"), value: z.boolean() }),
  LegacyBase.extend({ t: z.literal("mic.state"), value: z.enum(["unmuted", "self-muted"]) }),
  LegacyBase.extend({ t: z.literal("speaker.request"), requestId: Identifier }),
  LegacyBase.extend({ t: z.literal("speaker.release"), requestId: Identifier.optional() }),
  LegacyBase.extend({ t: z.literal("leave") }),
  LegacyBase.extend({ t: z.literal("ping") }),
  LegacyBase.extend({ t: z.literal("sync.frame"), frame: SyncFrame }),
  LegacyBase.extend({
    t: z.literal("data.channel.relay"),
    to: UserId,
    channel: z.enum(["sync", "files"]),
    payload: byteBoundedString(MAX_RAW_FRAME_BYTES, "relay payload"),
  }),
]);
export type ClientMsg = z.infer<typeof ClientMsg>;

export const Participant = z.object({
  userId: UserId,
  profile: Profile,
  joinedAt: Timestamp,
  hasBookFile: z.boolean(),
  micState: z.enum(["unmuted", "self-muted", "host-muted"]),
  connectionState: z.enum(["connected", "reconnecting"]),
}).strict();

export const BookContext = z.object({
  bookId: Identifier,
  contentHash: sha256HexSchema,
  format: z.enum(["epub", "pdf"]),
}).strict();

export const ServerMsg = z.discriminatedUnion("t", [
  LegacyBase.extend({
    t: z.literal("welcome"), you: UserId, role: z.enum(["host", "viewer"]),
    sharerId: UserId, reconnectToken: z.string().max(4096), reservedUntil: Timestamp,
  }),
  LegacyBase.extend({
    t: z.literal("roster"),
    participants: z.array(Participant).max(5),
    pendingJoiners: z.array(z.object({ userId: UserId, profile: Profile, requestedAt: Timestamp }).strict()).optional(),
    requiresApproval: z.boolean(),
    bookContext: BookContext,
    status: z.enum(["live", "host-suspended", "ended"]),
    hostSuspendedUntil: Timestamp.optional(),
  }),
  LegacyBase.extend({ t: z.literal("peer.joined"), userId: UserId, profile: Profile, hasBookFile: z.boolean() }),
  LegacyBase.extend({ t: z.literal("peer.left"), userId: UserId, reason: z.enum(["left", "kicked", "dropped"]) }),
  LegacyBase.extend({ t: z.literal("peer.updated"), userId: UserId, patch: PeerPatch }),
  LegacyBase.extend({ t: z.literal("sdp.offer"), from: UserId, sdp: z.string().max(20_000) }),
  LegacyBase.extend({ t: z.literal("sdp.answer"), from: UserId, sdp: z.string().max(20_000) }),
  LegacyBase.extend({ t: z.literal("ice"), from: UserId, candidate: IceCandidate }),
  LegacyBase.extend({ t: z.literal("role.transferred"), newSharerId: UserId }),
  LegacyBase.extend({ t: z.literal("join.requested"), userId: UserId, profile: Profile }),
  LegacyBase.extend({ t: z.literal("approval.result"), approved: z.boolean(), reason: z.string().max(4096).optional() }),
  LegacyBase.extend({ t: z.literal("host.suspended"), until: Timestamp }),
  LegacyBase.extend({ t: z.literal("host.resumed") }),
  LegacyBase.extend({ t: z.literal("kicked"), reason: z.string().max(4096) }),
  LegacyBase.extend({ t: z.literal("session.ended"), reason: z.enum(["host_left", "host_ended", "host_grace_expired"]) }),
  LegacyBase.extend({ t: z.literal("error"), code: z.string().max(128), message: z.string().max(4096) }),
  LegacyBase.extend({ t: z.literal("pong") }),
  LegacyBase.extend({ t: z.literal("sync.frame"), from: UserId, frame: SyncFrame }),
  LegacyBase.extend({
    t: z.literal("data.channel.relay"),
    from: UserId,
    channel: z.enum(["sync", "files"]),
    payload: byteBoundedString(MAX_RAW_FRAME_BYTES, "relay payload"),
  }),
]);
export type ServerMsg = z.infer<typeof ServerMsg>;

// ---------- HTTP bodies ----------
export const CreateSessionBody = z.object({
  bookContext: BookContext,
  requiresApproval: z.boolean(),
}).strict();
export const RedeemBody = z.object({ joinToken: z.string().min(10).max(4096) }).strict();
