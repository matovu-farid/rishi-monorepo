export type RealtimeUsageInput = {
  audioInputTokens?: number;
  audioOutputTokens?: number;
  textInputTokens?: number;
  textOutputTokens?: number;
};

export type RealtimeUsageTotal = {
  audioInputTokens: number;
  audioOutputTokens: number;
  textInputTokens: number;
  textOutputTokens: number;
};

export interface RealtimeUsageAccumulator {
  add(usage: RealtimeUsageInput): void;
  snapshot(): RealtimeUsageTotal;
  flush(): RealtimeUsageTotal;
  isEmpty(): boolean;
}

const FIELDS = [
  "audioInputTokens",
  "audioOutputTokens",
  "textInputTokens",
  "textOutputTokens",
] as const;

function validateNonNegative(usage: RealtimeUsageInput): void {
  for (const f of FIELDS) {
    const v = usage[f];
    if (v === undefined) continue;
    if (typeof v !== "number" || !Number.isFinite(v) || v < 0) {
      throw new Error(`${f} must be a non-negative finite number`);
    }
  }
}

export function createUsageAccumulator(): RealtimeUsageAccumulator {
  const totals: RealtimeUsageTotal = {
    audioInputTokens: 0,
    audioOutputTokens: 0,
    textInputTokens: 0,
    textOutputTokens: 0,
  };

  return {
    add(usage) {
      validateNonNegative(usage);
      totals.audioInputTokens += usage.audioInputTokens ?? 0;
      totals.audioOutputTokens += usage.audioOutputTokens ?? 0;
      totals.textInputTokens += usage.textInputTokens ?? 0;
      totals.textOutputTokens += usage.textOutputTokens ?? 0;
    },
    snapshot() {
      return { ...totals };
    },
    flush() {
      const out = { ...totals };
      totals.audioInputTokens = 0;
      totals.audioOutputTokens = 0;
      totals.textInputTokens = 0;
      totals.textOutputTokens = 0;
      return out;
    },
    isEmpty() {
      return (
        totals.audioInputTokens === 0 &&
        totals.audioOutputTokens === 0 &&
        totals.textInputTokens === 0 &&
        totals.textOutputTokens === 0
      );
    },
  };
}
