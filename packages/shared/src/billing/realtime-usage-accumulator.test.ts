import { describe, test, expect } from "vitest";
import { createUsageAccumulator } from "./realtime-usage-accumulator";

describe("createUsageAccumulator — initial state", () => {
  test("starts at zero across all counters", () => {
    const acc = createUsageAccumulator();
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 0,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
  });

  test("isEmpty is true before any add", () => {
    const acc = createUsageAccumulator();
    expect(acc.isEmpty()).toBe(true);
  });
});

describe("createUsageAccumulator — add", () => {
  test("single add records the values", () => {
    const acc = createUsageAccumulator();
    acc.add({
      audioInputTokens: 100,
      audioOutputTokens: 50,
      textInputTokens: 10,
      textOutputTokens: 5,
    });
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 100,
      audioOutputTokens: 50,
      textInputTokens: 10,
      textOutputTokens: 5,
    });
  });

  test("multiple adds sum field-wise", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 100, audioOutputTokens: 50 });
    acc.add({ audioInputTokens: 25, audioOutputTokens: 5, textInputTokens: 3 });
    acc.add({ textOutputTokens: 7 });
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 125,
      audioOutputTokens: 55,
      textInputTokens: 3,
      textOutputTokens: 7,
    });
  });

  test("missing fields are treated as zero", () => {
    const acc = createUsageAccumulator();
    acc.add({});
    acc.add({ audioInputTokens: 42 });
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 42,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
  });

  test("isEmpty becomes false after a non-zero add", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 1 });
    expect(acc.isEmpty()).toBe(false);
  });

  test("isEmpty stays true after adds of only zeros", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 0, audioOutputTokens: 0 });
    acc.add({});
    expect(acc.isEmpty()).toBe(true);
  });

  test("negative values are rejected by throwing", () => {
    const acc = createUsageAccumulator();
    expect(() => acc.add({ audioInputTokens: -1 })).toThrow(
      /non-negative/i,
    );
    expect(() => acc.add({ audioOutputTokens: -5 })).toThrow(/non-negative/i);
    expect(() => acc.add({ textInputTokens: -1 })).toThrow(/non-negative/i);
    expect(() => acc.add({ textOutputTokens: -1 })).toThrow(/non-negative/i);
  });

  test("a rejected add does not mutate state", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 10 });
    expect(() =>
      acc.add({ audioInputTokens: 5, audioOutputTokens: -1 }),
    ).toThrow();
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 10,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
  });
});

describe("createUsageAccumulator — snapshot vs flush", () => {
  test("snapshot does not reset state", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 10, audioOutputTokens: 20 });
    acc.snapshot();
    acc.snapshot();
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 10,
      audioOutputTokens: 20,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(acc.isEmpty()).toBe(false);
  });

  test("snapshot returns a fresh object that does not alias internal state", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 10 });
    const snap = acc.snapshot();
    snap.audioInputTokens = 9999;
    expect(acc.snapshot().audioInputTokens).toBe(10);
  });

  test("flush returns totals and resets counters to zero", () => {
    const acc = createUsageAccumulator();
    acc.add({
      audioInputTokens: 100,
      audioOutputTokens: 50,
      textInputTokens: 7,
      textOutputTokens: 3,
    });
    const flushed = acc.flush();
    expect(flushed).toEqual({
      audioInputTokens: 100,
      audioOutputTokens: 50,
      textInputTokens: 7,
      textOutputTokens: 3,
    });
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 0,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(acc.isEmpty()).toBe(true);
  });

  test("flush on an empty accumulator returns zeros and stays empty", () => {
    const acc = createUsageAccumulator();
    expect(acc.flush()).toEqual({
      audioInputTokens: 0,
      audioOutputTokens: 0,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
    expect(acc.isEmpty()).toBe(true);
  });

  test("can accumulate again after a flush", () => {
    const acc = createUsageAccumulator();
    acc.add({ audioInputTokens: 10 });
    acc.flush();
    acc.add({ audioInputTokens: 4, audioOutputTokens: 2 });
    expect(acc.snapshot()).toEqual({
      audioInputTokens: 4,
      audioOutputTokens: 2,
      textInputTokens: 0,
      textOutputTokens: 0,
    });
  });
});
