import { describe, test, expect } from "vitest";
import { DEFAULT_RATES } from "./default-rates";
import { REALTIME_VOICE_MODEL } from "../realtime/model";

const isPositiveFinite = (n: unknown): boolean =>
  typeof n === "number" && Number.isFinite(n) && n > 0;

describe("DEFAULT_RATES structure", () => {
  test("chat: gpt-5-nano has positive finite input/output per-1M rates", () => {
    const rate = DEFAULT_RATES.chat["gpt-5-nano"];
    expect(rate).toBeDefined();
    expect(isPositiveFinite(rate.inputPer1M)).toBe(true);
    expect(isPositiveFinite(rate.outputPer1M)).toBe(true);
  });

  test("tts: tts-1 has positive finite per-1M-chars rate", () => {
    const rate = DEFAULT_RATES.tts["tts-1"];
    expect(rate).toBeDefined();
    expect(isPositiveFinite(rate.per1MChars)).toBe(true);
  });

  test("embedding: text-embedding-3-small has positive finite per-1M-tokens rate", () => {
    const rate = DEFAULT_RATES.embedding["text-embedding-3-small"];
    expect(rate).toBeDefined();
    expect(isPositiveFinite(rate.per1MTokens)).toBe(true);
  });

  test("realtime: gpt-realtime has positive finite audio + text per-1M rates", () => {
    const rate = DEFAULT_RATES.realtime["gpt-realtime"];
    expect(rate).toBeDefined();
    expect(isPositiveFinite(rate.audioInputPer1M)).toBe(true);
    expect(isPositiveFinite(rate.audioOutputPer1M)).toBe(true);
    expect(isPositiveFinite(rate.textInputPer1M)).toBe(true);
    expect(isPositiveFinite(rate.textOutputPer1M)).toBe(true);
  });

  test("realtime mini aliases preserve historical and canonical keys at the same rates", () => {
    expect(REALTIME_VOICE_MODEL).toBe("gpt-realtime-2.1-mini");
    expect(DEFAULT_RATES.realtime["gpt-realtime-mini"]).toEqual({
      audioInputPer1M: 10,
      audioOutputPer1M: 20,
      textInputPer1M: 0.6,
      textOutputPer1M: 2.4,
    });
    expect(DEFAULT_RATES.realtime[REALTIME_VOICE_MODEL]).toEqual(
      DEFAULT_RATES.realtime["gpt-realtime-mini"],
    );
  });
});
