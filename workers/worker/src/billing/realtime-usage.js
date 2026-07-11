/**
 * Per-report cap. Roughly $50 worth of realtime audio at gpt-realtime
 * rates (audio in $32/1M, audio out $64/1M, plus margin). Anyone
 * sending more in a single report is almost certainly buggy or
 * malicious; we 400 and ask them to split.
 */
export const REALTIME_MAX_TOKENS_PER_REPORT = 500_000;
const REALTIME_MODEL = "gpt-realtime";
function isNonNegInt(v, name) {
    if (typeof v !== "number") {
        return false;
    }
    if (!Number.isInteger(v) || v < 0) {
        return false;
    }
    if (v > REALTIME_MAX_TOKENS_PER_REPORT) {
        throw new Error(`${name} exceeds per-report cap of ${REALTIME_MAX_TOKENS_PER_REPORT}`);
    }
    return true;
}
export function parseRealtimeUsageBody(raw) {
    if (!raw || typeof raw !== "object") {
        return { ok: false, error: "Body must be an object" };
    }
    const r = raw;
    try {
        if (!isNonNegInt(r.audioInputTokens, "audioInputTokens")) {
            return { ok: false, error: "audioInputTokens must be a non-negative integer" };
        }
        if (!isNonNegInt(r.audioOutputTokens, "audioOutputTokens")) {
            return { ok: false, error: "audioOutputTokens must be a non-negative integer" };
        }
        const textIn = r.textInputTokens === undefined ? 0 : r.textInputTokens;
        const textOut = r.textOutputTokens === undefined ? 0 : r.textOutputTokens;
        if (!isNonNegInt(textIn, "textInputTokens")) {
            return { ok: false, error: "textInputTokens must be a non-negative integer when provided" };
        }
        if (!isNonNegInt(textOut, "textOutputTokens")) {
            return { ok: false, error: "textOutputTokens must be a non-negative integer when provided" };
        }
        return {
            ok: true,
            usage: {
                type: "realtime",
                model: REALTIME_MODEL,
                audioInputTokens: r.audioInputTokens,
                audioOutputTokens: r.audioOutputTokens,
                textInputTokens: textIn,
                textOutputTokens: textOut,
            },
        };
    }
    catch (e) {
        return { ok: false, error: e instanceof Error ? e.message : "validation failed" };
    }
}
