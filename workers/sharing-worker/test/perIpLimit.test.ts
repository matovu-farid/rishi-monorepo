import { describe, expect, it } from "vitest";
import { GlobalLimiter } from "../src/perIpLimit";

describe("GlobalLimiter", () => {
  it("denies after N for the same key in window", () => {
    const g = new GlobalLimiter({ capacity: 2, windowMs: 60_000 });
    expect(g.allow("k")).toBe(true);
    expect(g.allow("k")).toBe(true);
    expect(g.allow("k")).toBe(false);
    expect(g.allow("other")).toBe(true);
  });

  it("resets after windowMs elapses", () => {
    const g = new GlobalLimiter({ capacity: 1, windowMs: 1_000 });
    const t0 = 1_000_000;
    expect(g.allow("k", t0)).toBe(true);
    expect(g.allow("k", t0 + 500)).toBe(false);
    expect(g.allow("k", t0 + 2_000)).toBe(true);
  });
});
