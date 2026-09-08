import { SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { sign } from "../src/hmac";

const SECRET = "test-secret-do-not-use-in-prod";
const CONTENT_HASH = "a".repeat(64);

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_legacy_owner", email: "legacy@example.com", displayName: "Legacy Owner" });
});

describe("versioned Apple sharing transport", () => {
  it("keeps v1 and v2 rooms isolated even when their ids match", async () => {
    const legacyResponse = await SELF.fetch("https://example.com/v1/sessions", {
      method: "POST",
      headers: {
        authorization: "Bearer legacy-owner",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        bookContext: { bookId: "legacy-book", contentHash: CONTENT_HASH, format: "epub" },
        requiresApproval: false,
      }),
    });
    expect(legacyResponse.status).toBe(200);
    const legacy = await legacyResponse.json() as { sessionId: string };

    const path = `/v2/internal/rooms/${legacy.sessionId}`;
    const body = {
      action: "createRoom",
      payload: {
        sessionId: legacy.sessionId,
        initialSharerUserId: "u_apple_owner",
        bookContext: { bookId: "apple-book", contentHash: CONTENT_HASH, format: "epub" },
        maxParticipants: 5,
      },
    };
    const token = await sign({
      method: "POST",
      path,
      body,
      exp: Date.now() + 60_000,
    }, SECRET);

    const appleResponse = await SELF.fetch(`https://example.com${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-rishi-internal-token": token,
      },
      body: JSON.stringify(body),
    });

    expect(appleResponse.status).toBe(200);
    expect(await appleResponse.json()).toMatchObject({
      sessionId: legacy.sessionId,
      roomEpoch: 1,
      controllerGeneration: 1,
    });
  });

  it("routes v2 internal room commands to AppleSessionRoom", async () => {
    const sessionId = `apple-${crypto.randomUUID()}`;
    const path = `/v2/internal/rooms/${sessionId}`;
    const body = {
      action: "createRoom",
      payload: {
        sessionId,
        initialSharerUserId: "u_owner",
        bookContext: { bookId: "book-1", contentHash: CONTENT_HASH, format: "epub" },
        maxParticipants: 5,
      },
    };
    const token = await sign({
      method: "POST",
      path,
      body,
      exp: Date.now() + 60_000,
    }, SECRET);

    const response = await SELF.fetch(`https://example.com${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-rishi-internal-token": token,
      },
      body: JSON.stringify(body),
    });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({
      sessionId,
      roomEpoch: 1,
      controllerGeneration: 1,
    });
  });

  it("does not expose the Apple command surface under the legacy v1 path", async () => {
    const response = await SELF.fetch("https://example.com/v1/internal/rooms/legacy-room", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ action: "createRoom", payload: {} }),
    });

    expect(response.status).toBe(404);
  });
});
