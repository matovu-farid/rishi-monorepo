import { describe, test, expect } from "vitest";
import { DEFAULT_RATES } from "./default-rates";
const isPositiveFinite = (n) => typeof n === "number" && Number.isFinite(n) && n > 0;
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
});
