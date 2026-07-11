export function computeOpenAiCostUsd(usage, rates) {
    switch (usage.type) {
        case "chat": {
            const rate = rates.chat[usage.model];
            if (!rate)
                throw new Error(`No chat rate for model: ${usage.model}`);
            return ((usage.inputTokens * rate.inputPer1M +
                usage.outputTokens * rate.outputPer1M) /
                1_000_000);
        }
        case "tts": {
            const rate = rates.tts[usage.model];
            if (!rate)
                throw new Error(`No tts rate for model: ${usage.model}`);
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
            if (!rate)
                throw new Error(`No realtime rate for model: ${usage.model}`);
            const textIn = usage.textInputTokens ?? 0;
            const textOut = usage.textOutputTokens ?? 0;
            return ((usage.audioInputTokens * rate.audioInputPer1M +
                usage.audioOutputTokens * rate.audioOutputPer1M +
                textIn * rate.textInputPer1M +
                textOut * rate.textOutputPer1M) /
                1_000_000);
        }
    }
}
