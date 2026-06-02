import { z } from "zod";

const Base = z.object({ v: z.literal(1) });
const UserId = z.string().min(1).max(64);
// Lowercase SHA-256 hex. A strict superset of the IPC-side `hex64` check in
// `apps/rishi-electron/src/main/sharing/sharing.schemas.ts` (which uses the
// same [0-9a-f]{64} class with `/i`). Tightening here closes finding 253-005:
// a hostile host can no longer carry an arbitrary `contentHash` (e.g. empty
// or `"../../../etc/passwd"`) on the wire even before IPC persistence rejects
// it. Keep the literal pattern in sync — `grep -r '\[0-9a-f\]\{64\}'` should
// find both this file and the IPC schema.
const sha256HexSchema = z
  .string()
  .regex(/^[0-9a-f]{64}$/, "contentHash must be lowercase sha256 hex (64 chars)");

const Profile = z.object({
  displayName: z.string().min(1).max(100),
  avatarUrl: z.string().url().optional(),
});

// ---------- Client → DO ----------
export const ClientMsg = z.discriminatedUnion("t", [
  Base.extend({ t: z.literal("hello"), hasBookFile: z.boolean() }),
  Base.extend({ t: z.literal("sdp.offer"), to: UserId, sdp: z.string().max(20_000) }),
  Base.extend({ t: z.literal("sdp.answer"), to: UserId, sdp: z.string().max(20_000) }),
  Base.extend({ t: z.literal("ice"), to: UserId, candidate: z.unknown() }),
  Base.extend({ t: z.literal("request.sharer") }),
  Base.extend({ t: z.literal("pass.sharer"), to: UserId }),
  Base.extend({ t: z.literal("mute.peer"), userId: UserId, muted: z.boolean() }),
  Base.extend({ t: z.literal("kick.peer"), userId: UserId }),
  Base.extend({ t: z.literal("approve.join"), userId: UserId }),
  Base.extend({ t: z.literal("reject.join"), userId: UserId }),
  Base.extend({ t: z.literal("has.book"), value: z.boolean() }),
  Base.extend({ t: z.literal("mic.state"), value: z.enum(["unmuted", "self-muted"]) }),
  Base.extend({ t: z.literal("leave") }),
  Base.extend({ t: z.literal("ping") }),
  // Sync-frame relay. Carries an opaque payload (validated as a SyncMsg by the
  // protocol's `sync.ts` schema on the client side). The worker broadcasts to
  // all other connected participants without inspecting `frame`.
  //
  // Design note: the production happy-path for reader-position sync is the
  // peer-to-peer `sync` data channel on each RTCPeerConnection. This WS relay
  // is a server-side fallback used when the data-channel send is unavailable
  // (e.g. the E2E fake `RtcAdapter` is a no-op). Production code may also use
  // the relay when DCs haven't opened yet — it's cheap and rate-limited by the
  // existing per-socket frame bucket.
  Base.extend({ t: z.literal("sync.frame"), frame: z.unknown() }),
  // TEST-ONLY data-channel relay. The production wire path for sync / files
  // payloads is the peer-to-peer RTCDataChannel; this WS relay exists so the
  // E2E fake RtcAdapter (`testing/fakeRtcAdapter.ts`) — whose `send()` is a
  // no-op because two Electron processes can't share an RTCPeerConnection —
  // can shuttle payloads through the worker. Production code never emits
  // this; if it ever does, the receive side is guarded behind a test-only
  // global bus and is a no-op. The per-socket frame bucket also rate-limits
  // this path so a misbehaving client cannot flood peers.
  Base.extend({
    t: z.literal("data.channel.relay"),
    to: UserId,
    channel: z.enum(["sync", "files"]),
    payload: z.string(),
  }),
]);
export type ClientMsg = z.infer<typeof ClientMsg>;

// ---------- DO → Client ----------
export const Participant = z.object({
  userId: UserId,
  profile: Profile,
  joinedAt: z.number(),
  hasBookFile: z.boolean(),
  micState: z.enum(["unmuted", "self-muted", "host-muted"]),
  connectionState: z.enum(["connected", "reconnecting"]),
});

export const BookContext = z.object({
  bookId: z.string(),
  contentHash: sha256HexSchema,
  format: z.enum(["epub", "pdf"]),
});

export const ServerMsg = z.discriminatedUnion("t", [
  Base.extend({
    t: z.literal("welcome"), you: UserId, role: z.enum(["host", "viewer"]),
    sharerId: UserId, reconnectToken: z.string(), reservedUntil: z.number(),
  }),
  Base.extend({
    t: z.literal("roster"),
    participants: z.array(Participant),
    pendingJoiners: z.array(z.object({ userId: UserId, profile: Profile, requestedAt: z.number() })).optional(),
    requiresApproval: z.boolean(),
    bookContext: BookContext,
    status: z.enum(["live", "host-suspended", "ended"]),
    hostSuspendedUntil: z.number().optional(),
  }),
  Base.extend({ t: z.literal("peer.joined"), userId: UserId, profile: Profile, hasBookFile: z.boolean() }),
  Base.extend({ t: z.literal("peer.left"), userId: UserId, reason: z.enum(["left", "kicked", "dropped"]) }),
  Base.extend({ t: z.literal("peer.updated"), userId: UserId, patch: z.record(z.string(), z.unknown()) }),
  Base.extend({ t: z.literal("sdp.offer"), from: UserId, sdp: z.string() }),
  Base.extend({ t: z.literal("sdp.answer"), from: UserId, sdp: z.string() }),
  Base.extend({ t: z.literal("ice"), from: UserId, candidate: z.unknown() }),
  Base.extend({ t: z.literal("role.transferred"), newSharerId: UserId }),
  Base.extend({ t: z.literal("join.requested"), userId: UserId, profile: Profile }),
  Base.extend({ t: z.literal("approval.result"), approved: z.boolean(), reason: z.string().optional() }),
  Base.extend({ t: z.literal("host.suspended"), until: z.number() }),
  Base.extend({ t: z.literal("host.resumed") }),
  Base.extend({ t: z.literal("kicked"), reason: z.string() }),
  Base.extend({
    t: z.literal("session.ended"),
    reason: z.enum(["host_left", "host_ended", "host_grace_expired"]),
  }),
  Base.extend({ t: z.literal("error"), code: z.string(), message: z.string() }),
  Base.extend({ t: z.literal("pong") }),
  // Relayed sync frame. `from` is the sender's userId; `frame` is the opaque
  // SyncMsg payload (validated client-side against `sync.ts`).
  Base.extend({ t: z.literal("sync.frame"), from: UserId, frame: z.unknown() }),
  // TEST-ONLY: relayed counterpart of the ClientMsg above. The worker stamps
  // `from` with the sender's userId and forwards. See ClientMsg.data.channel.relay
  // for rationale.
  Base.extend({
    t: z.literal("data.channel.relay"),
    from: UserId,
    channel: z.enum(["sync", "files"]),
    payload: z.string(),
  }),
]);
export type ServerMsg = z.infer<typeof ServerMsg>;

// ---------- HTTP bodies ----------
export const CreateSessionBody = z.object({
  bookContext: BookContext,
  requiresApproval: z.boolean(),
});
export const RedeemBody = z.object({ joinToken: z.string().min(10) });
