import { SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { sign } from "../src/hmac";
import { verifyAuthToken } from "../src/auth";

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

  it("[W4-005] maps an active Apple purge conflict to HTTP 409 and preserves the result envelope", async () => {
    const sessionId = `apple-purge-${crypto.randomUUID()}`;
    const command = async (action: string, payload: Record<string, unknown>) => {
      const path = `/v2/internal/rooms/${sessionId}`;
      const body = { action, payload };
      const token = await sign({ method: "POST", path, body, exp: Date.now() + 60_000 }, SECRET);
      return SELF.fetch(`https://example.com${path}`, {
        method: "POST",
        headers: { "content-type": "application/json", "x-rishi-internal-token": token },
        body: JSON.stringify(body),
      });
    };

    const created = await command("createRoom", {
      sessionId,
      initialSharerUserId: "u_owner",
      bookContext: { bookId: "book-1", contentHash: CONTENT_HASH, format: "epub" },
      maxParticipants: 5,
    });
    expect(created.status).toBe(200);

    const premature = await command("purgeAppleRoom", {});
    expect(premature.status).toBe(409);
    expect(await premature.json()).toEqual({
      ok: false,
      code: "CONFLICT",
      error: "room must be ended before purge",
    });

    const ended = await command("endRoom", { actingUserId: "u_owner", expectedControllerGeneration: 1 });
    expect(ended.status).toBe(200);
    const purged = await command("purgeAppleRoom", {});
    expect(purged.status).toBe(200);
    expect(await purged.json()).toEqual({ ok: true });
  });

  it("does not expose the Apple command surface under the legacy v1 path", async () => {
    const response = await SELF.fetch("https://example.com/v1/internal/rooms/legacy-room", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ action: "createRoom", payload: {} }),
    });

    expect(response.status).toBe(404);
  });

  it("uses api.fidexa.org as the canonical production auth authority", async () => {
    const requestedUrls: string[] = [];
    const fetcher: typeof fetch = async (input) => {
      requestedUrls.push(String(input));
      return new Response(JSON.stringify({
        user: { id: "u_auth", email: "auth@example.com", name: "Authenticated" },
      }), { status: 200 });
    };

    await expect(verifyAuthToken("production-bearer", {
      AUTH_BASE_URL: "https://api.fidexa.org",
      fetcher,
    })).resolves.toMatchObject({ userId: "u_auth" });

    expect(requestedUrls).toEqual([
      "https://api.fidexa.org/api/auth/get-session",
    ]);
    expect(requestedUrls).not.toContain(
      "https://rishi.fidexa.org/api/auth/get-session",
    );
  });
});
