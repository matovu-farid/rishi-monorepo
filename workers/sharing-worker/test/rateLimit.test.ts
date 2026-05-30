import { describe, expect, it } from "vitest";
import { RateBucket } from "../src/rateLimit";

describe("RateBucket", () => {
  it("allows up to N then denies", () => {
    const b = new RateBucket({ capacity: 3, refillPerSec: 0 });
    expect(b.tryConsume()).toBe(true);
    expect(b.tryConsume()).toBe(true);
    expect(b.tryConsume()).toBe(true);
    expect(b.tryConsume()).toBe(false);
  });
  it("refills over time", () => {
    const b = new RateBucket({ capacity: 1, refillPerSec: 1 });
    expect(b.tryConsume()).toBe(true);
    expect(b.tryConsume()).toBe(false);
    expect(b.tryConsume(Date.now() + 1100)).toBe(true);
  });
});
