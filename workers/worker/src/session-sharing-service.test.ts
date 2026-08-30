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
