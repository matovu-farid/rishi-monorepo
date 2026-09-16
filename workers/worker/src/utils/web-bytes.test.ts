import { describe, expect, it } from "vitest";

async function loadWebBytes() {
  try {
    return await import("./web-bytes");
  } catch {
    return { webBytes: undefined };
  }
}

describe("webBytes", () => {
  it("copies ArrayBufferLike bytes into an ArrayBuffer-backed view", async () => {
    const { webBytes } = await loadWebBytes();

    expect(webBytes).toBeTypeOf("function");
    if (!webBytes) return;

    const input = Uint8Array.from([1, 2, 3]);
    const output = webBytes(input);

    expect(output).toEqual(input);
    expect(output.buffer).toBeInstanceOf(ArrayBuffer);
    expect(output).not.toBe(input);
  });
});
