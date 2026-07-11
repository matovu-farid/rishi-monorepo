export const DEFAULT_RATES = {
    chat: {
        // https://developers.openai.com/api/docs/models/gpt-5-nano
        "gpt-5-nano": { inputPer1M: 0.05, outputPer1M: 0.4 },
    },
    tts: {
        // https://developers.openai.com/api/docs/models/tts-1
        "tts-1": { per1MChars: 15.0 },
    },
    embedding: {
        // https://developers.openai.com/api/docs/models/text-embedding-3-small
        "text-embedding-3-small": { per1MTokens: 0.02 },
    },
    realtime: {
        // https://developers.openai.com/api/docs/models/gpt-realtime
        "gpt-realtime": {
            audioInputPer1M: 32.0,
            audioOutputPer1M: 64.0,
            textInputPer1M: 4.0,
            textOutputPer1M: 16.0,
        },
    },
};
