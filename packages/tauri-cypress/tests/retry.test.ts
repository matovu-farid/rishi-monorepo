import { describe, it, expect, vi } from "vitest";
import { retry } from "../src/retry.js";

describe("retry", () => {
  it("resolves immediately if function succeeds", async () => {
    const fn = vi.fn(() => "ok");
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(1);
  });

  it("retries until function succeeds", async () => {
    let calls = 0;
    const fn = vi.fn(() => {
      calls++;
      if (calls < 3) throw new Error("not yet");
      return "ok";
    });
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe("ok");
    expect(fn).toHaveBeenCalledTimes(3);
  });

  it("throws after timeout if function never succeeds", async () => {
    const fn = vi.fn(() => {
      throw new Error("always fails");
    });
    await expect(
      retry(fn, { timeout: 100, interval: 10 })
    ).rejects.toThrow("always fails");
  });

  it("returns last error message on timeout", async () => {
    let count = 0;
    const fn = vi.fn(() => {
      count++;
      throw new Error(`fail #${count}`);
    });
    await expect(
      retry(fn, { timeout: 80, interval: 10 })
    ).rejects.toThrow(/fail #/);
  });

  it("supports async functions", async () => {
    let calls = 0;
    const fn = vi.fn(async () => {
      calls++;
      if (calls < 2) throw new Error("not yet");
      return 42;
    });
    const result = await retry(fn, { timeout: 1000, interval: 10 });
    expect(result).toBe(42);
  });
});
