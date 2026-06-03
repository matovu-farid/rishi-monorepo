import { describe, test, expect } from "vitest";
import { computeOpenAiCostUsd, type RateCard } from "./cost";

describe("computeOpenAiCostUsd — chat", () => {
  test("sums input and output token cost at per-1M rates", () => {
    const rates: RateCard = {
      chat: { "gpt-5-nano": { inputPer1M: 0.05, outputPer1M: 0.4 } },
      tts: {},
    };
    const cost = computeOpenAiCostUsd(
      {
        type: "chat",
        model: "gpt-5-nano",
        inputTokens: 1_000_000,
        outputTokens: 500_000,
      },
      rates,
    );
    expect(cost).toBeCloseTo(0.25, 10);
  });
});

describe("computeOpenAiCostUsd — tts", () => {
  test("charges per-character at per-1M rate", () => {
    const rates: RateCard = {
      chat: {},
      tts: { "tts-1": { per1MChars: 15 } },
      embedding: {},
      realtime: {},
    };
    const cost = computeOpenAiCostUsd(
      { type: "tts", model: "tts-1", characters: 2000 },
      rates,
    );
    // 2000 chars * $15/1M = $0.03
    expect(cost).toBeCloseTo(0.03, 10);
  });
});

describe("computeOpenAiCostUsd — embedding", () => {
  test("charges per-token at per-1M rate", () => {
    const rates: RateCard = {
      chat: {},
      tts: {},
      embedding: { "text-embedding-3-small": { per1MTokens: 0.02 } },
      realtime: {},
    };
    const cost = computeOpenAiCostUsd(
      { type: "embedding", model: "text-embedding-3-small", tokens: 500_000 },
      rates,
    );
    // 0.5M * $0.02/1M = $0.00001 * 1000 = $0.01
    expect(cost).toBeCloseTo(0.01, 10);
  });
});

describe("computeOpenAiCostUsd — realtime", () => {
  test("sums audio input + audio output + text input + text output costs", () => {
    const rates: RateCard = {
      chat: {},
      tts: {},
      embedding: {},
      realtime: {
        "gpt-4o-realtime-preview": {
          audioInputPer1M: 40,
          audioOutputPer1M: 80,
          textInputPer1M: 5,
          textOutputPer1M: 20,
        },
      },
    };
    const cost = computeOpenAiCostUsd(
      {
        type: "realtime",
        model: "gpt-4o-realtime-preview",
        audioInputTokens: 100_000,
        audioOutputTokens: 50_000,
        textInputTokens: 10_000,
        textOutputTokens: 5_000,
      },
      rates,
    );
    // (100k*40 + 50k*80 + 10k*5 + 5k*20) / 1M
    // = (4_000_000 + 4_000_000 + 50_000 + 100_000) / 1M = 8.15
    expect(cost).toBeCloseTo(8.15, 10);
  });

  test("treats omitted text token fields as zero", () => {
    const rates: RateCard = {
      chat: {},
      tts: {},
      embedding: {},
      realtime: {
        "gpt-4o-realtime-preview": {
          audioInputPer1M: 40,
          audioOutputPer1M: 80,
          textInputPer1M: 5,
          textOutputPer1M: 20,
        },
      },
    };
    const cost = computeOpenAiCostUsd(
      {
        type: "realtime",
        model: "gpt-4o-realtime-preview",
        audioInputTokens: 1_000_000,
        audioOutputTokens: 500_000,
      },
      rates,
    );
    // 1M*40 + 0.5M*80 = 40 + 40 = $80
    expect(cost).toBeCloseTo(80, 10);
  });
});

describe("computeOpenAiCostUsd — error cases", () => {
  test("throws when model is missing from the rate card", () => {
    const rates: RateCard = {
      chat: {},
      tts: {},
      embedding: {},
      realtime: {},
    };
    expect(() =>
      computeOpenAiCostUsd(
        {
          type: "chat",
          model: "gpt-unknown",
          inputTokens: 1,
          outputTokens: 1,
        },
        rates,
      ),
    ).toThrow(/gpt-unknown/);
  });
});
