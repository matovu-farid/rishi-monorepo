import { SELF, env, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, expectTypeOf, it } from "vitest";
import { sign } from "../src/hmac";
import type { AppleSessionRoom } from "../src/AppleSessionRoom";

const SECRET = "test-secret-do-not-use-in-prod";
const CONTENT_HASH = "a".repeat(64);
const createdRoomIds = new Set<string>();

afterEach(async () => {
  await Promise.all([...createdRoomIds].map(async (sessionId) => {
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const id = namespace.idFromName(sessionId);
    const stub = namespace.get(id);
    await runInDurableObject(stub, async (_instance, ctx) => {
      await ctx.storage.delete("apple-state");
      await ctx.storage.deleteAlarm();
    });
  }));
  createdRoomIds.clear();
});

function base64Url(value: string): string {
  return btoa(value).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function command(sessionId: string, action: string, payload: Record<string, unknown>) {
  const path = `/v2/internal/rooms/${sessionId}`;
  const body = { action, payload };
  const token = await sign({ method: "POST", path, body, exp: Date.now() + 60_000 }, SECRET);
  return SELF.fetch(`https://example.com${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-rishi-internal-token": token },
    body: JSON.stringify(body),
  });
}

async function createRoom(sessionId: string, maxParticipants = 5) {
  const response = await command(sessionId, "createRoom", {
    sessionId,
    initialSharerUserId: "u_owner",
    bookContext: { bookId: "book-1", contentHash: CONTENT_HASH, format: "epub" },
    maxParticipants,
  });
  expect(response.status).toBe(200);
  await response.json();
  createdRoomIds.add(sessionId);
}

async function issueTicket(sessionId: string, userId: string) {
  const response = await command(sessionId, "issueAdmissionTicket", {
    sessionId,
    inviteId: `invite-${userId}`,
    userId,
    contentHash: CONTENT_HASH,
    profile: { displayName: userId },
  });
  expect(response.status).toBe(200);
  return response.json() as Promise<{ admissionTicket: string; claims: { ticketId: string } }>;
}

async function openSocket(sessionId: string, userId: string, admissionTicket: string, accept = true) {
  const response = await SELF.fetch(`https://example.com/v2/sessions/${sessionId}/wss`, {
    headers: {
      upgrade: "websocket",
      "sec-websocket-protocol": [
        "rishi.sharing.v1",
        `jwt.${base64Url(`${userId}--${userId}`)}`,
        `admission.${admissionTicket}`,
      ].join(", "),
    },
  });
  if (response.status !== 101 || !response.webSocket) {
    await response.text();
    throw Object.assign(new Error(`upgrade failed: ${response.status}`), { status: response.status });
  }
  if (accept) response.webSocket.accept();
  return response.webSocket;
}

function nextAppleMessage(ws: WebSocket, predicate: (message: any) => boolean): Promise<any> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ws.removeEventListener("message", onMessage as any);
      reject(new Error("timed out waiting for Apple room message"));
    }, 2_000);
    const onMessage = (event: MessageEvent) => {
      const message = JSON.parse(String(event.data));
      if (!predicate(message)) return;
      clearTimeout(timeout);
      ws.removeEventListener("message", onMessage as any);
      resolve(message);
    };
    ws.addEventListener("message", onMessage as any);
  });
}

function nextSocketClose(ws: WebSocket): Promise<CloseEvent> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      ws.removeEventListener("close", onClose as any);
      reject(new Error("timed out waiting for Apple room socket close"));
    }, 2_000);
    const onClose = (event: CloseEvent) => {
      clearTimeout(timeout);
      ws.removeEventListener("close", onClose as any);
      resolve(event);
    };
    ws.addEventListener("close", onClose as any);
  });
}

