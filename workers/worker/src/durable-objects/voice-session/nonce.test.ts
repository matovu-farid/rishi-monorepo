import { describe, expect, it, vi } from "vitest";

function expectArrayBufferBacked(value: unknown): void {
  expect(ArrayBuffer.isView(value)).toBe(true);
  if (ArrayBuffer.isView(value)) {
    expect(value.buffer).toBeInstanceOf(ArrayBuffer);
  }
}

class SharedBufferTextEncoder {
  encode(value: string): Uint8Array<ArrayBufferLike> {
    const bytes = new Uint8Array(new SharedArrayBuffer(value.length));
    for (let index = 0; index < value.length; index += 1) {
      bytes[index] = value.charCodeAt(index);
    }
    return bytes;
  }
}

describe("voice registration nonce Web Crypto boundaries", () => {
  it("copies nonce messages before every crypto operation", async () => {
    vi.resetModules();
    vi.stubGlobal("TextEncoder", SharedBufferTextEncoder);

    const originalImportKey = crypto.subtle.importKey.bind(crypto.subtle);
    const originalSign = crypto.subtle.sign.bind(crypto.subtle);
    const originalVerify = crypto.subtle.verify.bind(crypto.subtle);
    const importKeySpy = vi
      .spyOn(crypto.subtle, "importKey")
      .mockImplementation(async (...args) => {
        expectArrayBufferBacked(args[1]);
        return originalImportKey(...args);
      });
    const signSpy = vi
      .spyOn(crypto.subtle, "sign")
      .mockImplementation(async (...args) => {
        expectArrayBufferBacked(args[2]);
        return originalSign(...args);
      });
    const verifySpy = vi
      .spyOn(crypto.subtle, "verify")
      .mockImplementation(async (...args) => {
        expectArrayBufferBacked(args[2]);
        expectArrayBufferBacked(args[3]);
        return originalVerify(...args);
      });

    try {
      const { mintRegistrationNonce, verifyRegistrationNonce } = await import(
        "./nonce"
      );
      const minted = await mintRegistrationNonce(
        "session-1",
        "user-1",
        "secret",
        1_700_000_000_000,
      );

      await expect(
        verifyRegistrationNonce(
          minted.nonce,
          "session-1",
          "user-1",
          "secret",
          minted,
        ),
      ).resolves.toBe(true);
      expect(importKeySpy).toHaveBeenCalledTimes(2);
      expect(signSpy).toHaveBeenCalledTimes(1);
      expect(verifySpy).toHaveBeenCalledTimes(1);
    } finally {
      vi.restoreAllMocks();
      vi.unstubAllGlobals();
    }
  });
});
