import { describe, it, expect } from "vitest";
import { detectOs } from "./detect-os";

function headers(entries: Record<string, string>): Headers {
  return new Headers(entries);
}

describe("detectOs", () => {
  it("detects macOS from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"macOS"' }))).toBe("mac");
  });

  it("detects Windows from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"Windows"' }))).toBe("windows");
  });

  it("detects Linux from sec-ch-ua-platform", () => {
    expect(detectOs(headers({ "sec-ch-ua-platform": '"Linux"' }))).toBe("linux");
  });

  it("detects mobile via user-agent even when sec-ch-ua-platform says Android", () => {
    expect(
      detectOs(
        headers({
          "sec-ch-ua-platform": '"Android"',
          "user-agent":
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("mobile");
  });

  it("detects mobile from iPhone UA", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605",
        }),
      ),
    ).toBe("mobile");
  });

  it("detects mobile from iPad UA", () => {
    expect(
      detectOs(
        headers({
          "user-agent": "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605",
        }),
      ),
    ).toBe("mobile");
  });

  it("falls back to UA parsing when sec-ch-ua-platform is absent — macOS", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605 Safari/605",
        }),
      ),
    ).toBe("mac");
  });

  it("falls back to UA parsing — Windows", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("windows");
  });

  it("falls back to UA parsing — Linux", () => {
    expect(
      detectOs(
        headers({
          "user-agent":
            "Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120",
        }),
      ),
    ).toBe("linux");
  });

  it("returns unknown for empty headers", () => {
    expect(detectOs(headers({}))).toBe("unknown");
  });

  it("returns unknown for unrecognized UA", () => {
    expect(detectOs(headers({ "user-agent": "Weirdbot/1.0" }))).toBe("unknown");
  });

  it("prefers sec-ch-ua-platform over UA for desktop classification", () => {
    // UA says Windows, CH says macOS — CH should win
    expect(
      detectOs(
        headers({
          "sec-ch-ua-platform": '"macOS"',
          "user-agent":
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120",
        }),
      ),
    ).toBe("mac");
  });
});
