import { SELF } from "cloudflare:test";
import { describe, expect, it, vi, beforeEach } from "vitest";
import { resolveTestBearer } from "../src/SessionRoom";

/**
 * Regression: the WebSocket upgrade path in `SessionRoom.fetch()` must gate
 * the `userId--DisplayName` test-bearer shortcut behind
 * `env.TEST_AUTH_ALLOWED === "1"`. Without that gate, a public client could
 * present `jwt.<base64url("alice--Alice")>` as a Sec-WebSocket-Protocol
 * value and be admitted as `alice` without any auth check.
 *
 * The gateway (`auth.ts:verifyAuth`) already gates the same shortcut, but
 * the DO's own fetch handler historically duplicated the regex match
 * without the env gate — see CRITICAL review finding on PR #253.
 *
 * `resolveTestBearer` encapsulates the gating decision so we can unit-test
 * it independently of the miniflare runtime env (which the test pool
 * loads once at startup from `vitest.config.ts`).
 */

beforeEach(() => {
  vi.stubGlobal("__TEST_AUTH__", { userId: "u_host", email: "h@x.y", displayName: "Host" });
});

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

describe("resolveTestBearer gate", () => {
  it("returns null when TEST_AUTH_ALLOWED is unset (production)", () => {
    expect(resolveTestBearer("u_attacker--Attacker", undefined)).toBeNull();
  });

  it("returns null when TEST_AUTH_ALLOWED is anything other than '1'", () => {
    expect(resolveTestBearer("u_attacker--Attacker", "0")).toBeNull();
    expect(resolveTestBearer("u_attacker--Attacker", "true")).toBeNull();
    expect(resolveTestBearer("u_attacker--Attacker", "")).toBeNull();
  });

  it("returns null on a non-shortcut bearer even when flag is set", () => {
    expect(resolveTestBearer("eyJalg...", "1")).toBeNull();
    expect(resolveTestBearer("nodashes", "1")).toBeNull();
  });

  it("decodes userId--Name (underscore = space) when flag is '1'", () => {
    expect(resolveTestBearer("u_42--Alice_Q", "1")).toEqual({
      userId: "u_42",
      displayName: "Alice Q",
    });
  });

  it("supports hyphenated userIds before the `--` separator", () => {
    // The shortcut uses `--` to separate userId from display name; the
    // userId itself may contain single hyphens (e.g. e2e-host).
    expect(resolveTestBearer("e2e-host--E2E_Host", "1")).toEqual({
      userId: "e2e-host",
      displayName: "E2E Host",
    });
  });
});

describe("WS upgrade integration (TEST_AUTH_ALLOWED='1' baseline)", () => {
  it("accepts userId--Name bearer with 101 in the test pool", async () => {
    // Sanity: vitest.config.ts sets TEST_AUTH_ALLOWED='1' so this MUST
    // succeed. The negative case (flag unset → 401) is exercised by the
    // `resolveTestBearer` unit tests above, since the test pool's env
    // bindings are fixed at miniflare startup and cannot be flipped per
    // test without restarting the runtime.
    const r = await SELF.fetch("https://x/v1/sessions", {
      method: "POST",
      headers: {
        authorization: "Bearer u_host--Host",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        bookContext: { bookId: "b", contentHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", format: "epub" },
        requiresApproval: false,
      }),
    });
    const created = (await r.json()) as { sessionId: string; wsUrl: string };
    const httpUrl = created.wsUrl
      .replace(/^wss:\/\//, "https://")
      .replace(/^ws:\/\//, "http://");
    const upgraded = await SELF.fetch(httpUrl, {
      headers: {
        upgrade: "websocket",
        "sec-websocket-protocol": ["rishi.sharing.v1", `jwt.${b64url("u_host--Host")}`].join(", "),
      },
    });
    expect(upgraded.status).toBe(101);
  });
});
