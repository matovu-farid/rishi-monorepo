import { describe, expect, it } from "vitest";
import { decryptSiwaRefreshToken, encryptSiwaRefreshToken } from "./siwa-token-crypto";

describe("Sign in with Apple refresh-token encryption", () => {
  it("round-trips a token without exposing plaintext in the stored fields", async () => {
    const encrypted = await encryptSiwaRefreshToken("refresh-token-value", "test-secret");

    expect(encrypted.ciphertext).not.toContain("refresh-token-value");
    expect(await decryptSiwaRefreshToken(encrypted, "test-secret")).toBe("refresh-token-value");
  });

  it("rejects tampered ciphertext", async () => {
    const encrypted = await encryptSiwaRefreshToken("refresh-token-value", "test-secret");
    const tampered = { ...encrypted, ciphertext: `${encrypted.ciphertext.slice(0, -2)}AA` };

    await expect(decryptSiwaRefreshToken(tampered, "test-secret")).rejects.toThrow();
  });
});
