import { describe, test, expect, vi, beforeEach, afterEach } from "vitest";
import {
  reportRealtimeUsage,
  REALTIME_USAGE_PATH,
  REALTIME_USAGE_CAP,
  type ApiFetch,
} from "./realtime-usage-client";

function jsonResponse(status: number, body: unknown = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

describe("reportRealtimeUsage — constants", () => {
  test("path matches the worker route", () => {
    expect(REALTIME_USAGE_PATH).toBe("/api/billing/realtime-usage");
  });

  test("cap matches the worker per-report cap of 500k", () => {
    expect(REALTIME_USAGE_CAP).toBe(500_000);
  });
});

describe("reportRealtimeUsage — skip-when-empty", () => {
  test("does not POST when all counters are zero, returns ok:true", async () => {
    const apiFetch = vi.fn<ApiFetch>();
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 0,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result).toEqual({ ok: true });
    expect(apiFetch).not.toHaveBeenCalled();
  });
});

describe("reportRealtimeUsage — happy path", () => {
  test("POSTs JSON body with all four counters on 2xx", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200, { ok: true }));
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 1234,
      audioOutputTokens: 5678,
      textInputTokens: 9,
      textOutputTokens: 1,
    });
    expect(result).toEqual({ ok: true });
    expect(apiFetch).toHaveBeenCalledTimes(1);
    const [path, init] = apiFetch.mock.calls[0]!;
    expect(path).toBe(REALTIME_USAGE_PATH);
    expect(init?.method).toBe("POST");
    const headers = new Headers(init?.headers);
    expect(headers.get("Content-Type")).toBe("application/json");
    expect(JSON.parse(String(init?.body))).toEqual({
      audioInputTokens: 1234,
      audioOutputTokens: 5678,
      textInputTokens: 9,
      textOutputTokens: 1,
    });
  });

  test("a single non-zero counter is enough to trigger the POST", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200));
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 1,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result).toEqual({ ok: true });
    expect(apiFetch).toHaveBeenCalledTimes(1);
  });
});

describe("reportRealtimeUsage — non-2xx responses", () => {
  test("400 returns ok:false with a reason string, does not throw", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () =>
      jsonResponse(400, { error: "bad request" }),
    );
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 10,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(typeof result.reason).toBe("string");
      expect(result.reason).toMatch(/400/);
    }
  });

  test("401 returns ok:false and does NOT throw", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(401, {}));
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 10,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/401/);
  });

  test("500 returns ok:false and does NOT throw", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(500, {}));
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 10,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
  });
});

describe("reportRealtimeUsage — fetch errors", () => {
  test("when apiFetch rejects, returns ok:false and does NOT throw", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => {
      throw new Error("network down");
    });
    const result = await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 10,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.reason).toMatch(/network down/);
  });
});

describe("reportRealtimeUsage — clamping", () => {
  let warnSpy: ReturnType<typeof vi.spyOn>;
  beforeEach(() => {
    warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});
  });
  afterEach(() => {
    warnSpy.mockRestore();
  });

  test("oversized counters are clamped to REALTIME_USAGE_CAP in the POST body", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200));
    await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 999_999,
      audioOutputTokens: 600_000,
      textInputTokens: 500_001,
      textOutputTokens: 12_345,
    });
    const [, init] = apiFetch.mock.calls[0]!;
    expect(JSON.parse(String(init?.body))).toEqual({
      audioInputTokens: REALTIME_USAGE_CAP,
      audioOutputTokens: REALTIME_USAGE_CAP,
      textInputTokens: REALTIME_USAGE_CAP,
      textOutputTokens: 12_345,
    });
  });

  test("clamping emits a console.warn", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200));
    await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 999_999,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(warnSpy).toHaveBeenCalled();
  });

  test("negative counters are clamped to 0 (not sent as negative)", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200));
    await reportRealtimeUsage(apiFetch, {
      audioInputTokens: -5,
      audioOutputTokens: 100,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    const [, init] = apiFetch.mock.calls[0]!;
    expect(JSON.parse(String(init?.body))).toEqual({
      audioInputTokens: 0,
      audioOutputTokens: 100,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
  });

  test("no warn when nothing needed clamping", async () => {
    const apiFetch = vi.fn<ApiFetch>(async () => jsonResponse(200));
    await reportRealtimeUsage(apiFetch, {
      audioInputTokens: 100,
      audioOutputTokens: 50,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(warnSpy).not.toHaveBeenCalled();
  });
});
