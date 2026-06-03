export type ChatRate = { inputPer1M: number; outputPer1M: number };
export type TtsRate = { per1MChars: number };
export type EmbeddingRate = { per1MTokens: number };
export type RealtimeRate = {
  audioInputPer1M: number;
  audioOutputPer1M: number;
  textInputPer1M: number;
  textOutputPer1M: number;
};

export type RateCard = {
  chat: Record<string, ChatRate>;
  tts: Record<string, TtsRate>;
  embedding: Record<string, EmbeddingRate>;
  realtime: Record<string, RealtimeRate>;
};

export type OpenAiUsage =
  | {
      type: "chat";
      model: string;
      inputTokens: number;
      outputTokens: number;
    }
  | {
      type: "tts";
      model: string;
      characters: number;
    }
  | {
      type: "embedding";
      model: string;
      tokens: number;
    }
  | {
      type: "realtime";
      model: string;
      audioInputTokens: number;
      audioOutputTokens: number;
      textInputTokens?: number;
      textOutputTokens?: number;
    };

export function computeOpenAiCostUsd(
  usage: OpenAiUsage,
  rates: RateCard,
): number {
  switch (usage.type) {
    case "chat": {
      const rate = rates.chat[usage.model];
      if (!rate) throw new Error(`No chat rate for model: ${usage.model}`);
      return (
        (usage.inputTokens * rate.inputPer1M +
          usage.outputTokens * rate.outputPer1M) /
        1_000_000
      );
    }
    case "tts": {
      const rate = rates.tts[usage.model];
      if (!rate) throw new Error(`No tts rate for model: ${usage.model}`);
      return (usage.characters * rate.per1MChars) / 1_000_000;
    }
    case "embedding": {
      const rate = rates.embedding[usage.model];
      if (!rate)
        throw new Error(`No embedding rate for model: ${usage.model}`);
      return (usage.tokens * rate.per1MTokens) / 1_000_000;
    }
    case "realtime": {
      const rate = rates.realtime[usage.model];
      if (!rate) throw new Error(`No realtime rate for model: ${usage.model}`);
      const textIn = usage.textInputTokens ?? 0;
      const textOut = usage.textOutputTokens ?? 0;
      return (
        (usage.audioInputTokens * rate.audioInputPer1M +
          usage.audioOutputTokens * rate.audioOutputPer1M +
          textIn * rate.textInputPer1M +
          textOut * rate.textOutputPer1M) /
        1_000_000
      );
    }
  }
}
