import { describe, expect, it, vi } from "vitest";

import {
  SessionSharingService,
  SessionSharingServiceError,
  signInternalToken,
} from "./session-sharing-service";

function decodeBase64Url(segment: string): string {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((segment.length + 3) % 4);
  return atob(padded);
}

describe("session-sharing-service", () => {
  it("mints the same JWT-shaped internal token envelope as the sharing worker", async () => {
    const token = await signInternalToken("shared-secret", {
      method: "POST",
      path: "/internal/rooms/session-123",
      body: {
        action: "createRoom",
        payload: { sessionId: "session-123", initialSharerUserId: "user-1" },
      },
      exp: 1234,
    });

    const parts = token.split(".");
    expect(parts).toHaveLength(3);
    expect(JSON.parse(decodeBase64Url(parts[0]!))).toEqual({ alg: "HS256", typ: "JWT" });
    expect(JSON.parse(decodeBase64Url(parts[1]!))).toEqual({
      method: "POST",
      path: "/internal/rooms/session-123",
      body: {
        action: "createRoom",
        payload: { sessionId: "session-123", initialSharerUserId: "user-1" },
      },
      exp: 1234,
    });
  });

  it("signs requests and maps non-2xx service responses to stable errors", async () => {
    const fetchSpy = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toContain("/internal/rooms/session-123");
      expect(init?.method).toBe("POST");
      expect(init?.headers).toMatchObject({
        "content-type": "application/json",
        "x-rishi-internal-token": expect.any(String),
      });
      expect(JSON.parse(String(init?.body))).toEqual({
        action: "createRoom",
        payload: {
          sessionId: "session-123",
          initialSharerUserId: "user-1",
          bookContext: { contentHash: "hash-1", format: "epub" },
        },
      });
      return new Response(JSON.stringify({ code: "ROOM_FULL", error: "room full" }), {
        status: 409,
        headers: { "content-type": "application/json" },
      });
    });

    const service = new SessionSharingService(
      { fetch: fetchSpy },
      {
        internalTokenSecret: "shared-secret",
        now: () => 1_000,
      },
    );

    await expect(
      service.createRoom({
        sessionId: "session-123",
        initialSharerUserId: "user-1",
        bookContext: { contentHash: "hash-1", format: "epub" },
      }),
    ).rejects.toMatchObject({
      name: "SessionSharingServiceError",
      code: "ROOM_FULL",
      status: 409,
      responseCode: "ROOM_FULL",
      message: "room full",
    });

    expect(fetchSpy).toHaveBeenCalledTimes(1);
    const header = fetchSpy.mock.calls[0]?.[1]?.headers as Record<string, string> | undefined;
    expect(header?.["x-rishi-internal-token"]).toBeTypeOf("string");
  });

  it("signs a v2 createRoom request with a path-matching sessionId payload", async () => {
    const expectedBody = {
      action: "createRoom",
      payload: {
        sessionId: "session-123",
        initialSharerUserId: "user-1",
        bookContext: { contentHash: "hash-1", format: "epub" },
        maxParticipants: 5,
      },
    };
    const fetchSpy = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input)).pathname;
      const body = JSON.parse(String(init?.body));
      const token = new Headers(init?.headers).get("x-rishi-internal-token")!;
      const claims = JSON.parse(decodeBase64Url(token.split(".")[1]!));

      expect({ method: init?.method, path, body }).toEqual({
        method: "POST",
        path: "/v2/internal/rooms/session-123",
        body: expectedBody,
      });
      expect(body.payload.sessionId).toBe(path.split("/").at(-1));
      expect(claims).toEqual({ method: "POST", path, body, exp: 61_000 });

      return new Response(JSON.stringify({ sessionId: "session-123", roomEpoch: 1, controllerGeneration: 1 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    const service = new SessionSharingService(
      { fetch: fetchSpy },
      { internalTokenSecret: "shared-secret", internalPathPrefix: "/v2/internal", now: () => 1_000 },
    );

    await expect(service.createRoom({
      sessionId: "session-123",
      initialSharerUserId: "user-1",
      bookContext: { contentHash: "hash-1", format: "epub" },
      maxParticipants: 5,
    })).resolves.toEqual({ sessionId: "session-123", roomEpoch: 1, controllerGeneration: 1 });
  });

  it("supports a separately versioned internal route without changing the legacy default", async () => {
    const fetchSpy = vi.fn(async (input: RequestInfo | URL) => {
      expect(String(input)).toBe("https://sharing-worker.internal/v2/internal/rooms/session-123");
      return new Response(JSON.stringify({ sessionId: "session-123", roomEpoch: 1, controllerGeneration: 1 }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });

    const service = new SessionSharingService(
      { fetch: fetchSpy },
      {
        internalTokenSecret: "shared-secret",
        internalPathPrefix: "/v2/internal",
        now: () => 1_000,
      },
    );

    await expect(service.createRoom({
      sessionId: "session-123",
      initialSharerUserId: "user-1",
      bookContext: { contentHash: "hash-1", format: "epub" },
    })).resolves.toEqual({ sessionId: "session-123", roomEpoch: 1, controllerGeneration: 1 });
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("uses the v2 purge command for an already-ended Apple room", async () => {
    const fetchSpy = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      expect(String(input)).toBe("https://sharing-worker.internal/v2/internal/rooms/session-123");
      expect(JSON.parse(String(init?.body))).toEqual({ action: "purgeAppleRoom", payload: {} });
      return new Response(JSON.stringify({ ok: true }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    });
    const service = new SessionSharingService(
      { fetch: fetchSpy },
      { internalTokenSecret: "shared-secret", internalPathPrefix: "/v2/internal", now: () => 1_000 },
    );

    await expect(service.purgeAppleRoom({ sessionId: "session-123" })).resolves.toBeUndefined();
  });

  it("exposes a stable error class for local transport failures", async () => {
    const service = new SessionSharingService(
      {
        fetch: vi.fn(async () => {
          throw new TypeError("network down");
        }),
      },
      {
        internalTokenSecret: "shared-secret",
        now: () => 1_000,
      },
    );

    await expect(
      service.getRoomStatus({ sessionId: "session-123" }),
    ).rejects.toBeInstanceOf(SessionSharingServiceError);
  });
});
