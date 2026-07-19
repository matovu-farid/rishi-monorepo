// OpenAI public pricing — fetched 2026-06-03 from https://developers.openai.com/api/docs/pricing
import type { RateCard } from "./cost";

export const DEFAULT_RATES: RateCard = {
  chat: {
    // https://developers.openai.com/api/docs/models/gpt-5-nano
    "gpt-5-nano": { inputPer1M: 0.05, outputPer1M: 0.4 },
  },
  tts: {
    // https://developers.openai.com/api/docs/models/tts-1
    "tts-1": { per1MChars: 15.0 },
    // gpt-4o-mini-tts is the model actually used in production
    // (workers/worker/src/index.ts calls openai.audio.speech.create with
    // model: "gpt-4o-mini-tts") but had NO entry here until 2026-07-17,
    // which made computeOpenAiCostUsd() throw "No tts rate for model:
    // gpt-4o-mini-tts" inside meterFromContext(), silently swallowed by
    // waitUntil() — every production TTS request failed to report its
    // Stripe meter event.
    //
    // OpenAI's real gpt-4o-mini-tts pricing is TOKEN-based, not character-
    // based: $0.60 / 1M text-input tokens + $12.00 / 1M audio-output tokens
    // (https://developers.openai.com/api/docs/models/gpt-4o-mini-tts,
    // confirmed 2026-07-17), which this character-based RateCard shape
    // cannot represent exactly — OpenAiUsage["tts"] only carries a
    // character count today, not token counts. Two independent trackers
    // (texttolab.com/blog/openai-tts-pricing and costgoat.com/pricing/
    // openai-tts, both checked 2026-07-17) estimate gpt-4o-mini-tts's
    // effective cost at approximately the same $15/1M characters / ~$0.015
    // per minute of audio as tts-1 for typical English text. Use that
    // documented approximation so metering fires correctly-ish instead of
    // throwing. A follow-up should extend OpenAiUsage["tts"] to carry real
    // input/output token counts from OpenAI's response for exact billing —
    // see "Follow-up wiring required" in the plan doc that added this
    // comment (2026-07-17-rate-limits-feature-flags-telemetry.md).
    "gpt-4o-mini-tts": { per1MChars: 15.0 },
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
    "gpt-realtime-mini": {
      audioInputPer1M: 10.0,
      audioOutputPer1M: 20.0,
      textInputPer1M: 0.6,
      textOutputPer1M: 2.4,
    },
  },
};
