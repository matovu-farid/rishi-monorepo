import { z } from "zod";

const Base = z.object({ v: z.literal(1) });
const UserId = z.string().min(1).max(64);
const SessionId = z.string().min(1).max(64);

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
  contentHash: z.string(),
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
]);
export type ServerMsg = z.infer<typeof ServerMsg>;

// ---------- HTTP bodies ----------
export const CreateSessionBody = z.object({
  bookContext: BookContext,
  requiresApproval: z.boolean(),
});
export const RedeemBody = z.object({ joinToken: z.string().min(10) });
