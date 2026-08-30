import { describe, expect, it } from "vitest";
import {
  AdmissionTicketClaims,
  ClientMsg,
  MAX_RAW_FRAME_BYTES,
  MAX_SYNC_FRAME_BYTES,
  PeerPatch,
  ServerMsg,
  SessionMsg,
  parseClientFrame,
  parseRawFrame,
  parseServerFrame,
} from "./schemas";

const base = {
  v: 1 as const,
  sessionId: "session-1",
  roomEpoch: 3,
  controllerGeneration: 2,
  connectionGeneration: 7,
};

describe("SessionMsg", () => {
  it.each([
    ["session.start", { ...base, t: "session.start", bookId: "book-1", contentHash: "a".repeat(64), format: "epub", status: "active" }],
    ["session.state", { ...base, t: "session.state", status: "active", controllerUserId: "user-1" }],
    ["controller.transfer", { ...base, t: "controller.transfer", toUserId: "user-2" }],
    ["controller.left", { ...base, t: "controller.left", controllerUserId: "user-2" }],
    ["participant.remove", { ...base, t: "participant.remove", userId: "user-2", reason: "removed" }],
    ["participant.restore", { ...base, t: "participant.restore", userId: "user-2" }],
    ["speaker.request", { ...base, t: "speaker.request", requestId: "request-1" }],
    ["speaker.granted", { ...base, t: "speaker.granted", requestId: "request-1", speakerUserId: "user-1" }],
    ["speaker.released", { ...base, t: "speaker.released", speakerUserId: "user-1" }],
    ["participant.forceMute", { ...base, t: "participant.forceMute", userId: "user-2", muted: true }],
    ["turn.refresh", { ...base, t: "turn.refresh", expiresAt: 1_800_000_000 }],
    ["session.ended", { ...base, t: "session.ended", reason: "controller_ended" }],
  ])("accepts the bounded %s message", (_name, message) => {
    expect(SessionMsg.safeParse(message).success).toBe(true);
  });

  it("rejects an unknown field instead of silently accepting it", () => {
    expect(SessionMsg.safeParse({ ...base, t: "speaker.request", requestId: "r", injected: true }).success).toBe(false);
  });
});

