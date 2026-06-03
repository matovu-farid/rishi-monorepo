import { describe, test, expect } from "vitest";
import {
  parseRealtimeUsageBody,
  REALTIME_MAX_TOKENS_PER_REPORT,
} from "./realtime-usage";

describe("parseRealtimeUsageBody", () => {
  test("accepts a valid audio-only report", () => {
    const result = parseRealtimeUsageBody({
      audioInputTokens: 1000,
      audioOutputTokens: 500,
    });
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.usage).toEqual({
        type: "realtime",
        model: "gpt-realtime",
        audioInputTokens: 1000,
        audioOutputTokens: 500,
        textInputTokens: 0,
        textOutputTokens: 0,
      });
    }
  });

  test("accepts text tokens when present", () => {
    const result = parseRealtimeUsageBody({
      audioInputTokens: 100,
      audioOutputTokens: 100,
      textInputTokens: 50,
      textOutputTokens: 75,
    });
    expect(result.ok).toBe(true);
    if (result.ok && result.usage.type === "realtime") {
      expect(result.usage.textInputTokens).toBe(50);
      expect(result.usage.textOutputTokens).toBe(75);
    }
  });

  test("rejects missing audio fields", () => {
    const result = parseRealtimeUsageBody({ textInputTokens: 5 });
    expect(result.ok).toBe(false);
  });

  test("rejects non-integer fields", () => {
    const result = parseRealtimeUsageBody({
      audioInputTokens: "lots" as unknown as number,
      audioOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
  });

  test("rejects negative token counts", () => {
    const result = parseRealtimeUsageBody({
      audioInputTokens: -1,
      audioOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
  });

  test("rejects when any single field exceeds the per-report cap", () => {
    const result = parseRealtimeUsageBody({
      audioInputTokens: REALTIME_MAX_TOKENS_PER_REPORT + 1,
      audioOutputTokens: 0,
    });
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.error).toMatch(/cap|max/i);
    }
  });
});
