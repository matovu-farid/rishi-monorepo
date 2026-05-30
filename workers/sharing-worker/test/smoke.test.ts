import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("worker boot", () => {
  it("responds 200 on /health", async () => {
    const res = await SELF.fetch("https://example.com/health");
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  it("404s unknown routes", async () => {
    const res = await SELF.fetch("https://example.com/nope");
    expect(res.status).toBe(404);
  });
});
