import type { RealtimeUsageTotal } from "./realtime-usage-accumulator";

export type ApiFetch = (path: string, init?: RequestInit) => Promise<Response>;

export const REALTIME_USAGE_PATH = "/api/billing/realtime-usage";
export const REALTIME_USAGE_CAP = 500_000;

export type ReportResult = { ok: true } | { ok: false; reason: string };

const FIELDS = [
  "audioInputTokens",
  "audioOutputTokens",
  "textInputTokens",
  "textOutputTokens",
] as const;

function clamp(v: number): number {
  if (!Number.isFinite(v) || v < 0) return 0;
  if (v > REALTIME_USAGE_CAP) return REALTIME_USAGE_CAP;
  return v;
}

export async function reportRealtimeUsage(
  apiFetch: ApiFetch,
  usage: RealtimeUsageTotal,
): Promise<ReportResult> {
  const clamped: RealtimeUsageTotal = {
    audioInputTokens: clamp(usage.audioInputTokens),
    audioOutputTokens: clamp(usage.audioOutputTokens),
    textInputTokens: clamp(usage.textInputTokens),
    textOutputTokens: clamp(usage.textOutputTokens),
  };

  const adjusted = FIELDS.filter((f) => clamped[f] !== usage[f]);
  if (adjusted.length > 0) {
    console.warn(
      `[realtime-usage-client] clamped out-of-range counters: ${adjusted.join(", ")}`,
    );
  }

  if (
    clamped.audioInputTokens === 0 &&
    clamped.audioOutputTokens === 0 &&
    clamped.textInputTokens === 0 &&
    clamped.textOutputTokens === 0
  ) {
    return { ok: true };
  }

  let response: Response;
  try {
    response = await apiFetch(REALTIME_USAGE_PATH, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(clamped),
    });
  } catch (e) {
    const reason = e instanceof Error ? e.message : String(e);
    return { ok: false, reason };
  }

  if (!response.ok) {
    return { ok: false, reason: `HTTP ${response.status}` };
  }
  return { ok: true };
}
