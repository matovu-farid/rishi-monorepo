import { describe, expect, it } from "vitest";
import { resolveCorsOrigin } from "./cors-origin";

describe("Worker CORS origin policy", () => {
  it("preserves explicit web and native origins", () => {
    expect(resolveCorsOrigin("https://rishi.fidexa.org")).toBe("https://rishi.fidexa.org");
    expect(resolveCorsOrigin("tauri://localhost")).toBe("tauri://localhost");
    expect(resolveCorsOrigin("rishi-electron://")).toBe("rishi-electron://");
  });

  it("allows Electron loopback renderer ports", () => {
    expect(resolveCorsOrigin("http://127.0.0.1:47823")).toBe("http://127.0.0.1:47823");
    expect(resolveCorsOrigin("http://localhost:54321")).toBe("http://localhost:54321");
  });

  it("rejects unrelated or malformed origins", () => {
    expect(resolveCorsOrigin("https://evil.example")).toBeUndefined();
    expect(resolveCorsOrigin("http://127.0.0.1")).toBeUndefined();
    expect(resolveCorsOrigin("http://127.0.0.1:99999")).toBeUndefined();
    expect(resolveCorsOrigin("http://127.0.0.1.evil.example:47823")).toBeUndefined();
    expect(resolveCorsOrigin("file://local")).toBeUndefined();
  });
});
