import { describe, expect, it } from "vitest";

import {
  SHARE_EXPIRY_MS,
  createShareToken,
  createShareTokenFromSecret,
  hashShareToken,
  shareExpiry,
} from "./shareTokens";

describe("share tokens", () => {
  it("creates a URL-safe token with a one-week expiry", async () => {
    const token = createShareToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]+$/);
    expect(token.length).toBeGreaterThanOrEqual(40);
    expect(shareExpiry(1000).getTime()).toBe(1000 + SHARE_EXPIRY_MS);
    expect(await hashShareToken(token)).not.toBe(token);
  });

  it("hashes the same token deterministically", async () => {
    const first = await hashShareToken("share-token");
    const second = await hashShareToken("share-token");
    expect(first).toBe(second);
    expect(first).not.toBe(await hashShareToken("other-token"));
  });

  it("derives the same unguessable token for an idempotent request", async () => {
    const first = await createShareTokenFromSecret("secret", "user", "request");
    const second = await createShareTokenFromSecret("secret", "user", "request");
    expect(first).toBe(second);
    expect(first).not.toBe(await createShareTokenFromSecret("secret", "user", "other"));
    expect(first).not.toBe(await createShareTokenFromSecret("other", "user", "request"));
  });
});