describe("AppleSessionRoom admission recovery", () => {
  it("[W4-008] exposes an HMAC-only account-revocation payload without a sessionId", () => {
    expectTypeOf<Parameters<AppleSessionRoom["revokeAccountReferences"]>[0]>()
      .toEqualTypeOf<{ accountUserId: string; deletionOperationId: string }>();
  });

  it("createRoom binds canonical sessionId", async () => {
    const sessionId = `apple-canonical-${crypto.randomUUID()}`;
    const response = await command(sessionId, "createRoom", {
      sessionId: `${sessionId}-different`,
      initialSharerUserId: "u_owner",
      bookContext: { bookId: "book-1", contentHash: CONTENT_HASH, format: "epub" },
      maxParticipants: 5,
    });

    expect(response.status).toBe(400);
    await response.json();
    createdRoomIds.add(sessionId);
  });

  it("admission ticket has exactly one prefix", async () => {
    const sessionId = `apple-prefix-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const response = await issueTicket(sessionId, "u_reader");

    expect(response.admissionTicket.startsWith("admission.")).toBe(false);
    await expect(openSocket(`${sessionId}-other`, "u_reader", response.admissionTicket))
      .rejects.toMatchObject({ status: 401 });
    await expect(openSocket(sessionId, "u_reader", `admission.${response.admissionTicket}`))
      .rejects.toMatchObject({ status: 401 });
  });

  it("unconsumed admission lease expires and restores capacity", async () => {
    const sessionId = `apple-lease-${crypto.randomUUID()}`;
    await createRoom(sessionId, 1);
    const first = await issueTicket(sessionId, "u_first");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const id = namespace.idFromName(sessionId);
    const stub = namespace.get(id);

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.pendingAdmissionLeases[first.claims.ticketId].expiresAt = Date.now() - 1;
      await ctx.storage.put("apple-state", state);
      await ctx.storage.setAlarm(Date.now());
    });

    const second = await command(sessionId, "issueAdmissionTicket", {
      sessionId,
      inviteId: "invite-second",
      userId: "u_second",
      contentHash: CONTENT_HASH,
      profile: { displayName: "Second" },
    });
    expect(second.status).toBe(200);
    await second.json();
  });

  it("supersedes a pending lease without letting an old alarm erase the new generation", async () => {
    const sessionId = `apple-supersede-${crypto.randomUUID()}`;
    await createRoom(sessionId, 1);
    const first = await issueTicket(sessionId, "u_reader");
    const second = await issueTicket(sessionId, "u_reader");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.pendingAdmissionLeases[first.claims.ticketId]).toBeUndefined();
      expect(state.pendingAdmissionLeases[second.claims.ticketId].connectionGeneration).toBe(2);
      await ctx.storage.setAlarm(Date.now());
      await (_instance as any).alarm();
      const after = await ctx.storage.get<any>("apple-state");
      expect(after.pendingAdmissionLeases[second.claims.ticketId].connectionGeneration).toBe(2);
    });

    await expect(openSocket(sessionId, "u_reader", first.admissionTicket)).rejects.toMatchObject({ status: 401 });
    await expect(openSocket(sessionId, "u_reader", second.admissionTicket)).resolves.toBeInstanceOf(WebSocket);
  });

  it("reissue fences and closes a stale socket, then expires the empty post-occupancy room", async () => {
    const sessionId = `apple-reissue-empty-${crypto.randomUUID()}`;
    await createRoom(sessionId, 1);
    const first = await issueTicket(sessionId, "u_reader");
    const staleSocket = await openSocket(sessionId, "u_reader", first.admissionTicket);
    const staleSocketClosed = nextSocketClose(staleSocket);

    const replacement = await issueTicket(sessionId, "u_reader");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await expect(staleSocketClosed).resolves.toMatchObject({ code: 4000, reason: "reissued" });
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.participants.u_reader.connectionGeneration).toBe(2);
      expect(state.participants.u_reader.connectionState).toBe("reconnecting");
      state.pendingAdmissionLeases[replacement.claims.ticketId].expiresAt = Date.now() - 1;
      await ctx.storage.put("apple-state", state);

      await (_instance as any).alarm();

      const empty = await ctx.storage.get<any>("apple-state");
      expect(empty.pendingAdmissionLeases).toEqual({});
      expect(empty.participants).toEqual({});
      expect(empty.lastEmptyAt).toEqual(expect.any(Number));

      empty.lastEmptyAt = Date.now() - (2 * 60_000) - 1;
      await ctx.storage.put("apple-state", empty);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.status).toBe("ended");
    });
  });

  it("repeats an HMAC-only account revocation without changing the stored result", async () => {
    const sessionId = `apple-revoke-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_removed");
    await openSocket(sessionId, "u_removed", issued.admissionTicket);
    const payload = { accountUserId: "u_removed", deletionOperationId: "delete-1" };

    const first = await command(sessionId, "revokeAccountReferences", payload);
    expect(first.status).toBe(200);
    const firstResult = await first.json();
    expect(firstResult).toEqual({ ok: true, status: "removed" });

    const repeated = await command(sessionId, "revokeAccountReferences", payload);
    expect(repeated.status).toBe(200);
    expect(await repeated.json()).toEqual(firstResult);
  });

  it("[W4-001] persists a deleted-account tombstone and rejects rejoin, admission, and restoration", async () => {
    const sessionId = `apple-w4-tombstone-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_deleted");

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_deleted",
      deletionOperationId: "delete-w4-tombstone",
    });
    expect(revoked.status).toBe(200);
    expect(await revoked.json()).toEqual({ ok: true, status: "removed" });

    await expect(openSocket(sessionId, "u_deleted", issued.admissionTicket))
      .rejects.toMatchObject({ status: 401 });

    const rejoin = await command(sessionId, "issueAdmissionTicket", {
      sessionId,
      inviteId: "invite-rejoin",
      userId: "u_deleted",
      contentHash: CONTENT_HASH,
      profile: { displayName: "Deleted" },
    });
    expect(rejoin.status).toBe(400);
    expect(await rejoin.json()).toMatchObject({ code: "ACCOUNT_DELETED" });

    const restored = await command(sessionId, "restoreParticipant", {
      actingUserId: "u_owner",
      userId: "u_deleted",
      inviteId: "invite-restore",
      contentHash: CONTENT_HASH,
      expectedControllerGeneration: 1,
      profile: { displayName: "Deleted" },
    });
    expect(restored.status).toBe(400);
    expect(await restored.json()).toMatchObject({ code: "ACCOUNT_DELETED" });

    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.deletedAccountTombstones.u_deleted).toMatchObject({ deletionOperationId: "delete-w4-tombstone" });
      expect(state.participants.u_deleted).toBeUndefined();
      expect(state.seatReservations.u_deleted).toBeUndefined();
      expect(Object.values(state.pendingAdmissionLeases).some((lease: any) => lease.userId === "u_deleted")).toBe(false);
      expect(state.removedUserIds).not.toContain("u_deleted");
    });
  });

  it("[W4-002] removes provisional account references before storing a SESSION_NOT_FOUND acknowledgement", async () => {
    const sessionId = `apple-w4-provisional-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_absent");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      delete state.participants.u_absent;
      state.seatReservations.u_absent = { reservedUntil: Date.now() + 60_000, connectionGeneration: 1 };
      state.removedUserIds.push("u_absent");
      expect(state.pendingAdmissionLeases[issued.claims.ticketId]).toMatchObject({ userId: "u_absent" });
      await ctx.storage.put("apple-state", state);
    });

    const payload = {
      accountUserId: "u_absent",
      deletionOperationId: "delete-w4-provisional",
    };
    const first = await command(sessionId, "revokeAccountReferences", payload);
    expect(first.status).toBe(200);
    const acknowledged = await first.json();
    expect(acknowledged).toEqual({ ok: true, status: "not_found" });

    const repeated = await command(sessionId, "revokeAccountReferences", payload);
    expect(await repeated.json()).toEqual(acknowledged);

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.participants.u_absent).toBeUndefined();
      expect(state.seatReservations.u_absent).toBeUndefined();
      expect(Object.values(state.pendingAdmissionLeases).some((lease: any) => lease.userId === "u_absent")).toBe(false);
      expect(state.removedUserIds).not.toContain("u_absent");
      expect(state.deletedAccountTombstones.u_absent).toMatchObject({ deletionOperationId: "delete-w4-provisional" });
    });
  });

  it("[W4-006] clears an absent provisional controller reference before storing SESSION_NOT_FOUND", async () => {
    const sessionId = `apple-w4-provisional-controller-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.controllerUserId = "u_absent_controller";
      state.controllerGeneration = 2;
      state.roomEpoch = 2;
      state.pendingAdmissionLeases.stale = {
        ticketId: "stale",
        userId: "u_absent_controller",
        inviteId: "invite-stale",
        connectionGeneration: 1,
        expiresAt: Date.now() + 60_000,
      };
      await ctx.storage.put("apple-state", state);
    });

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_absent_controller",
      deletionOperationId: "delete-w4-provisional-controller",
    });
    expect(await revoked.json()).toEqual({ ok: true, status: "not_found" });

    const status = await command(sessionId, "getRoomStatus", {});
    expect(await status.json()).toMatchObject({
      controllerUserId: "u_owner",
      controllerGeneration: 3,
      roomEpoch: 3,
    });
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.pendingAdmissionLeases.stale).toBeUndefined();
    });
  });

  it("[W4-007] closes a stale account socket while cleaning an absent provisional member", async () => {
    const sessionId = `apple-w4-provisional-socket-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_stale_socket");
    const socket = await openSocket(sessionId, "u_stale_socket", issued.admissionTicket);
    const closed = nextSocketClose(socket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      delete state.participants.u_stale_socket;
      state.pendingAdmissionLeases.stale = {
        ticketId: "stale",
        userId: "u_stale_socket",
        inviteId: "invite-stale",
        connectionGeneration: 1,
        expiresAt: Date.now() + 60_000,
      };
      await ctx.storage.put("apple-state", state);
    });

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_stale_socket",
      deletionOperationId: "delete-w4-provisional-socket",
    });
    expect(await revoked.json()).toEqual({ ok: true, status: "not_found" });
    await expect(closed).resolves.toMatchObject({ code: 1000, reason: "account deleted" });
  });

  it("[W4-003] tombstones an owner revocation before ending the room so it remains purgeable", async () => {
    const sessionId = `apple-w4-owner-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner",
      deletionOperationId: "delete-w4-owner",
    });
    expect(await revoked.json()).toEqual({ ok: true, status: "ended" });

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.status).toBe("ended");
      expect(state.deletedAccountTombstones.u_owner).toMatchObject({ deletionOperationId: "delete-w4-owner" });
    });

    const purged = await command(sessionId, "purgeAppleRoom", {});
    expect(purged.status).toBe(200);
    expect(await purged.json()).toEqual({ ok: true });
  });

  it("[W4-010] persists initial-sharer tombstone and removal when revoking an already-ended room", async () => {
    const sessionId = `apple-w4-ended-owner-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    const ended = await command(sessionId, "endRoom", {
      actingUserId: "u_owner",
      expectedControllerGeneration: 1,
    });
    expect(await ended.json()).toMatchObject({ status: "ended" });

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner",
      deletionOperationId: "delete-w4-ended-owner",
    });
    expect(await revoked.json()).toEqual({ ok: true, status: "ended" });

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state).toMatchObject({
        status: "ended",
        initialSharerUserId: "",
        controllerUserId: "",
        deletedAccountTombstones: {
          u_owner: { deletionOperationId: "delete-w4-ended-owner" },
        },
        accountRevocations: {
          "delete-w4-ended-owner": {
            accountUserId: "u_owner",
            result: { ok: true, status: "ended" },
          },
        },
      });
      expect(state.participants.u_owner).toBeUndefined();
    });
  });

  it("[W4-004] rejects queued Apple frames after the Apple room has been purged", async () => {
    const sessionId = `apple-w4-queued-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    let server: WebSocket;

    await runInDurableObject(stub, async (_instance, ctx) => {
      server = ctx.getWebSockets()[0]!;
    });

    await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner",
      deletionOperationId: "delete-w4-queued",
    });
    await command(sessionId, "purgeAppleRoom", {});

    await runInDurableObject(stub, async (_instance, ctx) => {
      await ctx.storage.put("state", {
        sessionId,
        hostUserId: "u_owner",
        sharerUserId: "u_owner",
        bookContext: { bookId: "legacy", contentHash: CONTENT_HASH, format: "epub" },
        requiresApproval: false,
        status: "live",
        createdAt: Date.now(),
        participants: {
          u_owner: {
            userId: "u_owner",
            profile: { displayName: "Owner" },
            joinedAt: Date.now(),
            hasBookFile: false,
            micState: "unmuted",
            connectionState: "connected",
          },
        },
        pendingJoiners: {},
        joinTokens: {},
        hostProfileFallback: { displayName: "Owner" },
      });
      await (_instance as any).webSocketMessage(server!, JSON.stringify({ v: 1, t: "has.book", value: true }));
      expect((await ctx.storage.get<any>("state")).participants.u_owner.hasBookFile).toBe(false);
    });
  });

  it("[W4-009] ignores a stale Apple socket close after purge instead of mutating legacy state", async () => {
    const sessionId = `apple-w4-close-after-purge-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    const reader = await issueTicket(sessionId, "u_reader");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    await openSocket(sessionId, "u_reader", reader.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    let readerServer: WebSocket;

    await runInDurableObject(stub, async (_instance, ctx) => {
      readerServer = ctx.getWebSockets().find((socket) => {
        return JSON.parse(ctx.getTags(socket)[0] ?? "{}").meta?.userId === "u_reader";
      })!;
    });

    await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner",
      deletionOperationId: "delete-w4-close-after-purge",
    });
    await command(sessionId, "purgeAppleRoom", {});

    await runInDurableObject(stub, async (_instance, ctx) => {
      await ctx.storage.put("state", {
        sessionId,
        hostUserId: "u_owner",
        sharerUserId: "u_owner",
        bookContext: { bookId: "legacy", contentHash: CONTENT_HASH, format: "epub" },
        requiresApproval: false,
        status: "live",
        createdAt: Date.now(),
        participants: {
          u_owner: {
            userId: "u_owner",
            profile: { displayName: "Owner" },
            joinedAt: Date.now(),
            hasBookFile: false,
            micState: "unmuted",
            connectionState: "connected",
          },
          u_reader: {
            userId: "u_reader",
            profile: { displayName: "Reader" },
            joinedAt: Date.now(),
            hasBookFile: false,
            micState: "unmuted",
            connectionState: "connected",
          },
        },
        pendingJoiners: {},
        joinTokens: {},
        hostProfileFallback: { displayName: "Owner" },
      });

      await (_instance as any).webSocketClose(readerServer!, 4000);

      expect((await ctx.storage.get<any>("state")).participants.u_reader.connectionState).toBe("connected");
    });
  });

  it("revokes an unconsumed ticket and ends an owner account's room idempotently", async () => {
    const sessionId = `apple-owner-revoke-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const pending = await issueTicket(sessionId, "u_pending");
    const removed = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_pending", deletionOperationId: "delete-pending",
    });
    expect(await removed.json()).toEqual({ ok: true, status: "removed" });
    await expect(openSocket(sessionId, "u_pending", pending.admissionTicket)).rejects.toMatchObject({ status: 401 });

    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const first = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner", deletionOperationId: "delete-owner",
    });
    expect(await first.json()).toEqual({ ok: true, status: "ended" });
    const repeated = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_owner", deletionOperationId: "delete-owner",
    });
    expect(await repeated.json()).toEqual({ ok: true, status: "ended" });
  });

  it("ends when a revoked participant-controller has no eligible replacement", async () => {
    const sessionId = `apple-no-replacement-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const controller = await issueTicket(sessionId, "u_controller");
    await openSocket(sessionId, "u_controller", controller.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.controllerUserId = "u_controller";
      state.controllerGeneration = 2;
      state.roomEpoch = 2;
      await ctx.storage.put("apple-state", state);
    });

    const revoked = await command(sessionId, "revokeAccountReferences", {
      accountUserId: "u_controller", deletionOperationId: "delete-only-controller",
    });
    expect(await revoked.json()).toEqual({ ok: true, status: "ended" });
    const status = await command(sessionId, "getRoomStatus", {});
    expect(await status.json()).toMatchObject({ status: "ended" });
  });

  it("rehydrates pre-W2 Apple state before issuing a new lease", async () => {
    const sessionId = `apple-rehydrate-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      delete state.pendingAdmissionLeases;
      delete state.observations;
      delete state.accountRevocations;
      delete state.startupExpiresAt;
      delete state.hasEverBeenOccupied;
      await ctx.storage.put("apple-state", state);
    });

    const ticket = await issueTicket(sessionId, "u_rehydrated");
    await expect(openSocket(sessionId, "u_rehydrated", ticket.admissionTicket)).resolves.toBeInstanceOf(WebSocket);
  });

  it("limits observations to actual admitted members and never exposes participant identities", async () => {
    const sessionId = `apple-observations-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_member");

    const forbidden = await command(sessionId, "getMemberObservations", {
      sessionId,
      requestingUserId: "u_other",
    });
    expect(forbidden.status).toBe(403);
    await forbidden.json();

    const pending = await command(sessionId, "getMemberObservations", {
      sessionId,
      requestingUserId: "u_member",
    });
    expect(pending.status).toBe(403);
    await pending.json();

    await openSocket(sessionId, "u_member", issued.admissionTicket);

    const allowed = await command(sessionId, "getMemberObservations", {
      sessionId,
      requestingUserId: "u_member",
    });
    expect(allowed.status).toBe(200);
    const body = await allowed.json() as { membership: string; observations: Array<Record<string, unknown>> };
    expect(body.membership).toBe("participant");
    expect(JSON.stringify(body.observations)).not.toContain("u_member");
  });

  it("consumes a bare admission ticket only once", async () => {
    const sessionId = `apple-replay-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_member");
    await openSocket(sessionId, "u_member", issued.admissionTicket);

    await expect(openSocket(sessionId, "u_member", issued.admissionTicket))
      .rejects.toMatchObject({ status: 401 });
  });

  it("admits exactly one of two parallel sockets for one ticket without corrupting capacity", async () => {
    const sessionId = `apple-parallel-admission-${crypto.randomUUID()}`;
    await createRoom(sessionId, 1);
    const issued = await issueTicket(sessionId, "u_member");

    // Start both upgrades before awaiting either one so each competes to
    // atomically consume the same durable ticket reservation.
    const attempts = await Promise.allSettled([
      openSocket(sessionId, "u_member", issued.admissionTicket),
      openSocket(sessionId, "u_member", issued.admissionTicket),
    ]);
    const admitted = attempts.filter((attempt) => attempt.status === "fulfilled");
    const rejected = attempts.filter((attempt) => attempt.status === "rejected");

    expect(admitted).toHaveLength(1);
    expect(rejected).toHaveLength(1);
    expect(rejected[0]).toMatchObject({ status: "rejected", reason: { status: 401 } });

    const status = await command(sessionId, "getRoomStatus", {});
    expect(status.status).toBe(200);
    expect(await status.json()).toMatchObject({
      maxParticipants: 1,
      participants: [{ userId: "u_member", connectionState: "connected" }],
    });

    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(Object.keys(state.consumedAdmissionTicketIds)).toEqual([issued.claims.ticketId]);
      expect(state.pendingAdmissionLeases).toEqual({});
      expect(Object.keys(state.participants)).toEqual(["u_member"]);
      expect(state.participants.u_member.connectionState).toBe("connected");
      expect(state.seatReservations).toEqual({});
    });

    const overCapacity = await command(sessionId, "issueAdmissionTicket", {
      sessionId,
      inviteId: "invite-second-member",
      userId: "u_second_member",
      contentHash: CONTENT_HASH,
      profile: { displayName: "Second member" },
    });
    expect(overCapacity.status).toBe(409);
    await overCapacity.json();
  });

  it("replaces a revoked participant-controller with the oldest connected member exactly once", async () => {
    const sessionId = `apple-controller-revoke-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    const controller = await issueTicket(sessionId, "u_controller");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    await openSocket(sessionId, "u_controller", controller.admissionTicket);

    const transferred = await command(sessionId, "transferController", {
      actingUserId: "u_owner",
      targetUserId: "u_controller",
      expectedControllerGeneration: 1,
    });
    expect(transferred.status).toBe(200);

    const payload = { accountUserId: "u_controller", deletionOperationId: "delete-controller" };
    const first = await command(sessionId, "revokeAccountReferences", payload);
    expect(first.status).toBe(200);
    expect(await first.json()).toEqual({ ok: true, status: "removed" });

    const status = await command(sessionId, "getRoomStatus", {});
    expect(await status.json()).toMatchObject({ controllerUserId: "u_owner", controllerGeneration: 3 });

    const repeated = await command(sessionId, "revokeAccountReferences", payload);
    expect(await repeated.json()).toEqual({ ok: true, status: "removed" });
    const unchanged = await command(sessionId, "getRoomStatus", {});
    expect(await unchanged.json()).toMatchObject({ controllerUserId: "u_owner", controllerGeneration: 3 });
  });

  it("stores only increasing controller snapshots and fences a controller reissue", async () => {
    const sessionId = `apple-snapshot-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const frame = (sequence: number, controllerGeneration = 1) => ({
      v: 1,
      t: "snapshot",
      format: "epub",
      bookId: "book-1",
      contentHash: CONTENT_HASH,
      position: { format: "epub", cfi: "epubcfi(/6/2)" },
      isPlaying: false,
      ttsRate: 1,
      roomEpoch: 1,
      controllerGeneration,
      sequence,
      source: "controller",
    });
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const server = ctx.getWebSockets()[0];
      expect(server).toBeDefined();
      await (_instance as any).webSocketMessage(server, JSON.stringify({ v: 1, t: "sync.frame", frame: frame(3, 0) }));
      expect((await ctx.storage.get<any>("apple-state")).latestSyncSnapshot).toBeUndefined();
      await (_instance as any).webSocketMessage(server, JSON.stringify({ v: 1, t: "sync.frame", frame: frame(2) }));
      await (_instance as any).webSocketMessage(server, JSON.stringify({ v: 1, t: "sync.frame", frame: frame(1) }));
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.latestSyncSnapshot.sequence).toBe(2);
    });

    const replacement = await issueTicket(sessionId, "u_owner");
    expect(replacement.claims.ticketId).not.toBe(owner.claims.ticketId);
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.latestSyncSnapshot).toBeUndefined();
    });
  });

  it("rejects partial and cross-book controller snapshots without persisting them", async () => {
    const sessionId = `apple-snapshot-validation-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const frame = {
      v: 1,
      t: "snapshot",
      format: "epub",
      bookId: "book-1",
      contentHash: CONTENT_HASH,
      position: { format: "epub", cfi: "epubcfi(/6/2)" },
      isPlaying: false,
      ttsRate: 1,
      roomEpoch: 1,
      controllerGeneration: 1,
      sequence: 1,
      source: "controller",
    };
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const server = ctx.getWebSockets()[0];
      await (_instance as any).webSocketMessage(server, JSON.stringify({
        v: 1,
        t: "sync.frame",
        frame: (() => { const partial = { ...frame } as Record<string, unknown>; delete partial.ttsRate; return partial; })(),
      }));
      await (_instance as any).webSocketMessage(server, JSON.stringify({
        v: 1,
        t: "sync.frame",
        frame: { ...frame, sequence: 2, bookId: "book-2" },
      }));
      await (_instance as any).webSocketMessage(server, JSON.stringify({
        v: 1,
        t: "sync.frame",
        frame: { ...frame, sequence: 3, contentHash: "b".repeat(64) },
      }));

      expect((await ctx.storage.get<any>("apple-state")).latestSyncSnapshot).toBeUndefined();
    });
  });

  it("replays one persisted snapshot only when all controller fences still match", async () => {
    const sessionId = `apple-snapshot-replay-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    const frame = {
      v: 1, t: "snapshot", format: "epub", bookId: "book-1", contentHash: CONTENT_HASH,
      position: { format: "epub", cfi: "epubcfi(/6/2)" }, isPlaying: false, ttsRate: 1,
      roomEpoch: 1, controllerGeneration: 1, sequence: 4, source: "controller",
    };
    await runInDurableObject(stub, async (_instance, ctx) => {
      const server = ctx.getWebSockets()[0];
      await (_instance as any).webSocketMessage(server, JSON.stringify({ v: 1, t: "sync.frame", frame }));
      expect((await ctx.storage.get<any>("apple-state")).latestSyncSnapshot.frame).toMatchObject(frame);
    });

    const reader = await issueTicket(sessionId, "u_reader");
    const socket = await openSocket(sessionId, "u_reader", reader.admissionTicket, false);
    const replay = nextAppleMessage(socket, (message) => message.t === "sync.frame" && message.frame.sequence === 4);
    socket.accept();
    await expect(replay).resolves.toMatchObject({
      from: "u_owner",
      roomEpoch: 1,
      controllerGeneration: 1,
      frame,
    });
  });

  it("bounds observation history, honors a cursor, and fails closed after removal and retention expiry", async () => {
    const sessionId = `apple-observation-retention-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    const member = await issueTicket(sessionId, "u_member");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    await openSocket(sessionId, "u_member", member.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.observations = Array.from({ length: 100 }, (_, index) => ({
        observationId: `observation-${index + 1}`, eventId: `event-${index + 1}`,
        eventType: "sync", roomEpoch: 1, controllerGeneration: 1, connectionGeneration: 1,
        readerSequence: index + 1, occurredAt: index + 1,
      }));
      await ctx.storage.put("apple-state", state);
    });

    const page = await command(sessionId, "getMemberObservations", { sessionId, requestingUserId: "u_member", afterObservationId: "observation-98" });
    expect(page.status).toBe(200);
    expect((await page.json() as { observations: Array<{ observationId: string }> }).observations.map((item) => item.observationId))
      .toEqual(["observation-99", "observation-100"]);

    const removed = await command(sessionId, "removeParticipant", { actingUserId: "u_owner", userId: "u_member", expectedControllerGeneration: 1 });
    expect(removed.status).toBe(200);
    const denied = await command(sessionId, "getMemberObservations", { sessionId, requestingUserId: "u_member" });
    expect(denied.status).toBe(403);

    const ended = await command(sessionId, "endRoom", { actingUserId: "u_owner", expectedControllerGeneration: 1 });
    expect(ended.status).toBe(200);
    await runInDurableObject(stub, async (_instance) => { await (_instance as any).alarm(); });
    const expired = await command(sessionId, "getMemberObservations", { sessionId, requestingUserId: "u_owner" });
    expect(expired.status).toBe(404);
  });

  it("counts a reconnecting seat reservation toward capacity while allowing its member to rejoin", async () => {
    const sessionId = `apple-reserved-seat-${crypto.randomUUID()}`;
    await createRoom(sessionId, 1);
    const first = await issueTicket(sessionId, "u_reader");
    await openSocket(sessionId, "u_reader", first.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const server = ctx.getWebSockets()[0];
      await (_instance as any).webSocketClose(server, 4000);
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.seatReservations.u_reader).toMatchObject({ connectionGeneration: 1 });
    });

    const blocked = await command(sessionId, "issueAdmissionTicket", {
      sessionId, inviteId: "invite-other", userId: "u_other", contentHash: CONTENT_HASH,
      profile: { displayName: "Other" },
    });
    expect(blocked.status).toBe(409);
    await blocked.json();

    const rejoin = await issueTicket(sessionId, "u_reader");
    await expect(openSocket(sessionId, "u_reader", rejoin.admissionTicket)).resolves.toBeInstanceOf(WebSocket);
  });

  it("re-elects and broadcasts authority fences when the provisional controller lease expires", async () => {
    const sessionId = `apple-controller-lease-expiry-${crypto.randomUUID()}`;
    await createRoom(sessionId, 2);
    const owner = await issueTicket(sessionId, "u_owner");
    const ownerSocket = await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const provisional = await issueTicket(sessionId, "u_controller");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    const transfer = nextAppleMessage(ownerSocket, (message) => message.t === "controller.transfer" && message.toUserId === "u_owner" && message.controllerGeneration === 3);

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.controllerUserId = "u_controller";
      state.controllerGeneration = 2;
      state.roomEpoch = 2;
      state.latestSyncSnapshot = { stale: true };
      state.pendingAdmissionLeases[provisional.claims.ticketId].expiresAt = Date.now() - 1;
      await ctx.storage.put("apple-state", state);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.status).toBe("waiting");
      expect(after.participants.u_controller).toBeUndefined();
      expect(after.controllerUserId).toBe("u_owner");
      expect(after.controllerGeneration).toBe(3);
      expect(after.roomEpoch).toBe(3);
      expect(after.latestSyncSnapshot).toBeUndefined();
    });

    await expect(transfer).resolves.toMatchObject({ roomEpoch: 3, controllerGeneration: 3 });
  });

  it("removes every pending admission lease for a removed participant immediately", async () => {
    const sessionId = `apple-remove-lease-${crypto.randomUUID()}`;
    await createRoom(sessionId, 2);
    const owner = await issueTicket(sessionId, "u_owner");
    const member = await issueTicket(sessionId, "u_member");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    await openSocket(sessionId, "u_member", member.admissionTicket);
    const replacement = await issueTicket(sessionId, "u_member");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    const removed = await command(sessionId, "removeParticipant", {
      actingUserId: "u_owner", userId: "u_member", expectedControllerGeneration: 1,
    });
    expect(removed.status).toBe(200);
    await removed.json();
    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      expect(state.pendingAdmissionLeases[replacement.claims.ticketId]).toBeUndefined();
      expect(Object.values(state.pendingAdmissionLeases).filter((lease: any) => lease.userId === "u_member")).toEqual([]);
    });

    await expect(command(sessionId, "issueAdmissionTicket", {
      sessionId, inviteId: "invite-replacement", userId: "u_replacement", contentHash: CONTENT_HASH,
      profile: { displayName: "Replacement" },
    })).resolves.toMatchObject({ status: 200 });
  });

  it("rejects a queued controller frame after end without recreating a snapshot", async () => {
    const sessionId = `apple-ended-frame-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const owner = await issueTicket(sessionId, "u_owner");
    await openSocket(sessionId, "u_owner", owner.admissionTicket);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));
    const frame = {
      v: 1, t: "snapshot", format: "epub", bookId: "book-1", contentHash: CONTENT_HASH,
      position: { format: "epub", cfi: "epubcfi(/6/2)" }, isPlaying: false, ttsRate: 1,
      roomEpoch: 2, controllerGeneration: 1, sequence: 1, source: "controller",
    };

    await runInDurableObject(stub, async (_instance, ctx) => {
      const server = ctx.getWebSockets()[0];
      await (_instance as any).endRoom({ actingUserId: "u_owner", expectedControllerGeneration: 1 });
      await (_instance as any).webSocketMessage(server, JSON.stringify({ v: 1, t: "sync.frame", frame }));
      const after = await ctx.storage.get<any>("apple-state");
      expect(after.status).toBe("ended");
      expect(after.latestSyncSnapshot).toBeUndefined();
    });
  });

  it("infers legacy occupancy from persisted reconnecting participants and reservations", async () => {
    const sessionId = `apple-legacy-occupancy-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const pending = await issueTicket(sessionId, "u_legacy");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      const participant = state.participants.u_legacy;
      delete state.pendingAdmissionLeases[pending.claims.ticketId];
      participant.connectionState = "reconnecting";
      participant.reservedUntil = Date.now() + 60_000;
      state.seatReservations.u_legacy = {
        reservedUntil: participant.reservedUntil,
        connectionGeneration: participant.connectionGeneration,
      };
      state.lastEmptyAt = Date.now() - (2 * 60_000) - 1;
      state.startupExpiresAt = Date.now() + 60 * 60_000;
      delete state.hasEverBeenOccupied;
      await ctx.storage.put("apple-state", state);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.hasEverBeenOccupied).toBe(true);
      expect(after.status).toBe("ended");
    });
  });

  it("infers legacy occupancy from a departed consumed admission ticket", async () => {
    const sessionId = `apple-legacy-consumed-ticket-occupancy-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const issued = await issueTicket(sessionId, "u_departed");
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.participants = {};
      state.seatReservations = {};
      state.pendingAdmissionLeases = {};
      state.consumedAdmissionTicketIds = { [issued.claims.ticketId]: Date.now() + 60_000 };
      state.latestSyncSnapshot = undefined;
      state.lastEmptyAt = Date.now() - (2 * 60_000) - 1;
      state.startupExpiresAt = Date.now() + 60 * 60_000;
      delete state.hasEverBeenOccupied;
      await ctx.storage.put("apple-state", state);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.hasEverBeenOccupied).toBe(true);
      expect(after.status).toBe("ended");
    });
  });

  it("infers legacy occupancy from a persisted authoritative snapshot", async () => {
    const sessionId = `apple-legacy-snapshot-occupancy-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.participants = {};
      state.seatReservations = {};
      state.pendingAdmissionLeases = {};
      state.consumedAdmissionTicketIds = {};
      state.latestSyncSnapshot = {
        sessionId,
        roomEpoch: state.roomEpoch,
        controllerGeneration: state.controllerGeneration,
        connectionGeneration: 1,
        controllerUserId: "u_owner",
        sequence: 1,
        frame: {
          v: 1,
          t: "snapshot",
          format: "epub",
          bookId: "book-1",
          contentHash: CONTENT_HASH,
          position: { format: "epub", cfi: "epubcfi(/6/2)" },
          isPlaying: false,
          ttsRate: 1,
          roomEpoch: state.roomEpoch,
          controllerGeneration: state.controllerGeneration,
          sequence: 1,
          source: "controller",
        },
      };
      state.lastEmptyAt = Date.now() - (2 * 60_000) - 1;
      state.startupExpiresAt = Date.now() + 60 * 60_000;
      delete state.hasEverBeenOccupied;
      await ctx.storage.put("apple-state", state);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.hasEverBeenOccupied).toBe(true);
      expect(after.status).toBe("ended");
    });
  });

  it("keeps never-occupied legacy state on startup expiry", async () => {
    const sessionId = `apple-legacy-never-occupied-${crypto.randomUUID()}`;
    await createRoom(sessionId);
    const namespace = (env as { APPLE_SESSION_ROOM: DurableObjectNamespace }).APPLE_SESSION_ROOM;
    const stub = namespace.get(namespace.idFromName(sessionId));

    await runInDurableObject(stub, async (_instance, ctx) => {
      const state = await ctx.storage.get<any>("apple-state");
      state.participants = {};
      state.seatReservations = {};
      state.pendingAdmissionLeases = {};
      state.consumedAdmissionTicketIds = {};
      state.latestSyncSnapshot = undefined;
      state.lastEmptyAt = undefined;
      state.startupExpiresAt = Date.now() - 1;
      delete state.hasEverBeenOccupied;
      await ctx.storage.put("apple-state", state);
      await (_instance as any).alarm();

      const after = await ctx.storage.get<any>("apple-state");
      expect(after.hasEverBeenOccupied).toBe(false);
      expect(after.status).toBe("ended");
    });
  });
});