describe("bounded signaling fields", () => {
  const validCandidate = {
    candidate: "candidate:1 1 UDP 2122260223 192.0.2.1 54400 typ host",
    sdpMid: "0",
    sdpMLineIndex: 0,
  };

  it.each([
    ["malformed", { candidate: 123, sdpMLineIndex: 0 }],
    ["oversized", { ...validCandidate, candidate: "x".repeat(4 * 1024 + 1) }],
  ])("rejects %s ICE candidates in both legacy directions", (_name, candidate) => {
    expect(ClientMsg.safeParse({ v: 1, t: "ice", to: "user-2", candidate }).success).toBe(false);
    expect(ServerMsg.safeParse({ v: 1, t: "ice", from: "user-1", candidate }).success).toBe(false);
  });

  it("accepts a valid bounded ICE candidate in both legacy directions", () => {
    expect(ClientMsg.safeParse({ v: 1, t: "ice", to: "user-2", candidate: validCandidate }).success).toBe(true);
    expect(ServerMsg.safeParse({ v: 1, t: "ice", from: "user-1", candidate: validCandidate }).success).toBe(true);
  });

  it("enforces the sync-frame size inside direct message schemas", () => {
    const frame = {
      v: 1,
      t: "cursor",
      ts: 1,
      x: 0,
      y: 0,
      extra: "x".repeat(MAX_SYNC_FRAME_BYTES),
    };
    const clientResult = ClientMsg.safeParse({ v: 1, t: "sync.frame", frame });
    const serverResult = ServerMsg.safeParse({ v: 1, t: "sync.frame", from: "user-1", frame });
    expect(clientResult.success).toBe(false);
    expect(serverResult.success).toBe(false);
    expect(JSON.stringify(clientResult)).toMatch(/16 KiB|maximum/);
    expect(JSON.stringify(serverResult)).toMatch(/16 KiB|maximum/);
  });

  it("rejects oversized raw frames before JSON parsing", () => {
    const oversized = "x".repeat(MAX_RAW_FRAME_BYTES + 1);
    expect(() => parseRawFrame(oversized)).toThrow(/64 KiB|maximum|large/i);
  });

  it("bounds relay payloads by UTF-8 bytes in both legacy directions", () => {
    const validPayload = "é".repeat(MAX_RAW_FRAME_BYTES / 2);
    const oversizedPayload = "é".repeat(MAX_RAW_FRAME_BYTES / 2 + 1);
    expect(ClientMsg.safeParse({ v: 1, t: "data.channel.relay", to: "user-2", channel: "sync", payload: validPayload }).success).toBe(true);
    expect(ServerMsg.safeParse({ v: 1, t: "data.channel.relay", from: "user-1", channel: "sync", payload: validPayload }).success).toBe(true);
    expect(ClientMsg.safeParse({ v: 1, t: "data.channel.relay", to: "user-2", channel: "sync", payload: oversizedPayload }).success).toBe(false);
    expect(ServerMsg.safeParse({ v: 1, t: "data.channel.relay", from: "user-1", channel: "sync", payload: oversizedPayload }).success).toBe(false);
  });

  it("rejects oversized nested sync frames in both legacy directions", () => {
    const frame = {
      v: 1,
      t: "cursor",
      ts: 1,
      x: 0,
      y: 0,
      extra: "x".repeat(MAX_SYNC_FRAME_BYTES),
    };
    expect(() => parseClientFrame(JSON.stringify({ v: 1, t: "sync.frame", frame }))).toThrow(/16 KiB|maximum|large/i);
    expect(() => parseServerFrame(JSON.stringify({ v: 1, t: "sync.frame", from: "user-1", frame }))).toThrow(/16 KiB|maximum|large/i);
  });

  it("preserves legacy annotation objects and does not cap pending joiners at five", () => {
    expect(ServerMsg.safeParse({
      v: 1,
      t: "peer.updated",
      userId: "user-1",
      patch: { hasBookFile: true },
    }).success).toBe(true);
    expect(ServerMsg.safeParse({
      v: 1,
      t: "roster",
      participants: [],
      pendingJoiners: Array.from({ length: 6 }, (_, index) => ({
        userId: `user-${index}`,
        profile: { displayName: `User ${index}` },
        requestedAt: index,
      })),
      requiresApproval: true,
      bookContext: { bookId: "book-1", contentHash: "a".repeat(64), format: "epub" },
      status: "live",
    }).success).toBe(true);
  });

  it("accepts an existing empty legacy annotation range", () => {
    expect(ServerMsg.safeParse({
      v: 1,
      t: "sync.frame",
      from: "user-1",
      frame: { v: 1, t: "annotation.add", ts: 1, id: "annotation-1", range: {}, color: "yellow" },
    }).success).toBe(true);
  });
});

describe("AdmissionTicketClaims", () => {
  it("accepts the public admission ticket claim shape", () => {
    expect(AdmissionTicketClaims.safeParse({
      kind: "admission",
      sessionId: "session-1",
      inviteId: "invite-1",
      userId: "user-1",
      ticketId: "ticket-1",
      roomEpoch: 3,
      connectionGeneration: 7,
      exp: 1_800_000_000,
    }).success).toBe(true);
  });

  it("rejects a ticket with the wrong kind or an unknown claim", () => {
    expect(AdmissionTicketClaims.safeParse({
      kind: "jwt",
      sessionId: "session-1",
      inviteId: "invite-1",
      userId: "user-1",
      ticketId: "ticket-1",
      roomEpoch: 3,
      connectionGeneration: 7,
      exp: 1_800_000_000,
      admin: true,
    }).success).toBe(false);
  });
});
